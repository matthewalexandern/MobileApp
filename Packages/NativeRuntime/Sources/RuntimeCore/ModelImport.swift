import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum ModelQuantization: String, Codable, CaseIterable, Hashable, Sendable {
    case q8_0 = "Q8_0"
    case q4_k_m = "Q4_K_M"
}

public struct ModelProvenance: Codable, Hashable, Sendable {
    public let sourceURL: URL
    public let revision: String
    public let license: String

    public init(sourceURL: URL, revision: String, license: String) {
        self.sourceURL = sourceURL
        self.revision = revision
        self.license = license
    }
}

/// A checksum and provenance supplied through an independently reviewed manifest.
/// Quantization is a reviewed declaration; the GGUF envelope alone cannot verify it.
public struct ModelManifest: Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let quantization: ModelQuantization
    public let expectedByteCount: Int64
    public let sha256: String
    public let provenance: ModelProvenance

    public init(
        id: String,
        displayName: String,
        quantization: ModelQuantization,
        expectedByteCount: Int64,
        sha256: String,
        provenance: ModelProvenance
    ) {
        self.id = id
        self.displayName = displayName
        self.quantization = quantization
        self.expectedByteCount = expectedByteCount
        self.sha256 = sha256
        self.provenance = provenance
    }
}

/// Import verification covers the reviewed checksum, size, and basic GGUF envelope.
/// Tensor structure, architecture compatibility, and memory suitability need native loading checks.
public struct ValidatedModel: Codable, Hashable, Sendable {
    public let fileURL: URL
    public let manifest: ModelManifest

    public init(fileURL: URL, manifest: ModelManifest) {
        self.fileURL = fileURL
        self.manifest = manifest
    }
}

public enum ModelImportError: Error, Equatable, Sendable {
    case invalidManifest(String)
    case inaccessibleSource
    case invalidGGUF
    case unsupportedGGUFVersion(UInt32)
    case sizeMismatch(expected: Int64, actual: Int64)
    case checksumMismatch
    case destinationConflict
    case fileOperationFailed(String)
}

extension ModelImportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidManifest(let reason): "Invalid model manifest: \(reason)"
        case .inaccessibleSource: "The selected local model file cannot be read."
        case .invalidGGUF: "The selected file does not have a valid basic GGUF header."
        case .unsupportedGGUFVersion(let version): "GGUF version \(version) is unsupported; select a little-endian version 2 or 3 file."
        case .sizeMismatch(let expected, let actual): "Model size mismatch: expected \(expected) bytes, found \(actual)."
        case .checksumMismatch: "Model SHA-256 does not match the reviewed manifest."
        case .destinationConflict: "Another import is using this model destination."
        case .fileOperationFailed(let operation): "The model file operation failed: \(operation)."
        }
    }
}

/// Copies a user-selected local model into a trusted, app-private directory.
/// No downloads occur, and a failed or cancelled import preserves the previous destination.
public actor ModelImporter {
    private let modelsDirectory: URL
    private var activeDestinations: Set<String> = []
    private let chunkByteCount = 1_048_576

    public init(modelsDirectory: URL) {
        self.modelsDirectory = modelsDirectory
    }

    public func importModel(from sourceURL: URL, manifest: ModelManifest) async throws -> ValidatedModel {
        try validateManifest(manifest)
        try Task.checkCancellation()
        let directory = try prepareDirectory()
        let filename = "\(manifest.id)-\(manifest.quantization.rawValue).gguf"
        guard activeDestinations.insert(filename).inserted else {
            throw ModelImportError.destinationConflict
        }
        defer { activeDestinations.remove(filename) }

        let destination = directory.appendingPathComponent(filename, isDirectory: false)
        guard destination.deletingLastPathComponent().standardizedFileURL.pathComponents == directory.pathComponents else {
            throw ModelImportError.invalidManifest("Model ID escapes the import directory")
        }
        let staging = directory.appendingPathComponent(".\(manifest.id)-\(UUID().uuidString).importing")

        let didAccess = beginScopedAccess(sourceURL)
        defer { endScopedAccess(sourceURL, didAccess: didAccess) }
        let input = try openSource(sourceURL, manifest: manifest)
        defer { try? input.close() }

        let descriptor = staging.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
        guard descriptor >= 0 else { throw ModelImportError.fileOperationFailed("create staging file") }
        defer { try? FileManager.default.removeItem(at: staging) }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? output.close() }

        try await verifyStream(input, manifest: manifest, output: output)
        do {
            try output.synchronize()
            try output.close()
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: staging.path)
            #endif
        } catch { throw ModelImportError.fileOperationFailed("finish staging file") }
        try Task.checkCancellation()

        // Both paths are on the same filesystem. POSIX rename atomically replaces an existing
        // file; Foundation replacement has platform-dependent behavior on Linux.
        let result = staging.path.withCString { source in
            destination.path.withCString { target in rename(source, target) }
        }
        guard result == 0 else { throw ModelImportError.fileOperationFailed("atomically install model") }
        return ValidatedModel(fileURL: destination, manifest: manifest)
    }

    public func validateExistingModel(at fileURL: URL, manifest: ModelManifest) async throws -> ValidatedModel {
        try validateManifest(manifest)
        try Task.checkCancellation()
        let didAccess = beginScopedAccess(fileURL)
        defer { endScopedAccess(fileURL, didAccess: didAccess) }
        let input = try openSource(fileURL, manifest: manifest)
        defer { try? input.close() }
        try await verifyStream(input, manifest: manifest, output: nil)
        return ValidatedModel(fileURL: fileURL, manifest: manifest)
    }

    private func validateManifest(_ manifest: ModelManifest) throws {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-".utf8)
        guard !manifest.id.isEmpty, manifest.id.utf8.count <= 128,
              manifest.id.utf8.allSatisfy({ allowed.contains($0) }) else {
            throw ModelImportError.invalidManifest("Model ID must contain 1–128 ASCII letters, digits, underscores, or hyphens")
        }
        guard !manifest.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelImportError.invalidManifest("Display name is required")
        }
        guard manifest.expectedByteCount >= 24 else {
            throw ModelImportError.invalidManifest("Expected byte count must include the 24-byte GGUF header")
        }
        let hex = Set("0123456789abcdefABCDEF".utf8)
        guard manifest.sha256.utf8.count == 64, manifest.sha256.utf8.allSatisfy({ hex.contains($0) }) else {
            throw ModelImportError.invalidManifest("An independently reviewed 64-character SHA-256 is required")
        }
        guard manifest.provenance.sourceURL.scheme?.lowercased() == "https",
              manifest.provenance.sourceURL.host?.isEmpty == false,
              manifest.provenance.sourceURL.user == nil,
              manifest.provenance.sourceURL.password == nil,
              !manifest.provenance.revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !manifest.provenance.license.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelImportError.invalidManifest("HTTPS provenance, a pinned revision, and a reviewed license are required")
        }
    }

    private func prepareDirectory() throws -> URL {
        guard modelsDirectory.isFileURL else { throw ModelImportError.fileOperationFailed("use an app-private file directory") }
        do {
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
            let directory = modelsDirectory.standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ModelImportError.fileOperationFailed("verify model directory")
            }
            #if os(iOS)
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var mutableDirectory = directory
            try mutableDirectory.setResourceValues(resourceValues)
            #endif
            return directory
        } catch let error as ModelImportError { throw error }
        catch { throw ModelImportError.fileOperationFailed("prepare model directory") }
    }

    private func openSource(_ sourceURL: URL, manifest: ModelManifest) throws -> FileHandle {
        guard sourceURL.isFileURL else { throw ModelImportError.inaccessibleSource }
        // Bind regular-file and size checks to the opened descriptor, so replacing the
        // selected path cannot switch a checked regular file to a FIFO or symlink.
        let descriptor = sourceURL.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard descriptor >= 0 else { throw ModelImportError.inaccessibleSource }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            var status = stat()
            guard fstat(descriptor, &status) == 0, (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  status.st_size >= 0 else { throw ModelImportError.inaccessibleSource }
            let count = Int64(status.st_size)
            guard count == manifest.expectedByteCount else {
                throw ModelImportError.sizeMismatch(expected: manifest.expectedByteCount, actual: count)
            }
            return input
        } catch {
            try? input.close()
            if let error = error as? ModelImportError { throw error }
            throw ModelImportError.inaccessibleSource
        }
    }

    private func verifyStream(_ input: FileHandle, manifest: ModelManifest, output: FileHandle?) async throws {
        var hasher = StreamingSHA256()
        var count: Int64 = 0
        var header = Data()
        while true {
            try Task.checkCancellation()
            let chunk: Data
            do { chunk = try input.read(upToCount: chunkByteCount) ?? Data() }
            catch { throw ModelImportError.fileOperationFailed("read model") }
            if chunk.isEmpty { break }
            let (newCount, overflow) = count.addingReportingOverflow(Int64(chunk.count))
            guard !overflow else { throw ModelImportError.fileOperationFailed("count model bytes") }
            count = newCount
            guard count <= manifest.expectedByteCount else {
                throw ModelImportError.sizeMismatch(expected: manifest.expectedByteCount, actual: count)
            }
            if header.count < 24 {
                header.append(chunk.prefix(24 - header.count))
                if header.count == 24 { try validateGGUFHeader(header) }
            }
            hasher.update(chunk)
            if let output {
                do { try output.write(contentsOf: chunk) }
                catch { throw ModelImportError.fileOperationFailed("write staging model") }
            }
            await Task.yield()
        }
        try Task.checkCancellation()
        guard count == manifest.expectedByteCount else {
            throw ModelImportError.sizeMismatch(expected: manifest.expectedByteCount, actual: count)
        }
        guard header.count == 24 else { throw ModelImportError.invalidGGUF }
        guard hasher.hexadecimalDigest() == manifest.sha256.lowercased() else { throw ModelImportError.checksumMismatch }
    }

    private func validateGGUFHeader(_ header: Data) throws {
        guard Array(header.prefix(4)) == [0x47, 0x47, 0x55, 0x46] else { throw ModelImportError.invalidGGUF }
        let bytes = Array(header)
        let version = UInt32(bytes[4]) | (UInt32(bytes[5]) << 8) | (UInt32(bytes[6]) << 16) | (UInt32(bytes[7]) << 24)
        guard version == 2 || version == 3 else { throw ModelImportError.unsupportedGGUFVersion(version) }
    }

    private func beginScopedAccess(_ url: URL) -> Bool {
        #if canImport(Darwin)
        return url.startAccessingSecurityScopedResource()
        #else
        return false
        #endif
    }

    private func endScopedAccess(_ url: URL, didAccess: Bool) {
        #if canImport(Darwin)
        if didAccess { url.stopAccessingSecurityScopedResource() }
        #endif
    }
}

#if canImport(CryptoKit)
private struct StreamingSHA256 {
    private var hasher = SHA256()
    mutating func update(_ data: Data) { hasher.update(data: data) }
    mutating func hexadecimalDigest() -> String { hasher.finalize().map { String(format: "%02x", $0) }.joined() }
}
#else
// Dependency-free SHA-256 for non-Apple package tests. Apple production builds use CryptoKit.
private struct StreamingSHA256 {
    private var state: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    private var buffer: [UInt8] = []
    private var byteCount: UInt64 = 0
    private static let constants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    mutating func update(_ data: Data) {
        byteCount &+= UInt64(data.count)
        let bytes = Array(data)
        var offset = 0
        if !buffer.isEmpty {
            let take = min(64 - buffer.count, bytes.count)
            buffer.append(contentsOf: bytes.prefix(take))
            offset = take
            if buffer.count == 64 { compress(buffer[...]); buffer.removeAll(keepingCapacity: true) }
        }
        while offset + 64 <= bytes.count {
            compress(bytes[offset..<(offset + 64)])
            offset += 64
        }
        buffer.append(contentsOf: bytes[offset...])
    }

    mutating func hexadecimalDigest() -> String {
        let bitCount = byteCount &* 8
        buffer.append(0x80)
        while buffer.count % 64 != 56 { buffer.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { buffer.append(UInt8(truncatingIfNeeded: bitCount >> shift)) }
        for offset in stride(from: 0, to: buffer.count, by: 64) { compress(buffer[offset..<(offset + 64)]) }
        return state.map { String(format: "%08x", $0) }.joined()
    }

    private func rotate(_ value: UInt32, _ bits: UInt32) -> UInt32 { (value >> bits) | (value << (32 - bits)) }

    private mutating func compress(_ bytes: ArraySlice<UInt8>) {
        let block = Array(bytes)
        var words = [UInt32](repeating: 0, count: 64)
        for index in 0..<16 {
            let offset = index * 4
            words[index] = (UInt32(block[offset]) << 24) | (UInt32(block[offset + 1]) << 16) | (UInt32(block[offset + 2]) << 8) | UInt32(block[offset + 3])
        }
        for index in 16..<64 {
            let x = words[index - 15], y = words[index - 2]
            let s0 = rotate(x, 7) ^ rotate(x, 18) ^ (x >> 3)
            let s1 = rotate(y, 17) ^ rotate(y, 19) ^ (y >> 10)
            words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
        }
        var a = state[0], b = state[1], c = state[2], d = state[3]
        var e = state[4], f = state[5], g = state[6], h = state[7]
        for index in 0..<64 {
            let sum1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
            let choice = (e & f) ^ (~e & g)
            let t1 = h &+ sum1 &+ choice &+ Self.constants[index] &+ words[index]
            let sum0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let t2 = sum0 &+ majority
            h = g; g = f; f = e; e = d &+ t1
            d = c; c = b; b = a; a = t1 &+ t2
        }
        let result = [a, b, c, d, e, f, g, h]
        for index in 0..<8 { state[index] = state[index] &+ result[index] }
    }
}
#endif
