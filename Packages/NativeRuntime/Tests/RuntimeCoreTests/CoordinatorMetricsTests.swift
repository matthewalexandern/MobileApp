import Foundation
import Testing
@testable import RuntimeCore

struct CoordinatorMetricsTests {
    @Test func preservesNativeTimingsAndThroughputAfterCheckingTokenEvents() async throws {
        let metrics = InferenceMetrics(generatedTokenCount: 2, timeToFirstTokenSeconds: 0.25, durationSeconds: 0.75, generationDurationSeconds: 0.5)
        let runtime = RuntimeCoordinator(engine: MetricsEngine(events: [.token(""), .token("text"), .finished(metrics)]))
        try await runtime.load(model: MockInferenceEngine.demonstrationModel)
        var result: InferenceMetrics?
        for try await event in try await runtime.generate(request: .init(prompt: "fixture")) {
            if case .finished(let value) = event { result = value }
        }
        #expect(result == metrics)
        #expect(result?.tokensPerSecond == 4)
        #expect((await runtime.snapshot()).metrics == metrics)
    }

    @Test func rejectsNonFiniteAndInconsistentMetrics() async throws {
        for metrics in [
            InferenceMetrics(generatedTokenCount: 2, timeToFirstTokenSeconds: 0.1, durationSeconds: 0.2),
            InferenceMetrics(generatedTokenCount: 1, timeToFirstTokenSeconds: .nan, durationSeconds: 0.2),
            InferenceMetrics(generatedTokenCount: 1, timeToFirstTokenSeconds: 0.3, durationSeconds: 0.2),
            InferenceMetrics(generatedTokenCount: 1, timeToFirstTokenSeconds: 0.1, durationSeconds: 0.2, generationDurationSeconds: 0.3)
        ] {
            let runtime = RuntimeCoordinator(engine: MetricsEngine(events: [.token("text"), .finished(metrics)]))
            try await runtime.load(model: MockInferenceEngine.demonstrationModel)
            do {
                for try await _ in try await runtime.generate(request: .init(prompt: "fixture")) {}
                Issue.record("Invalid engine metrics must be rejected")
            } catch {
                #expect(error as? RuntimeError == .engineFailure(operation: "generation metrics"))
            }
        }
    }

    @Test func duplicateTerminalEventsAndLaterTokensAreRejected() async throws {
        let metrics = InferenceMetrics(generatedTokenCount: 1, timeToFirstTokenSeconds: 0.1, durationSeconds: 0.2)
        for suffix: InferenceEvent in [.finished(metrics), .token("late")] {
            let runtime = RuntimeCoordinator(engine: MetricsEngine(events: [.token("text"), .finished(metrics), suffix]))
            try await runtime.load(model: MockInferenceEngine.demonstrationModel)
            await #expect(throws: RuntimeError.self) {
                for try await _ in try await runtime.generate(request: .init(prompt: "fixture")) {}
            }
        }
    }

    @Test func demonstrationAndZeroDurationHaveNoNativeThroughput() {
        #expect(InferenceMetrics(generatedTokenCount: 4, timeToFirstTokenSeconds: 0.1, durationSeconds: 0.2).tokensPerSecond == nil)
        #expect(InferenceMetrics(generatedTokenCount: 0, timeToFirstTokenSeconds: nil, durationSeconds: 0, generationDurationSeconds: 0).tokensPerSecond == nil)
    }
}

private struct MetricsEngine: InferenceEngine {
    let mode = InferenceMode.local
    let events: [InferenceEvent]
    func load(model: ValidatedModel, configuration: InferenceConfiguration) async throws {}
    func unload() async {}
    func generate(request: InferenceRequest) async throws -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}
