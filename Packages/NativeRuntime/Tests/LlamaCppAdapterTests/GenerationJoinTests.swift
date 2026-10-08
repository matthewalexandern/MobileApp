import Foundation
import Testing
import RuntimeCore
@testable import LlamaCppAdapter

/// The gate represents a decode batch/GPU synchronization that cannot finish
/// immediately when stream iteration is cancelled. No model or GPU is used.
struct GenerationJoinTests {
    @Test func consumerCancellationKeepsCoordinatorBusyUntilNativeJoin() async throws {
        let backend = DelayedGenerationJoinBackend()
        let runtime = RuntimeCoordinator(engine: LlamaCppInferenceEngine(backend: backend))
        try await runtime.load(model: fixture())
        let stream = try await runtime.generate(request: .init(prompt: "first"))
        let consumer = Task { for try await _ in stream {} }
        await backend.waitForGenerationStart()
        consumer.cancel()
        _ = await consumer.result
        await backend.waitForCancellationStart()
        let cancellation = Task { await runtime.cancelGeneration() }

        #expect((await runtime.snapshot()).isGenerating)
        #expect(await backend.isGenerating)
        do {
            _ = try await runtime.generate(request: .init(prompt: "too early"))
            Issue.record("A new request must be refused while native cancellation is joining")
        } catch {
            #expect(error as? RuntimeError == .invalidState(operation: "generate", state: "generating"))
        }

        await backend.releaseCancellationJoin()
        await cancellation.value
        #expect(!(await runtime.snapshot()).isGenerating)
        #expect((await runtime.snapshot()).state == .ready)
        var text = ""
        for try await event in try await runtime.generate(request: .init(prompt: "after join")) {
            if case .token(let token) = event { text += token }
        }
        #expect(text == "after join")
        await runtime.unload()
        #expect(!(await backend.unloadedDuringGeneration))
    }

    @Test func timeoutAlsoJoinsNativeWorkBeforeCompleting() async throws {
        let backend = DelayedGenerationJoinBackend()
        let runtime = RuntimeCoordinator(
            engine: LlamaCppInferenceEngine(backend: backend),
            configuration: .init(generationTimeoutSeconds: 0.05)
        )
        try await runtime.load(model: fixture())
        let stream = try await runtime.generate(request: .init(prompt: "first"))
        let consumer = Task { for try await _ in stream {} }
        await backend.waitForCancellationStart()
        #expect((await runtime.snapshot()).isGenerating)
        #expect(await backend.isGenerating)
        await backend.releaseCancellationJoin()
        do {
            try await consumer.value
            Issue.record("The blocked generation must time out")
        } catch {
            #expect(error as? RuntimeError == .resourceLimit(reason: "Generation exceeded the configured time limit."))
        }
        #expect(!(await runtime.snapshot()).isGenerating)
        #expect((await runtime.snapshot()).state == .ready)
        var tokens = 0
        for try await event in try await runtime.generate(request: .init(prompt: "after join")) {
            if case .token = event { tokens += 1 }
        }
        #expect(tokens == 1)
        await runtime.unload()
        #expect(!(await backend.unloadedDuringGeneration))
    }

    @Test func repeatedEngineCancellationSharesJoinAndAllowsNextRequest() async throws {
        let backend = DelayedGenerationJoinBackend()
        let engine = LlamaCppInferenceEngine(backend: backend)
        try await engine.load(model: fixture(), configuration: .init())
        let stream = try await engine.generate(request: .init(prompt: "first"))
        let consumer = Task { for try await _ in stream {} }
        let first = Task { await engine.cancelGeneration() }
        await backend.waitForCancellationStart()
        let repeated = Task { await engine.cancelGeneration() }
        await #expect(throws: RuntimeError.self) {
            _ = try await engine.generate(request: .init(prompt: "too early"))
        }
        await backend.releaseCancellationJoin()
        await first.value
        await repeated.value
        _ = await consumer.result
        var text = ""
        for try await event in try await engine.generate(request: .init(prompt: "after join")) {
            if case .token(let token) = event { text += token }
        }
        #expect(text == "after join")
        await engine.unload()
        #expect(!(await backend.unloadedDuringGeneration))
    }

    private func fixture() -> ValidatedModel {
        ValidatedModel(
            fileURL: URL(fileURLWithPath: "/synthetic/join-fixture.gguf"),
            manifest: .init(
                id: "join-fixture", displayName: "Synthetic cancellation fixture", quantization: .q4_k_m,
                expectedByteCount: 24, sha256: String(repeating: "0", count: 64),
                provenance: .init(sourceURL: URL(string: "https://example.invalid/fixture")!, revision: "test", license: "Test only")
            )
        )
    }
}

private actor DelayedGenerationJoinBackend: LlamaCppBackend {
    private var firstGenerationID: UUID?
    private var firstOutput: AsyncThrowingStream<InferenceEvent, Error>.Continuation?
    private var cancellationStarted = false
    private var joinReleased = false
    private var generationWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var joinWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var isGenerating = false
    private(set) var unloadedDuringGeneration = false

    func load(model: ValidatedModel, configuration: InferenceConfiguration, acceleration: LlamaCppAcceleration) async throws {}

    func unload() async {
        unloadedDuringGeneration = unloadedDuringGeneration || isGenerating
    }

    func generate(request: InferenceRequest, generationID: UUID) async throws -> AsyncThrowingStream<InferenceEvent, Error> {
        if firstGenerationID != nil {
            return AsyncThrowingStream { continuation in
                continuation.yield(.token("after join"))
                continuation.finish()
            }
        }
        firstGenerationID = generationID
        isGenerating = true
        let stream = AsyncThrowingStream<InferenceEvent, Error> { firstOutput = $0 }
        for waiter in generationWaiters { waiter.resume() }
        generationWaiters.removeAll()
        return stream
    }

    func cancelGeneration(generationID: UUID) async {
        guard generationID == firstGenerationID, isGenerating else { return }
        cancellationStarted = true
        for waiter in cancellationWaiters { waiter.resume() }
        cancellationWaiters.removeAll()
        if !joinReleased {
            await withCheckedContinuation { joinWaiters.append($0) }
        }
        isGenerating = false
        firstOutput?.finish(throwing: CancellationError())
        firstOutput = nil
    }

    func waitForGenerationStart() async {
        if firstGenerationID != nil { return }
        await withCheckedContinuation { generationWaiters.append($0) }
    }

    func waitForCancellationStart() async {
        if cancellationStarted { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }

    func releaseCancellationJoin() {
        joinReleased = true
        for waiter in joinWaiters { waiter.resume() }
        joinWaiters.removeAll()
    }
}
