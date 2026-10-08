import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum ModelRegistryError: Error, Equatable, Sendable {
    case operationInProgress
    case invalidDirectory
    case invalidCatalog(String)
    case fileOperationFailed(String)
    case modelNotInstalled(id: String, quantization: ModelQuantization)
    case artifactUnavailable(id: String, quantization: ModelQuantization)
    case artifactVerificationFailed(id: String, quantization: ModelQuantization, cause: ModelImportError)
}

extension ModelRegistryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .operationInProgress: "Another local model operation is in progress."
        case .invalidDirectory: "The private model directory is unavailable or unsafe."
        case .invalidCatalog(let reason): "The local model catalog is invalid: \(reason). Reimport requires repairing the catalog first."
        case .fileOperationFailed(let operation): "The local model catalog operation failed: \(operation)."
        case .modelNotInstalled(let id, let quantization): "Model \(id) (\(quantization.rawValue)) has not been imported."
        case .artifactUnavailable(let id, let quantization): "The private artifact for \(id) (\(quantization.rawValue)) is missing or unsafe."
        case .artifactVerificationFailed(let id, let quantization, let cause):
            "The private artifact for \(id) (\(quantization.rawValue)) failed verification: \(cause.localizedDescription)"
        }
    }
}

/// An offline catalog of reviewed manifests and immutable, app-private imports.
/// Catalog entries store UUID artifact identifiers, never a caller-supplied file URL.
/// A replacement commits a new generation before atomically switching the catalog;
/// failures preserve the previous catalog and generation. M1 retains former generations
/// after successful replacements: an older catalog must not refer to a deleted artifact
/// if the metadata rename rolls back after power loss. This costs disk space until an
/// explicit cleanup policy is implemented; rename alone is not a disk durability guarantee.
/// This actor and its nonblocking file lock own the directory across suspensions,
/// including when another registry instance is used.
public actor ModelRegistry {
    private struct Identity: Codable, Equatable {
        let id: String
        let quantization: ModelQuantization

        init(_ manifest: ModelManifest) {
            id = manifest.id
            quantization = manifest.quantization
        }
    }

    private struct Entry: Codable {
        let manifest: ModelManifest
        let artifactIdentifier: String
        var identity: Identity { Identity(manifest) }
    }

    private struct Catalog: Codable {
        var version = 1
        var entries: [Entry] = []
        var selected: Identity?
    }

    private let modelsDirectory: URL
    private var operationInProgress = false
    private let maximumCatalogBytes = 1_048_576

    public init(modelsDirectory: URL) {
        self.modelsDirectory = modelsDirectory
    }

    /// Call from the app to obtain its sandbox's existing Application Support/Models
    /// location. No legacy file becomes trusted until explicitly reimported with a manifest.
    public nonisolated static func applicationSupportModelsDirectory() throws -> URL {
        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
            return support.appendingPathComponent("Models", isDirectory: true)
        } catch {
            throw ModelRegistryError.fileOperationFailed("locate Application Support")
        }
    }

    /// Explicit import also selects this exact ID and quantization. There is no
    /// download, automatic Q4 fallback, or metadata change before verification succeeds.
    public func importModel(from sourceURL: URL, manifest: ModelManifest) async throws -> ValidatedModel {
        try checkManifest(manifest)
        let directory = try beginOperation()
        defer { endOperation(directory.lockDescriptor) }
        var catalog = try readCatalog(in: directory.root)
        let artifactIdentifier = UUID().uuidString
        let generation = directory.artifacts.appendingPathComponent(artifactIdentifier, isDirectory: true)
        // Only this operation owns this newly allocated generation. No model import
        // touches a filename referenced by the previously committed catalog.
        try createPrivateDirectory(generation, allowExisting: false)
        var committed = false
        defer {
            if !committed { removeOwnedGeneration(artifactIdentifier, manifest: manifest, in: directory.artifacts) }
        }
        let importer = ModelImporter(modelsDirectory: generation)
        let model = try await importer.importModel(from: sourceURL, manifest: manifest)
        try Task.checkCancellation()
        catalog.entries.removeAll { $0.identity == Identity(manifest) }
        catalog.entries.append(Entry(manifest: manifest, artifactIdentifier: artifactIdentifier))
        catalog.selected = Identity(manifest)
        try writeCatalog(catalog, in: directory.root)
        committed = true
        // Do not delete a formerly committed generation here. The catalog file is
        // synchronized before rename, but no cross-platform directory durability
        // guarantee is made. An older durable catalog must retain its artifact.
        return model
    }

    /// Returns metadata with cheap existence/regular-file checks. Listing never reads
    /// weights; use verifiedModel or restoreSelectedModel before handing a URL to inference.
    public func installedModels() async throws -> [ModelManifest] {
        let directory = try beginOperation()
        defer { endOperation(directory.lockDescriptor) }
        let catalog = try readCatalog(in: directory.root)
        for entry in catalog.entries {
            try Task.checkCancellation()
            _ = try artifactURL(for: entry, in: directory.artifacts)
        }
        return catalog.entries.map(\.manifest).sorted {
            if $0.id != $1.id { return $0.id < $1.id }
            return $0.quantization.rawValue < $1.quantization.rawValue
        }
    }

    /// Rehashes the entire installed file with ModelImporter before persisting the
    /// user's exact selection. A missing Q8 never selects Q4 on the user's behalf.
    public func verifiedModel(id: String, quantization: ModelQuantization) async throws -> ValidatedModel {
        let directory = try beginOperation()
        defer { endOperation(directory.lockDescriptor) }
        var catalog = try readCatalog(in: directory.root)
        guard let entry = catalog.entries.first(where: { $0.manifest.id == id && $0.manifest.quantization == quantization }) else {
            throw ModelRegistryError.modelNotInstalled(id: id, quantization: quantization)
        }
        let model = try await verify(entry, in: directory.artifacts)
        try Task.checkCancellation()
        if catalog.selected != entry.identity {
            catalog.selected = entry.identity
            try writeCatalog(catalog, in: directory.root)
        }
        return model
    }

    /// Restoring metadata does not restore trust: the selected artifact is streamed
    /// through checksum/envelope validation again after each process restart.
    public func restoreSelectedModel() async throws -> ValidatedModel? {
        let directory = try beginOperation()
        defer { endOperation(directory.lockDescriptor) }
        let catalog = try readCatalog(in: directory.root)
        guard let selected = catalog.selected else { return nil }
        guard let entry = catalog.entries.first(where: { $0.identity == selected }) else {
            throw ModelRegistryError.invalidCatalog("selected model is absent")
        }
        return try await verify(entry, in: directory.artifacts)
    }

    private func verify(_ entry: Entry, in artifacts: URL) async throws -> ValidatedModel {
        let fileURL = try artifactURL(for: entry, in: artifacts)
        let importer = ModelImporter(modelsDirectory: fileURL.deletingLastPathComponent())
        do {
            return try await importer.validateExistingModel(at: fileURL, manifest: entry.manifest)
        } catch let cause as ModelImportError {
            throw ModelRegistryError.artifactVerificationFailed(
                id: entry.manifest.id, quantization: entry.manifest.quantization, cause: cause
            )
        }
    }

    private func beginOperation() throws -> (root: URL, artifacts: URL, lockDescriptor: Int32) {
        try Task.checkCancellation()
        guard !operationInProgress else { throw ModelRegistryError.operationInProgress }
        guard modelsDirectory.isFileURL else { throw ModelRegistryError.invalidDirectory }
        let requested = modelsDirectory.standardizedFileURL
        try createPrivateDirectory(requested, allowExisting: true)
        let root = requested.resolvingSymlinksInPath()
        let artifacts = root.appendingPathComponent(".artifacts", isDirectory: true)
        try createPrivateDirectory(artifacts, allowExisting: true)
        let lock = root.appendingPathComponent(".catalog.lock")
        let descriptor = lock.path.withCString { open($0, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600) }
        guard descriptor >= 0 else { throw ModelRegistryError.fileOperationFailed("open catalog lock") }
        var status = stat()
        guard fstat(descriptor, &status) == 0, (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            _ = close(descriptor)
            throw ModelRegistryError.fileOperationFailed("verify catalog lock")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            _ = close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN { throw ModelRegistryError.operationInProgress }
            throw ModelRegistryError.fileOperationFailed("acquire catalog lock")
        }
        operationInProgress = true
        return (root, artifacts, descriptor)
    }

    private func endOperation(_ descriptor: Int32) {
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
        operationInProgress = false
    }

    private func createPrivateDirectory(_ url: URL, allowExisting: Bool) throws {
        var status = stat()
        let exists = url.path.withCString { lstat($0, &status) } == 0
        if exists {
            guard allowExisting, (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
                throw ModelRegistryError.invalidDirectory
            }
        } else {
            do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            catch { throw ModelRegistryError.fileOperationFailed("create private model directory") }
            guard url.path.withCString({ lstat($0, &status) }) == 0,
                  (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else { throw ModelRegistryError.invalidDirectory }
        }
        #if os(iOS)
        do {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var directory = url
            try directory.setResourceValues(values)
        } catch { throw ModelRegistryError.fileOperationFailed("protect private model directory") }
        #endif
    }

    private func readCatalog(in directory: URL) throws -> Catalog {
        let url = directory.appendingPathComponent("catalog.json")
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        if descriptor < 0 {
            if errno == ENOENT { return Catalog() }
            throw ModelRegistryError.invalidCatalog("metadata is not a readable regular file")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0, (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              status.st_size > 0, status.st_size <= maximumCatalogBytes else {
            throw ModelRegistryError.invalidCatalog("metadata size or file type is invalid")
        }
        let data: Data
        do { data = try handle.read(upToCount: maximumCatalogBytes + 1) ?? Data() }
        catch { throw ModelRegistryError.fileOperationFailed("read catalog") }
        guard data.count == status.st_size, data.count <= maximumCatalogBytes else {
            throw ModelRegistryError.invalidCatalog("metadata changed while reading")
        }
        let catalog: Catalog
        do { catalog = try JSONDecoder().decode(Catalog.self, from: data) }
        catch { throw ModelRegistryError.invalidCatalog("metadata could not be decoded") }
        guard catalog.version == 1, catalog.entries.count <= 256 else {
            throw ModelRegistryError.invalidCatalog("unsupported version or too many entries")
        }
        var identities: [Identity] = []
        var artifactIdentifiers: Set<String> = []
        for entry in catalog.entries {
            do { try checkManifest(entry.manifest) }
            catch { throw ModelRegistryError.invalidCatalog("invalid reviewed manifest") }
            guard validArtifactIdentifier(entry.artifactIdentifier),
                  !identities.contains(entry.identity), artifactIdentifiers.insert(entry.artifactIdentifier.uppercased()).inserted else {
                throw ModelRegistryError.invalidCatalog("invalid or duplicate artifact identity")
            }
            identities.append(entry.identity)
        }
        if let selected = catalog.selected, !identities.contains(selected) {
            throw ModelRegistryError.invalidCatalog("selected model is absent")
        }
        return catalog
    }

    private func writeCatalog(_ catalog: Catalog, in directory: URL) throws {
        guard catalog.entries.count <= 256 else { throw ModelRegistryError.invalidCatalog("too many entries") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do { data = try encoder.encode(catalog) }
        catch { throw ModelRegistryError.fileOperationFailed("encode catalog") }
        guard data.count <= maximumCatalogBytes else { throw ModelRegistryError.invalidCatalog("metadata exceeds size limit") }
        let staging = directory.appendingPathComponent(".catalog-\(UUID().uuidString).writing")
        let descriptor = staging.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
        guard descriptor >= 0 else { throw ModelRegistryError.fileOperationFailed("create catalog staging file") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: staging)
        }
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: staging.path)
            #endif
        } catch { throw ModelRegistryError.fileOperationFailed("finish catalog staging file") }
        try Task.checkCancellation()
        let destination = directory.appendingPathComponent("catalog.json")
        let result = staging.path.withCString { source in
            destination.path.withCString { target in rename(source, target) }
        }
        guard result == 0 else { throw ModelRegistryError.fileOperationFailed("atomically install catalog") }
    }

    private func artifactURL(for entry: Entry, in artifacts: URL) throws -> URL {
        guard validArtifactIdentifier(entry.artifactIdentifier) else { throw ModelRegistryError.invalidCatalog("invalid artifact identifier") }
        let generation = artifacts.appendingPathComponent(entry.artifactIdentifier, isDirectory: true)
        var status = stat()
        guard generation.path.withCString({ lstat($0, &status) }) == 0,
              (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            throw ModelRegistryError.artifactUnavailable(id: entry.manifest.id, quantization: entry.manifest.quantization)
        }
        let url = generation.appendingPathComponent("\(entry.manifest.id)-\(entry.manifest.quantization.rawValue).gguf")
        guard url.path.withCString({ lstat($0, &status) }) == 0,
              (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw ModelRegistryError.artifactUnavailable(id: entry.manifest.id, quantization: entry.manifest.quantization)
        }
        return url
    }

    private func validArtifactIdentifier(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString == value.uppercased()
    }

    /// Best-effort cleanup touches only the exact expected file in a known UUID
    /// directory. Unknown files and symlinks are preserved; no recursive deletion occurs.
    private func removeOwnedGeneration(_ identifier: String, manifest: ModelManifest, in artifacts: URL) {
        guard validArtifactIdentifier(identifier) else { return }
        let directory = artifacts.appendingPathComponent(identifier, isDirectory: true)
        var status = stat()
        guard directory.path.withCString({ lstat($0, &status) }) == 0,
              (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else { return }
        let file = directory.appendingPathComponent("\(manifest.id)-\(manifest.quantization.rawValue).gguf")
        if file.path.withCString({ lstat($0, &status) }) == 0,
           (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) {
            try? FileManager.default.removeItem(at: file)
        }
        // The importer cleans its own staging files. If an unexpected file remains,
        // leave the generation intact rather than traversing unrecognized contents.
        _ = directory.path.withCString { rmdir($0) }
    }

    private func checkManifest(_ manifest: ModelManifest) throws {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-".utf8)
        let hexadecimal = Set("0123456789abcdefABCDEF".utf8)
        guard !manifest.id.isEmpty, manifest.id.utf8.count <= 128,
              manifest.id.utf8.allSatisfy({ allowed.contains($0) }) else {
            throw ModelImportError.invalidManifest("Model ID must contain 1–128 ASCII letters, digits, underscores, or hyphens")
        }
        guard !manifest.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              manifest.expectedByteCount >= 24,
              manifest.sha256.utf8.count == 64, manifest.sha256.utf8.allSatisfy({ hexadecimal.contains($0) }),
              manifest.provenance.sourceURL.scheme?.lowercased() == "https",
              manifest.provenance.sourceURL.host?.isEmpty == false,
              manifest.provenance.sourceURL.user == nil, manifest.provenance.sourceURL.password == nil,
              !manifest.provenance.revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !manifest.provenance.license.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelImportError.invalidManifest("Reviewed name, size, SHA-256, HTTPS provenance, revision, and license are required")
        }
    }
}
