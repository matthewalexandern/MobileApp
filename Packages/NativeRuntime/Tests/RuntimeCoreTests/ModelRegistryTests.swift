import Foundation
import Testing
@testable import RuntimeCore

@MainActor
struct ModelRegistryTests {
    private let fixtureHash = "8ba89d4604cdf3fc6a5efce18964414e34d2e747291a81c2ed0386efdce168ef"

    @Test func testImportPersistsPrivateArtifactAndSelectionAcrossRestart() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try writeSource(in: folder)
        let models = folder.appendingPathComponent("Models")
        let registry = ModelRegistry(modelsDirectory: models)

        let imported = try await registry.importModel(from: source, manifest: manifest())
        let restarted = ModelRegistry(modelsDirectory: models)
        let installed = try await restarted.installedModels()
        let selected = try await restarted.restoreSelectedModel()

        #expect(installed == [manifest()])
        #expect(selected == imported)
        #expect(imported.fileURL.deletingLastPathComponent().deletingLastPathComponent() == models.appendingPathComponent(".artifacts"))
        #expect(UUID(uuidString: imported.fileURL.deletingLastPathComponent().lastPathComponent) != nil)
        #expect(try Data(contentsOf: source) == fixture())
        let metadata = try String(contentsOf: models.appendingPathComponent("catalog.json"), encoding: .utf8)
        #expect(!metadata.contains(source.path))
        #expect(!metadata.contains("fileURL"))
        #expect(!metadata.contains("file://"))
    }

    @Test func testEmptyRegistryDoesNotInventModelOrSelection() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let registry = ModelRegistry(modelsDirectory: folder.appendingPathComponent("Models"))

        #expect(try await registry.installedModels().isEmpty)
        #expect(try await registry.restoreSelectedModel() == nil)
        do {
            _ = try await registry.verifiedModel(id: "fixture", quantization: .q8_0)
            Issue.record("An absent model cannot be selected")
        } catch let error as ModelRegistryError {
            #expect(error == .modelNotInstalled(id: "fixture", quantization: .q8_0))
        }
    }

    @Test func testQ4IsExplicitAndNeverSubstitutedForMissingQ8() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try writeSource(in: folder)
        let models = folder.appendingPathComponent("Models")
        let registry = ModelRegistry(modelsDirectory: models)
        let q4 = try await registry.importModel(from: source, manifest: manifest(quantization: .q4_k_m))
        let originalMetadata = try Data(contentsOf: models.appendingPathComponent("catalog.json"))

        do {
            _ = try await registry.verifiedModel(id: "fixture", quantization: .q8_0)
            Issue.record("Q4 must never silently satisfy a Q8 request")
        } catch let error as ModelRegistryError {
            #expect(error == .modelNotInstalled(id: "fixture", quantization: .q8_0))
        }

        #expect(try Data(contentsOf: models.appendingPathComponent("catalog.json")) == originalMetadata)
        #expect(try await registry.restoreSelectedModel() == q4)
    }

    @Test func testExplicitSelectionPersistsExactQuantization() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try writeSource(in: folder)
        let models = folder.appendingPathComponent("Models")
        let registry = ModelRegistry(modelsDirectory: models)
        let q8 = try await registry.importModel(from: source, manifest: manifest())
        _ = try await registry.importModel(from: source, manifest: manifest(quantization: .q4_k_m))

        #expect(try await registry.restoreSelectedModel()?.manifest.quantization == .q4_k_m)
        #expect(try await registry.verifiedModel(id: "fixture", quantization: .q8_0) == q8)
        let restarted = ModelRegistry(modelsDirectory: models)
        #expect(try await restarted.restoreSelectedModel() == q8)
        #expect(try await restarted.installedModels().count == 2)
    }

    @Test func testReplacementRetainsFormerGenerationForOlderCatalogRecovery() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try writeSource(in: folder)
        let models = folder.appendingPathComponent("Models")
        let registry = ModelRegistry(modelsDirectory: models)
        let first = try await registry.importModel(from: source, manifest: manifest())
        let catalogURL = models.appendingPathComponent("catalog.json")
        let previousCatalog = try Data(contentsOf: catalogURL)
        let generation = first.fileURL.deletingLastPathComponent()
        let unknown = generation.appendingPathComponent("unrelated.txt")
        try Data("preserve".utf8).write(to: unknown)

        let replacement = try await registry.importModel(from: source, manifest: manifest())

        #expect(replacement.fileURL != first.fileURL)
        #expect(try Data(contentsOf: first.fileURL) == fixture())
        #expect(try Data(contentsOf: unknown) == Data("preserve".utf8))
        #expect(try await registry.installedModels() == [manifest()])
        #expect(try await registry.restoreSelectedModel() == replacement)
        // Simulate recovering a formerly committed catalog after filesystem rollback.
        // Both generations remain available; restoring metadata cannot point to an
        // artifact that a successful replacement eagerly deleted.
        try previousCatalog.write(to: catalogURL)
        let restarted = ModelRegistry(modelsDirectory: models)
        #expect(try await restarted.restoreSelectedModel() == first)
        #expect(try Data(contentsOf: replacement.fileURL) == fixture())
    }

    @Test func testRejectedReplacementPreservesCatalogArtifactAndSource() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try writeSource(in: folder)
        let models = folder.appendingPathComponent("Models")
        let registry = ModelRegistry(modelsDirectory: models)
        let original = try await registry.importModel(from: source, manifest: manifest())
        let metadata = try Data(contentsOf: models.appendingPathComponent("catalog.json"))
        let generations = try FileManager.default.contentsOfDirectory(atPath: models.appendingPathComponent(".artifacts").path)

        do {
            _ = try await registry.importModel(from: source, manifest: manifest(hash: String(repeating: "0", count: 64)))
            Issue.record("An untrusted replacement must fail")
        } catch let error as ModelImportError { #expect(error == .checksumMismatch) }

        #expect(try Data(contentsOf: models.appendingPathComponent("catalog.json")) == metadata)
        #expect(try Data(contentsOf: original.fileURL) == fixture())
        #expect(try Data(contentsOf: source) == fixture())
        #expect(try FileManager.default.contentsOfDirectory(atPath: models.appendingPathComponent(".artifacts").path) == generations)
    }

    @Test func testSameSizeTamperingIsRehashedAfterRestart() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try writeSource(in: folder)
        let models = folder.appendingPathComponent("Models")
        let registry = ModelRegistry(modelsDirectory: models)
        let imported = try await registry.importModel(from: source, manifest: manifest())
        let metadata = try Data(contentsOf: models.appendingPathComponent("catalog.json"))
        var tampered = fixture()
        tampered[tampered.count - 1] = 1
        try tampered.write(to: imported.fileURL)
        let restarted = ModelRegistry(modelsDirectory: models)

        // Listing does not read/checksum weights; restore always does.
        #expect(try await restarted.installedModels() == [manifest()])
        do {
            _ = try await restarted.restoreSelectedModel()
            Issue.record("Persisted metadata cannot bypass a fresh checksum")
        } catch let error as ModelRegistryError {
            #expect(error == .artifactVerificationFailed(id: "fixture", quantization: .q8_0, cause: .checksumMismatch))
        }
        #expect(try Data(contentsOf: models.appendingPathComponent("catalog.json")) == metadata)
        #expect(try Data(contentsOf: source) == fixture())
    }

    @Test func testFailedSelectionDoesNotReplacePreviouslySelectedQuantization() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try writeSource(in: folder)
        let models = folder.appendingPathComponent("Models")
        let registry = ModelRegistry(modelsDirectory: models)
        let q8 = try await registry.importModel(from: source, manifest: manifest())
        let q4 = try await registry.importModel(from: source, manifest: manifest(quantization: .q4_k_m))
        let metadata = try Data(contentsOf: models.appendingPathComponent("catalog.json"))
        var tampered = fixture()
        tampered[tampered.count - 1] = 1
        try tampered.write(to: q8.fileURL)

        do {
            _ = try await registry.verifiedModel(id: "fixture", quantization: .q8_0)
            Issue.record("Failed verification cannot update selection")
        } catch let error as ModelRegistryError {
            #expect(error == .artifactVerificationFailed(id: "fixture", quantization: .q8_0, cause: .checksumMismatch))
        }
        #expect(try Data(contentsOf: models.appendingPathComponent("catalog.json")) == metadata)
        #expect(try await registry.restoreSelectedModel() == q4)
    }

    @Test func testMissingArtifactIsReportedWithoutResettingCatalog() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try writeSource(in: folder)
        let models = folder.appendingPathComponent("Models")
        let registry = ModelRegistry(modelsDirectory: models)
        let imported = try await registry.importModel(from: source, manifest: manifest())
        let metadata = try Data(contentsOf: models.appendingPathComponent("catalog.json"))
        try FileManager.default.removeItem(at: imported.fileURL)

        do {
            _ = try await registry.restoreSelectedModel()
            Issue.record("Missing artifacts cannot be restored")
        } catch let error as ModelRegistryError {
            #expect(error == .artifactUnavailable(id: "fixture", quantization: .q8_0))
        }
        #expect(try Data(contentsOf: models.appendingPathComponent("catalog.json")) == metadata)
    }

    @Test func testCorruptCatalogRejectsImportWithoutChangingExistingData() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try writeSource(in: folder)
        let models = folder.appendingPathComponent("Models")
        let registry = ModelRegistry(modelsDirectory: models)
        let imported = try await registry.importModel(from: source, manifest: manifest())
        let corrupted = Data("corrupted metadata".utf8)
        try corrupted.write(to: models.appendingPathComponent("catalog.json"))

        do {
            _ = try await registry.importModel(from: source, manifest: manifest())
            Issue.record("Corrupt metadata must not be silently reset")
        } catch let error as ModelRegistryError {
            #expect(error == .invalidCatalog("metadata could not be decoded"))
        }
        #expect(try Data(contentsOf: models.appendingPathComponent("catalog.json")) == corrupted)
        #expect(try Data(contentsOf: imported.fileURL) == fixture())
    }

    @Test func testCatalogCannotNameOutsideArtifactDirectory() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try writeSource(in: folder)
        let models = folder.appendingPathComponent("Models")
        let registry = ModelRegistry(modelsDirectory: models)
        _ = try await registry.importModel(from: source, manifest: manifest())
        let catalogURL = models.appendingPathComponent("catalog.json")
        var catalog = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])
        var entries = try #require(catalog["entries"] as? [[String: Any]])
        entries[0]["artifactIdentifier"] = "../../outside"
        catalog["entries"] = entries
        let unsafe = try JSONSerialization.data(withJSONObject: catalog)
        try unsafe.write(to: catalogURL)

        do {
            _ = try await registry.installedModels()
            Issue.record("Catalog references must be UUIDs, never paths")
        } catch let error as ModelRegistryError {
            #expect(error == .invalidCatalog("invalid or duplicate artifact identity"))
        }
        #expect(try Data(contentsOf: catalogURL) == unsafe)
        #expect(try Data(contentsOf: source) == fixture())
    }

    @Test func testArtifactAndCatalogSymlinksDoNotFollowExternalFiles() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try writeSource(in: folder)
        let models = folder.appendingPathComponent("Models")
        let registry = ModelRegistry(modelsDirectory: models)
        let imported = try await registry.importModel(from: source, manifest: manifest())
        try FileManager.default.removeItem(at: imported.fileURL)
        try FileManager.default.createSymbolicLink(at: imported.fileURL, withDestinationURL: source)

        do {
            _ = try await registry.restoreSelectedModel()
            Issue.record("Installed symlinks cannot become native model paths")
        } catch let error as ModelRegistryError {
            #expect(error == .artifactUnavailable(id: "fixture", quantization: .q8_0))
        }

        let catalogURL = models.appendingPathComponent("catalog.json")
        let catalogBytes = try Data(contentsOf: catalogURL)
        let outsideCatalog = folder.appendingPathComponent("outside.json")
        try catalogBytes.write(to: outsideCatalog)
        try FileManager.default.removeItem(at: catalogURL)
        try FileManager.default.createSymbolicLink(at: catalogURL, withDestinationURL: outsideCatalog)
        do {
            _ = try await registry.installedModels()
            Issue.record("Catalog symlinks cannot be read")
        } catch let error as ModelRegistryError {
            #expect(error == .invalidCatalog("metadata is not a readable regular file"))
        }
        #expect(try Data(contentsOf: outsideCatalog) == catalogBytes)
        #expect(try Data(contentsOf: source) == fixture())
    }

    @Test func testCatalogRejectsArtifactUUIDCaseAliases() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try writeSource(in: folder)
        let models = folder.appendingPathComponent("Models")
        let registry = ModelRegistry(modelsDirectory: models)
        _ = try await registry.importModel(from: source, manifest: manifest())
        let catalogURL = models.appendingPathComponent("catalog.json")
        var catalog = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])
        var entries = try #require(catalog["entries"] as? [[String: Any]])
        var alias = entries[0]
        var aliasManifest = try #require(alias["manifest"] as? [String: Any])
        aliasManifest["quantization"] = ModelQuantization.q4_k_m.rawValue
        alias["manifest"] = aliasManifest
        alias["artifactIdentifier"] = try #require(alias["artifactIdentifier"] as? String).lowercased()
        entries.append(alias)
        catalog["entries"] = entries
        let aliased = try JSONSerialization.data(withJSONObject: catalog)
        try aliased.write(to: catalogURL)

        do {
            _ = try await registry.installedModels()
            Issue.record("UUID case aliases cannot refer to one generation twice on Apple filesystems")
        } catch let error as ModelRegistryError {
            #expect(error == .invalidCatalog("invalid or duplicate artifact identity"))
        }
        #expect(try Data(contentsOf: catalogURL) == aliased)
    }

    @Test func testModelAndArtifactsDirectorySymlinksAreRejected() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let outside = folder.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let models = folder.appendingPathComponent("Models")
        try FileManager.default.createSymbolicLink(at: models, withDestinationURL: outside)
        let registry = ModelRegistry(modelsDirectory: models)
        do {
            _ = try await registry.installedModels()
            Issue.record("Model directory cannot be a symlink")
        } catch let error as ModelRegistryError { #expect(error == .invalidDirectory) }

        try FileManager.default.removeItem(at: models)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: models.appendingPathComponent(".artifacts"), withDestinationURL: outside)
        do {
            _ = try await registry.installedModels()
            Issue.record("Artifacts directory cannot be a symlink")
        } catch let error as ModelRegistryError { #expect(error == .invalidDirectory) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func testLegacyUncatalogedFilesAreNeverTrustedOrDeleted() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let models = folder.appendingPathComponent("Models")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        let legacy = models.appendingPathComponent("fixture-Q8_0.gguf")
        try fixture().write(to: legacy)
        let registry = ModelRegistry(modelsDirectory: models)

        #expect(try await registry.installedModels().isEmpty)
        #expect(try await registry.restoreSelectedModel() == nil)
        #expect(try Data(contentsOf: legacy) == fixture())
    }

    @Test func testCancelledImportAndOverlappingRegistriesPreserveCommittedGeneration() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try writeSource(in: folder)
        let models = folder.appendingPathComponent("Models")
        let initial = ModelRegistry(modelsDirectory: models)
        let original = try await initial.importModel(from: source, manifest: manifest())
        let metadata = try Data(contentsOf: models.appendingPathComponent("catalog.json"))
        let artifacts = models.appendingPathComponent(".artifacts")
        let checkpoint = RegistryCopyCheckpoint()
        let registry = ModelRegistry(modelsDirectory: models, importerFactory: { directory in
            ModelImporter(modelsDirectory: directory, copyCheckpoint: { await checkpoint.pause() })
        })
        let importing = Task {
            do {
                let model = try await registry.importModel(from: source, manifest: manifest())
                await checkpoint.finished()
                return model
            } catch {
                await checkpoint.finished()
                throw error
            }
        }
        do {
            let paused = await checkpoint.waitUntilPaused()
            try #require(paused, "The import must pause after successfully writing a staging chunk")
            #expect(try Data(contentsOf: stagingFile(in: artifacts)) == fixture())
            let concurrent = ModelRegistry(modelsDirectory: models)
            do {
                _ = try await concurrent.installedModels()
                Issue.record("Other registry instances cannot race an import")
            } catch let error as ModelRegistryError { #expect(error == .operationInProgress) }
            do {
                _ = try await registry.installedModels()
                Issue.record("Actor reentrancy cannot race the owned catalog")
            } catch let error as ModelRegistryError { #expect(error == .operationInProgress) }
            importing.cancel()
            await checkpoint.release()
            do {
                _ = try await importing.value
                Issue.record("Import must honor cancellation")
            } catch is CancellationError {}

            #expect(try Data(contentsOf: models.appendingPathComponent("catalog.json")) == metadata)
            #expect(try await concurrent.restoreSelectedModel() == original)
            #expect(try FileManager.default.contentsOfDirectory(atPath: artifacts.path) == [original.fileURL.deletingLastPathComponent().lastPathComponent])
        } catch {
            // Always settle the owned task before fixture teardown, including when
            // a filesystem assertion/setup operation throws while import is paused.
            importing.cancel()
            await checkpoint.release()
            _ = try? await importing.value
            throw error
        }
    }

    @Test func testMetadataCommitFailureCannotReplacePreviousModelOrManifest() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try writeSource(in: folder)
        let models = folder.appendingPathComponent("Models")
        let initial = ModelRegistry(modelsDirectory: models)
        let original = try await initial.importModel(from: source, manifest: manifest())
        let catalogURL = models.appendingPathComponent("catalog.json")
        let metadata = try Data(contentsOf: catalogURL)
        let savedCatalog = models.appendingPathComponent("saved-catalog.json")
        let artifacts = models.appendingPathComponent(".artifacts")
        let checkpoint = RegistryCopyCheckpoint()
        let registry = ModelRegistry(modelsDirectory: models, importerFactory: { directory in
            ModelImporter(modelsDirectory: directory, copyCheckpoint: { await checkpoint.pause() })
        })
        let importing = Task {
            do {
                let model = try await registry.importModel(from: source, manifest: manifest())
                await checkpoint.finished()
                return model
            } catch {
                await checkpoint.finished()
                throw error
            }
        }
        do {
            let paused = await checkpoint.waitUntilPaused()
            try #require(paused, "The import must pause after successfully writing a staging chunk")
            #expect(try Data(contentsOf: stagingFile(in: artifacts)) == fixture())
            // Force rename failure after the transaction read its catalog. The
            // original metadata and its generation remain available for recovery.
            try FileManager.default.moveItem(at: catalogURL, to: savedCatalog)
            try FileManager.default.createDirectory(at: catalogURL, withIntermediateDirectories: false)
            await checkpoint.release()

            do {
                _ = try await importing.value
                Issue.record("A failed metadata commit must fail the import")
            } catch let error as ModelRegistryError {
                #expect(error == .fileOperationFailed("atomically install catalog"))
            }
            #expect(try Data(contentsOf: savedCatalog) == metadata)
            #expect(try Data(contentsOf: original.fileURL) == fixture())
            #expect(try FileManager.default.contentsOfDirectory(atPath: artifacts.path) == [original.fileURL.deletingLastPathComponent().lastPathComponent])
            try FileManager.default.removeItem(at: catalogURL)
            try FileManager.default.moveItem(at: savedCatalog, to: catalogURL)
            #expect(try await registry.restoreSelectedModel() == original)
        } catch {
            importing.cancel()
            await checkpoint.release()
            _ = try? await importing.value
            throw error
        }
    }

    private func stagingFile(in artifacts: URL) throws -> URL {
        let paths = FileManager.default.enumerator(atPath: artifacts.path)?.allObjects.compactMap { $0 as? String } ?? []
        let staging = try #require(paths.first(where: { $0.hasSuffix(".importing") }))
        return artifacts.appendingPathComponent(staging)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ModelRegistryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeSource(in folder: URL) throws -> URL {
        let source = folder.appendingPathComponent("source.gguf")
        try fixture().write(to: source)
        return source
    }

    private func manifest(quantization: ModelQuantization = .q8_0, size: Int64 = 96, hash: String? = nil) -> ModelManifest {
        ModelManifest(
            id: "fixture", displayName: "Synthetic test fixture", quantization: quantization,
            expectedByteCount: size, sha256: hash ?? fixtureHash,
            provenance: ModelProvenance(
                sourceURL: URL(string: "https://example.invalid/synthetic-test-fixture")!,
                revision: "fixture-v1", license: "Test fixture; no model weights"
            )
        )
    }

    /// Synthetic GGUF envelope, never loadable model weights. Hashes independently
    /// calculated with hashlib and shared with ModelImportTests' existing fixture.
    private func fixture() -> Data {
        var bytes = Data([0x47, 0x47, 0x55, 0x46, 3, 0, 0, 0])
        appendLittleEndian(0, to: &bytes)
        appendLittleEndian(1, to: &bytes)
        let key = Data("general.architecture".utf8)
        appendLittleEndian(UInt64(key.count), to: &bytes)
        bytes.append(key)
        bytes.append(contentsOf: [8, 0, 0, 0])
        let value = Data("fixture".utf8)
        appendLittleEndian(UInt64(value.count), to: &bytes)
        bytes.append(value)
        while bytes.count % 32 != 0 { bytes.append(0) }
        return bytes
    }

    private func appendLittleEndian(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 0, through: 56, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
}

/// A checkpoint inside a real staging write, independent of file size, hashing
/// speed, and executor scheduling. All test failure paths release the held import.
private actor RegistryCopyCheckpoint {
    private var reached = false
    private var completed = false
    private var released = false
    private var arrivalWaiters: [CheckedContinuation<Bool, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        reached = true
        let waiting = arrivalWaiters
        arrivalWaiters.removeAll()
        for continuation in waiting { continuation.resume(returning: true) }
        if released { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilPaused() async -> Bool {
        if reached { return true }
        if completed { return false }
        return await withCheckedContinuation { continuation in
            arrivalWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiting = releaseWaiters
        releaseWaiters.removeAll()
        for continuation in waiting { continuation.resume() }
    }

    func finished() {
        completed = true
        let waiting = arrivalWaiters
        arrivalWaiters.removeAll()
        for continuation in waiting { continuation.resume(returning: reached) }
    }
}
