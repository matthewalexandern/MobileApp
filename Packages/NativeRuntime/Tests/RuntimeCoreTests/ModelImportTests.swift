import Foundation
import Testing
@testable import RuntimeCore

@MainActor
struct ModelImportTests {
    // Synthetic GGUF v3 envelope: one "general.architecture = fixture" metadata
    // entry, zero tensors, and alignment padding. This is deliberately not loadable
    // model weights. Golden hashes were calculated independently with hashlib.
    private let fixtureHash = "8ba89d4604cdf3fc6a5efce18964414e34d2e747291a81c2ed0386efdce168ef"

    @Test func testImportChecksManifestAndCopiesToPrivateDestination() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("user-selection.gguf")
        let bytes = fixture()
        try bytes.write(to: source)
        let models = folder.appendingPathComponent("Models")
        let manifest = manifest()
        let importer = ModelImporter(modelsDirectory: models)

        let imported = try await importer.importModel(from: source, manifest: manifest)

        #expect(imported.manifest == manifest)
        #expect(imported.fileURL == models.resolvingSymlinksInPath().appendingPathComponent("fixture-Q8_0.gguf"))
        #expect(try Data(contentsOf: imported.fileURL) == bytes)
        #expect(try Data(contentsOf: source) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: models.path) == ["fixture-Q8_0.gguf"])
        #expect(try JSONDecoder().decode(ModelManifest.self, from: JSONEncoder().encode(manifest)) == manifest)
    }

    @Test func testQ4RequiresItsExplicitManifestAndUsesDistinctDestination() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("model.gguf")
        try fixture().write(to: source)
        let importer = ModelImporter(modelsDirectory: folder.appendingPathComponent("Models"))

        let imported = try await importer.importModel(from: source, manifest: manifest(quantization: .q4_k_m))

        #expect(imported.manifest.quantization == .q4_k_m)
        #expect(imported.fileURL.lastPathComponent == "fixture-Q4_K_M.gguf")
    }

    @Test func testStreamingChecksumAcrossReadChunks() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("stream.gguf")
        let bytes = fixture() + Data(repeating: 0, count: 1_048_576 + 73)
        try bytes.write(to: source)
        let manifest = manifest(size: Int64(bytes.count), hash: "3032aab3822272f668eb4783145d3983c4382f5ce3b15116858f2502271cb8bb")
        let importer = ModelImporter(modelsDirectory: folder.appendingPathComponent("Models"))

        let imported = try await importer.importModel(from: source, manifest: manifest)

        #expect(try Data(contentsOf: imported.fileURL) == bytes)
    }

    @Test func testWrongChecksumPreservesExistingModelAndCleansStaging() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.gguf")
        try fixture().write(to: source)
        let models = folder.appendingPathComponent("Models")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        let destination = models.appendingPathComponent("fixture-Q8_0.gguf")
        let previous = Data("previous model".utf8)
        try previous.write(to: destination)
        let importer = ModelImporter(modelsDirectory: models)

        do {
            _ = try await importer.importModel(from: source, manifest: manifest(hash: String(repeating: "0", count: 64)))
            Issue.record("An untrusted checksum must fail")
        } catch let error as ModelImportError { #expect(error == .checksumMismatch) }

        #expect(try Data(contentsOf: destination) == previous)
        #expect(try FileManager.default.contentsOfDirectory(atPath: models.path) == ["fixture-Q8_0.gguf"])
    }

    @Test func testSizeMismatchIsRejectedBeforeCopy() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.gguf")
        try fixture().write(to: source)
        let models = folder.appendingPathComponent("Models")
        let importer = ModelImporter(modelsDirectory: models)

        do {
            _ = try await importer.importModel(from: source, manifest: manifest(size: 97))
            Issue.record("Incorrect byte count must fail")
        } catch let error as ModelImportError { #expect(error == .sizeMismatch(expected: 97, actual: 96)) }

        #expect(try FileManager.default.contentsOfDirectory(atPath: models.path).isEmpty)
    }

    @Test func testWrongMagicAndUnsupportedVersionAreRejected() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.gguf")
        let models = folder.appendingPathComponent("Models")
        let importer = ModelImporter(modelsDirectory: models)
        var invalidMagic = fixture()
        invalidMagic[0] = 0
        try invalidMagic.write(to: source)

        do {
            _ = try await importer.importModel(from: source, manifest: manifest())
            Issue.record("Wrong GGUF magic must fail")
        } catch let error as ModelImportError { #expect(error == .invalidGGUF) }

        var invalidVersion = fixture()
        invalidVersion[4] = 1
        try invalidVersion.write(to: source)
        do {
            _ = try await importer.importModel(from: source, manifest: manifest())
            Issue.record("Unsupported GGUF version must fail")
        } catch let error as ModelImportError { #expect(error == .unsupportedGGUFVersion(1)) }

        #expect(try FileManager.default.contentsOfDirectory(atPath: models.path).isEmpty)
    }

    @Test func testUnsafeIDsAndMissingTrustAnchorAreRejectedWithoutCreatingDirectory() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.gguf")
        try fixture().write(to: source)
        let models = folder.appendingPathComponent("Models")
        let importer = ModelImporter(modelsDirectory: models)
        let invalidManifests = [
            manifest(id: "../outside"), manifest(id: "a/b"), manifest(id: "a\\b"),
            manifest(id: "."), manifest(id: ""), manifest(id: "模型"),
            manifest(id: String(repeating: "a", count: 129)), manifest(hash: ""),
            manifest(size: 23),
            manifest(provenance: ModelProvenance(sourceURL: URL(string: "http://example.invalid/source")!, revision: "", license: ""))
        ]
        for invalid in invalidManifests {
            do {
                _ = try await importer.importModel(from: source, manifest: invalid)
                Issue.record("Invalid manifest must fail: \(invalid.id)")
            } catch let error as ModelImportError {
                guard case .invalidManifest = error else {
                    Issue.record("Expected invalidManifest, received \(error)")
                    return
                }
            }
        }
        #expect(!(FileManager.default.fileExists(atPath: models.path)))
        #expect(!(FileManager.default.fileExists(atPath: folder.appendingPathComponent("outside-Q8_0.gguf").path)))
    }

    @Test func testNonLocalAndNonRegularSourcesAreRejected() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let importer = ModelImporter(modelsDirectory: folder.appendingPathComponent("Models"))
        for source in [folder, folder.appendingPathComponent("absent.gguf"), URL(string: "https://example.invalid/model.gguf")!] {
            do {
                _ = try await importer.importModel(from: source, manifest: manifest())
                Issue.record("Only a readable local regular file may be imported")
            } catch let error as ModelImportError { #expect(error == .inaccessibleSource) }
        }
    }

    @Test func testSuccessfulImportAtomicallyReplacesExistingFile() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.gguf")
        try fixture().write(to: source)
        let models = folder.appendingPathComponent("Models")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        let destination = models.appendingPathComponent("fixture-Q8_0.gguf")
        try Data("old".utf8).write(to: destination)
        let importer = ModelImporter(modelsDirectory: models)

        _ = try await importer.importModel(from: source, manifest: manifest())

        #expect(try Data(contentsOf: destination) == fixture())
        #expect(try FileManager.default.contentsOfDirectory(atPath: models.path) == ["fixture-Q8_0.gguf"])
    }

    @Test func testSourceSymlinkIsRejectedWithoutFollowingIt() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("target.gguf")
        try fixture().write(to: target)
        let source = folder.appendingPathComponent("source-link.gguf")
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: target)
        let models = folder.appendingPathComponent("Models")
        let importer = ModelImporter(modelsDirectory: models)

        do {
            _ = try await importer.importModel(from: source, manifest: manifest())
            Issue.record("A source symlink must be rejected")
        } catch let error as ModelImportError { #expect(error == .inaccessibleSource) }

        #expect(try Data(contentsOf: target) == fixture())
        #expect(try FileManager.default.contentsOfDirectory(atPath: models.path).isEmpty)
    }

    @Test func testDestinationSymlinkIsReplacedWithoutModifyingOutsideTarget() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.gguf")
        try fixture().write(to: source)
        let outside = folder.appendingPathComponent("outside.gguf")
        let original = Data("unrelated file".utf8)
        try original.write(to: outside)
        let models = folder.appendingPathComponent("Models")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        let destination = models.appendingPathComponent("fixture-Q8_0.gguf")
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: outside)
        let importer = ModelImporter(modelsDirectory: models)

        _ = try await importer.importModel(from: source, manifest: manifest())

        #expect(try Data(contentsOf: destination) == fixture())
        #expect(try Data(contentsOf: outside) == original)
        #expect(try destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)
    }

    @Test func testValidateExistingDoesNotCopyOrCreateModelDirectory() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("existing.gguf")
        try fixture().write(to: source)
        let models = folder.appendingPathComponent("Models")
        let importer = ModelImporter(modelsDirectory: models)

        let model = try await importer.validateExistingModel(at: source, manifest: manifest())

        #expect(model.fileURL == source)
        #expect(!(FileManager.default.fileExists(atPath: models.path)))
    }

    @Test func testCancelledImportCleansStagingAndPreservesExistingFile() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.gguf")
        let bytes = fixture() + Data(repeating: 0, count: 32 * 1_048_576)
        try bytes.write(to: source)
        let models = folder.appendingPathComponent("Models")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        let destination = models.appendingPathComponent("fixture-Q8_0.gguf")
        let previous = Data("previous model".utf8)
        try previous.write(to: destination)
        let importer = ModelImporter(modelsDirectory: models)
        let largeManifest = manifest(size: Int64(bytes.count), hash: "d1392c063f1879fe53c4d041fc05063b8d159151581300d9dbb7071f68b13305")
        let operation = Task { try await importer.importModel(from: source, manifest: largeManifest) }

        // Wait until the staging file exists so cancellation exercises cleanup during copy.
        var sawStaging = false
        for _ in 0..<10_000 {
            if try FileManager.default.contentsOfDirectory(atPath: models.path).contains(where: { $0.hasSuffix(".importing") }) {
                sawStaging = true
                break
            }
            await Task.yield()
        }
        operation.cancel()
        do {
            _ = try await operation.value
            Issue.record("The in-progress import must honor cancellation")
        } catch is CancellationError {}
        #expect(sawStaging, "Cancellation must happen after staging begins")
        #expect(try Data(contentsOf: destination) == previous)
        #expect(try FileManager.default.contentsOfDirectory(atPath: models.path) == ["fixture-Q8_0.gguf"])
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ModelImportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func manifest(
        id: String = "fixture", quantization: ModelQuantization = .q8_0,
        size: Int64 = 96, hash: String? = nil, provenance: ModelProvenance? = nil
    ) -> ModelManifest {
        ModelManifest(
            id: id, displayName: "Synthetic test fixture", quantization: quantization,
            expectedByteCount: size, sha256: hash ?? fixtureHash,
            provenance: provenance ?? ModelProvenance(
                sourceURL: URL(string: "https://example.invalid/synthetic-test-fixture")!,
                revision: "fixture-v1", license: "Test fixture; no model weights"
            )
        )
    }

    private func fixture() -> Data {
        var bytes = Data([0x47, 0x47, 0x55, 0x46, 3, 0, 0, 0])
        appendLittleEndian(0, to: &bytes) // tensor count
        appendLittleEndian(1, to: &bytes) // metadata entry count
        let key = Data("general.architecture".utf8)
        appendLittleEndian(UInt64(key.count), to: &bytes)
        bytes.append(key)
        bytes.append(contentsOf: [8, 0, 0, 0]) // GGUF metadata type: string
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
