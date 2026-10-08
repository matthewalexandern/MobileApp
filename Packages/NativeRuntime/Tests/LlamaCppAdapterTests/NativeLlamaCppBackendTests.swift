#if canImport(llama)
import Foundation
import Testing
import RuntimeCore
import llama
@testable import LlamaCppAdapter

/// Native-linked failure-path tests need no model weights. Successful inference
/// and Metal placement still require the separately documented device gates.
struct NativeLlamaCppBackendTests {
    @Test func pinnedTemplateAPIFormatsHarmonyAndRejectsUnknownTemplates() {
        "user".withCString { role in
            "hello".withCString { content in
                var message = llama_chat_message(role: role, content: content)
                "gpt-oss".withCString { template in
                    let count = llama_chat_apply_template(template, &message, 1, true, nil, 0)
                    #expect(count > 0)
                    guard count > 0 else { return }
                    var bytes = [CChar](repeating: 0, count: Int(count) + 1)
                    let actual = llama_chat_apply_template(template, &message, 1, true, &bytes, Int32(bytes.count))
                    #expect(actual == count)
                    let text = String(decoding: bytes.prefix(Int(count)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    #expect(text == "<|start|>user<|message|>hello<|end|><|start|>assistant")
                }
                "unsupported-template-with-no-markers".withCString { template in
                    #expect(llama_chat_apply_template(template, &message, 1, true, nil, 0) < 0)
                }
            }
        }
    }

    @Test func failedNativeLoadsReleasePartialResourcesAndAllowAnotherAttempt() async {
        let first = NativeLlamaCppBackend()
        let second = NativeLlamaCppBackend()
        for backend in [first, second, first] {
            do {
                try await backend.load(model: missingModel(), configuration: .init(), acceleration: .cpu)
                Issue.record("A missing GGUF must fail native loading.")
            } catch {
                #expect(error as? NativeLlamaCppError == .modelLoadFailed)
            }
            await backend.unload()
            await backend.unload()
        }
    }

    @Test func preOpenCancellationStopsThatIDWithoutLoadingOrDecoding() async {
        let backend = NativeLlamaCppBackend()
        let generationID = UUID()
        await backend.cancelGeneration(generationID: generationID)
        do {
            _ = try await backend.generate(request: .init(prompt: "test"), generationID: generationID)
            Issue.record("A previously cancelled generation must fail before opening.")
        } catch { #expect(error is CancellationError) }
        await backend.unload()
    }

    @Test func unsupportedContextFailsBeforeModelLoading() async {
        let backend = NativeLlamaCppBackend()
        do {
            try await backend.load(model: missingModel(), configuration: .init(contextSize: 4_096), acceleration: .cpu)
            Issue.record("Unbenchmarked contexts must not allocate native resources.")
        } catch { #expect(error as? NativeLlamaCppError == .unsupportedContext) }
        await backend.unload()
    }

    private func missingModel() -> ValidatedModel {
        ValidatedModel(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gguf"),
            manifest: ModelManifest(
                id: "native-failure-fixture", displayName: "Native failure fixture", quantization: .q8_0,
                expectedByteCount: 24, sha256: String(repeating: "0", count: 64),
                provenance: ModelProvenance(sourceURL: URL(string: "https://example.invalid/model")!, revision: "test", license: "MIT")
            )
        )
    }
}
#endif
