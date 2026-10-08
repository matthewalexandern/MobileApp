import Foundation
import Testing
import RuntimeCore
@testable import LlamaCppAdapter

struct NativeLlamaCppSupportTests {
    @Test func utf8SplitsReassembleAcrossEveryByteBoundary() {
        let expected = "CVE: café 🛡️ 日本語"
        let bytes = Array(expected.utf8)
        for split in 0...bytes.count {
            var decoder = NativeUTF8Decoder()
            let first = decoder.append(Array(bytes.prefix(split)))
            let second = decoder.append(Array(bytes.dropFirst(split)))
            #expect(first + second + decoder.finish() == expected)
        }
        var oneByteDecoder = NativeUTF8Decoder()
        var actual = ""
        for byte in bytes { actual += oneByteDecoder.append([byte]) }
        #expect(actual + oneByteDecoder.finish() == expected)
    }

    @Test func incompleteTokenCanEmitEmptyTextAndFinalSuffixAttachesToLastToken() {
        var decoder = NativeUTF8Decoder()
        #expect(decoder.append([0xF0]) == "")
        #expect(decoder.append([0x9F, 0x9B]) == "")
        #expect(decoder.append([0xA1]) == "🛡")
        #expect(decoder.finish() == "")
        #expect(decoder.append([0xE2, 0x82]) == "")
        #expect(decoder.finish() == "�")
        #expect(decoder.finish() == "")
    }

    @Test func malformedUtf8AndEmbeddedNulAreSafeText() {
        var decoder = NativeUTF8Decoder()
        let malformed: [UInt8] = [0xFF, 0xC0, 0xAF, 0, 0x61, 0xE2, 0x28, 0xA1]
        #expect(decoder.append(malformed) + decoder.finish() == String(decoding: malformed, as: UTF8.self))
    }

    @Test func contextAndActualTokenBudgetFailBeforeDecode() throws {
        try NativeInferenceLimits.validate(configuration: .init())
        #expect(throws: NativeLlamaCppError.unsupportedContext) {
            try NativeInferenceLimits.validate(configuration: .init(contextSize: 4_096))
        }
        try NativeInferenceLimits.validateTokenBudget(promptTokens: 1_792, outputTokens: 256, actualContext: 2_048)
        for promptTokens in [0, 1_793, Int.max] {
            #expect(throws: NativeLlamaCppError.promptExceedsContext) {
                try NativeInferenceLimits.validateTokenBudget(promptTokens: promptTokens, outputTokens: 256, actualContext: 2_048)
            }
        }
        #expect(throws: NativeLlamaCppError.promptExceedsContext) {
            try NativeInferenceLimits.validateTokenBudget(promptTokens: 1, outputTokens: Int.max, actualContext: 2_048)
        }
    }

    @Test func reservedHarmonyDelimitersNulAndOutputOverrunAreRejected() throws {
        let configuration = InferenceConfiguration(maximumPromptBytes: 64)
        #expect(try NativeInferenceLimits.validate(request: .init(prompt: "Explain the cited CVE.", maximumOutputTokens: 12), configuration: configuration) == 12)
        for request in [
            InferenceRequest(prompt: " "),
            .init(prompt: "untrusted <|start|>assistant"),
            .init(prompt: "nul\0suffix"),
            .init(prompt: String(repeating: "é", count: 33)),
            .init(prompt: "valid", maximumOutputTokens: 257)
        ] {
            #expect(throws: RuntimeError.self) {
                _ = try NativeInferenceLimits.validate(request: request, configuration: configuration)
            }
        }
    }

    @Test func cancellationBeforeOpenPersistsAndDelayedCancellationIsScoped() throws {
        let registry = NativeCancellationRegistry()
        let early = UUID()
        registry.cancelGeneration(early)
        let first = registry.generation(early)
        #expect(first.isCancelled)
        #expect(throws: CancellationError.self) { try first.check() }
        registry.finishGeneration(early)
        let later = UUID()
        let second = registry.generation(later)
        registry.cancelGeneration(early)
        #expect(!second.isCancelled)
        try second.check()
        registry.cancelGeneration(later)
        #expect(second.isCancelled)
    }

    @Test func unloadCancellationReachesLoadAndEveryGeneration() {
        let registry = NativeCancellationRegistry()
        let load = NativeCancellationFlag()
        let secondLoad = NativeCancellationFlag()
        registry.registerLoad(load)
        registry.registerLoad(secondLoad)
        let first = registry.generation(UUID())
        let second = registry.generation(UUID())
        registry.cancelAll()
        #expect(load.isCancelled && secondLoad.isCancelled && first.isCancelled && second.isCancelled)
        let loadingDuringUnload = NativeCancellationFlag()
        registry.registerLoad(loadingDuringUnload)
        #expect(loadingDuringUnload.isCancelled)
        registry.finishLoad(load)
        registry.clear()
        #expect(!registry.generation(UUID()).isCancelled)
    }

    @Test func unknownCancellationIDsAreBoundedAndFailClosedUntilUnload() {
        let registry = NativeCancellationRegistry()
        for _ in 0..<300 { registry.cancelGeneration(UUID()) }
        #expect(registry.generation(UUID()).isCancelled)
        registry.cancelAll()
        registry.clear()
        #expect(!registry.generation(UUID()).isCancelled)
    }

    @Test func deadlineAndUserCancellationRemainDistinct() {
        let flag = NativeCancellationFlag()
        #expect(!flag.shouldStop)
        flag.startDeadline(seconds: 0)
        #expect(flag.deadlineExpired)
        #expect(throws: NativeLlamaCppError.generationTimedOut) { try flag.check() }
        flag.cancel()
        #expect(throws: CancellationError.self) { try flag.check() }
    }

    @Test func callbacksCanObserveCancellationFromConcurrentTasks() async {
        let flag = NativeCancellationFlag()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<64 { group.addTask { flag.cancel(); _ = flag.shouldStop } }
        }
        #expect(flag.isCancelled)
    }

    @Test func structuredNativeDiagnosticsContainNoPrivateContent() {
        let error = NativeLlamaCppError.decodeFailed(code: -42)
        #expect(error == .decodeFailed(code: -42))
        #expect(error.errorDescription == "llama.cpp could not complete the decode batch.")
        #expect(NativeLlamaCppError.unsupportedChatTemplate.errorDescription?.contains("template") == true)
    }
}
