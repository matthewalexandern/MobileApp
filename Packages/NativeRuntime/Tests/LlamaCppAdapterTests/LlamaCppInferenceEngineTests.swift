import Foundation
import Testing
import RuntimeCore
@testable import LlamaCppAdapter

struct LlamaCppInferenceEngineTests {
    @Test func nativeDefaultFailsClosedAndNeverBecomesReady() async {
        let engine = LlamaCppInferenceEngine()
        #expect(engine.mode == .local)
        for quantization in ModelQuantization.allCases {
            do {
                try await engine.load(model: fixture(quantization), configuration: .init())
                Issue.record("An unlinked native backend must not load a model.")
            } catch {
                #expect(error as? LlamaCppAdapterError == .nativeBackendUnavailable)
            }
            do {
                _ = try await engine.generate(request: .init(prompt: "test"))
                Issue.record("A failed load must not make generation available.")
            } catch {
                #expect(error as? RuntimeError == .invalidState(operation: "generate", state: "unloaded"))
            }
        }
        await engine.unload()
    }

    @Test func forwardsModelConfigurationAccelerationRequestAndMeasuredEvents() async throws {
        let metrics = InferenceMetrics(generatedTokenCount: 2, timeToFirstTokenSeconds: 0.12, durationSeconds: 0.7)
        let events: [InferenceEvent] = [.token("first"), .token("second"), .finished(metrics)]
        let backend = RecordingBackend(events: events)
        let engine = LlamaCppInferenceEngine(backend: backend)
        let model = fixture(.q8_0)
        let configuration = InferenceConfiguration(
            contextSize: 2_048, maximumOutputTokens: 128,
            sampling: .init(temperature: 0.4, topP: 0.8, seed: 42)
        )
        let request = InferenceRequest(prompt: "Reviewed local prompt", maximumOutputTokens: 16)
        try await engine.load(model: model, configuration: configuration)
        var received: [InferenceEvent] = []
        for try await event in try await engine.generate(request: request) { received.append(event) }
        #expect(received == events)
        #expect(await backend.models == [model])
        #expect(await backend.configurations == [configuration])
        #expect(await backend.accelerations == [.metal])
        #expect(await backend.requests == [request])
        // Stream closure must mean the engine is immediately reusable.
        for try await _ in try await engine.generate(request: request) {}
        await engine.unload()
        await engine.unload()
        #expect(await backend.unloadCount == 1)
    }

    @Test func q8ResourceFailureDoesNotSilentlyChooseOrRewriteQ4() async throws {
        let backend = RecordingBackend(rejectQ8: true)
        let engine = LlamaCppInferenceEngine(backend: backend)
        do {
            try await engine.load(model: fixture(.q8_0), configuration: .init())
            Issue.record("Q8 should report the backend's resource failure.")
        } catch {
            #expect(error as? RuntimeError == .resourceLimit(reason: "Test Q8 memory budget exceeded."))
        }
        #expect(await backend.models.map(\.manifest.quantization) == [.q8_0])
        #expect(await backend.unloadCount == 1)
        let independentlyValidatedQ4 = fixture(.q4_k_m)
        try await engine.load(model: independentlyValidatedQ4, configuration: .init())
        #expect(await backend.models.map(\.manifest.quantization) == [.q8_0, .q4_k_m])
        await engine.unload()
    }

    @Test func invalidConfigurationAndRequestsNeverReachBackend() async throws {
        let backend = RecordingBackend()
        let engine = LlamaCppInferenceEngine(backend: backend, acceleration: .cpu)
        do {
            try await engine.load(model: fixture(.q4_k_m), configuration: .init(contextSize: 0))
            Issue.record("Invalid context should fail before native allocation.")
        } catch { #expect(error is RuntimeError) }
        #expect(await backend.models.isEmpty)
        try await engine.load(model: fixture(.q4_k_m), configuration: .init(maximumPromptBytes: 8))
        for request in [InferenceRequest(prompt: " "), .init(prompt: "123456789"), .init(prompt: "test", maximumOutputTokens: 257)] {
            do {
                _ = try await engine.generate(request: request)
                Issue.record("Invalid requests should fail before native generation.")
            } catch { #expect(error is RuntimeError) }
        }
        #expect(await backend.requests.isEmpty)
        #expect(await backend.accelerations == [.cpu])
        await engine.unload()
    }

    @Test func unloadCancelsAndJoinsLoadingBeforeFreeingResources() async {
        let backend = RecordingBackend(blockLoad: true)
        let engine = LlamaCppInferenceEngine(backend: backend)
        let loading = Task { try await engine.load(model: fixture(.q8_0), configuration: .init()) }
        await backend.waitForLoadStart()
        await engine.unload()
        do {
            try await loading.value
            Issue.record("An unload during load must invalidate the load.")
        } catch { #expect(error is CancellationError) }
        #expect(await backend.unloadCount == 1)
        #expect(!(await backend.unloadedDuringLoad))
    }

    @Test func callerCancellationCleansPartialLoadingResources() async {
        let backend = RecordingBackend(blockLoad: true)
        let engine = LlamaCppInferenceEngine(backend: backend)
        let loading = Task { try await engine.load(model: fixture(.q8_0), configuration: .init()) }
        await backend.waitForLoadStart()
        loading.cancel()
        do {
            try await loading.value
            Issue.record("Cancelled loading should fail.")
        } catch { #expect(error is CancellationError) }
        #expect(await backend.unloadCount == 1)
        #expect(!(await backend.unloadedDuringLoad))
    }

    @Test func streamFailureIsForwardedAndEngineCanBeUsedAgain() async throws {
        let backend = RecordingBackend(streamFailure: .engineFailure(operation: "test decode"))
        let engine = LlamaCppInferenceEngine(backend: backend)
        try await engine.load(model: fixture(.q4_k_m), configuration: .init())
        for _ in 0..<2 {
            do {
                for try await _ in try await engine.generate(request: .init(prompt: "test")) {}
                Issue.record("Native stream errors must reach the caller.")
            } catch { #expect(error as? RuntimeError == .engineFailure(operation: "test decode")) }
        }
        #expect(await backend.requests.count == 2)
        #expect(await backend.cancelledGenerationIDs.count == 2)
        await engine.unload()
    }

    @Test func cancellingConsumerCancelsTheMatchingNativeGeneration() async throws {
        let backend = RecordingBackend(blockStream: true)
        let engine = LlamaCppInferenceEngine(backend: backend)
        try await engine.load(model: fixture(.q8_0), configuration: .init())
        let stream = try await engine.generate(request: .init(prompt: "test"))
        let consumer = Task { for try await _ in stream {} }
        await backend.waitForGenerationStart()
        consumer.cancel()
        _ = await consumer.result
        await backend.waitForCancellation()
        #expect(await backend.cancelledGenerationIDs.contains(backend.generationIDs[0]))
        await engine.unload()
        #expect(!(await backend.unloadedDuringGeneration))
    }

    @Test func unloadDuringStreamCreationJoinsTheOpeningTask() async throws {
        let backend = RecordingBackend(blockOpen: true, blockStream: true, ignoreOpenCancellation: true)
        let engine = LlamaCppInferenceEngine(backend: backend)
        try await engine.load(model: fixture(.q8_0), configuration: .init())
        let opening = Task { try await engine.generate(request: .init(prompt: "test")) }
        await backend.waitForGenerationStart()
        await engine.unload()
        do {
            _ = try await opening.value
            Issue.record("Unloading must invalidate stream creation.")
        } catch { #expect(error is CancellationError) }
        #expect(await backend.unloadCount == 1)
        #expect(await backend.cancellationCallCount >= 2)
        #expect(!(await backend.unloadedDuringGeneration))
    }
}

private func fixture(_ quantization: ModelQuantization) -> ValidatedModel {
    ValidatedModel(
        fileURL: URL(fileURLWithPath: "/test-fixtures/\(quantization.rawValue).gguf"),
        manifest: ModelManifest(
            id: "test-model", displayName: "Test fixture", quantization: quantization,
            expectedByteCount: 24, sha256: String(repeating: "a", count: 64),
            provenance: .init(sourceURL: URL(string: "https://example.invalid/test-model")!, revision: "fixture", license: "Test only")
        )
    )
}

/// A contract test double; none of its events are native inference measurements.
private actor RecordingBackend: LlamaCppBackend {
    private let events: [InferenceEvent]
    private let rejectQ8: Bool
    private let blockLoad: Bool
    private let blockOpen: Bool
    private let blockStream: Bool
    private let ignoreOpenCancellation: Bool
    private let streamFailure: RuntimeError?
    private var loading = false
    private var opening = false
    private var producers: [UUID: Task<Void, Never>] = [:]
    private var loadWaiters: [AsyncStream<Void>.Continuation] = []
    private var generationWaiters: [AsyncStream<Void>.Continuation] = []
    private var cancellationWaiters: [AsyncStream<Void>.Continuation] = []
    private(set) var models: [ValidatedModel] = []
    private(set) var configurations: [InferenceConfiguration] = []
    private(set) var accelerations: [LlamaCppAcceleration] = []
    private(set) var requests: [InferenceRequest] = []
    private(set) var generationIDs: [UUID] = []
    private(set) var cancelledGenerationIDs: Set<UUID> = []
    private(set) var cancellationCallCount = 0
    private(set) var unloadCount = 0
    private(set) var unloadedDuringLoad = false
    private(set) var unloadedDuringGeneration = false

    init(
        events: [InferenceEvent] = [], rejectQ8: Bool = false,
        blockLoad: Bool = false, blockOpen: Bool = false,
        blockStream: Bool = false, ignoreOpenCancellation: Bool = false, streamFailure: RuntimeError? = nil
    ) {
        self.events = events
        self.rejectQ8 = rejectQ8
        self.blockLoad = blockLoad
        self.blockOpen = blockOpen
        self.blockStream = blockStream
        self.ignoreOpenCancellation = ignoreOpenCancellation
        self.streamFailure = streamFailure
    }

    func load(model: ValidatedModel, configuration: InferenceConfiguration, acceleration: LlamaCppAcceleration) async throws {
        models.append(model)
        configurations.append(configuration)
        accelerations.append(acceleration)
        loading = true
        for waiter in loadWaiters { waiter.yield(()); waiter.finish() }
        loadWaiters.removeAll()
        defer { loading = false }
        if blockLoad { try await Task.sleep(for: .seconds(60)) }
        if rejectQ8 && model.manifest.quantization == .q8_0 {
            throw RuntimeError.resourceLimit(reason: "Test Q8 memory budget exceeded.")
        }
    }

    func unload() async {
        unloadCount += 1
        unloadedDuringLoad = unloadedDuringLoad || loading
        unloadedDuringGeneration = unloadedDuringGeneration || opening || !producers.isEmpty
    }

    func generate(request: InferenceRequest, generationID: UUID) async throws -> AsyncThrowingStream<InferenceEvent, Error> {
        requests.append(request)
        generationIDs.append(generationID)
        opening = true
        for waiter in generationWaiters { waiter.yield(()); waiter.finish() }
        generationWaiters.removeAll()
        defer { opening = false }
        if blockOpen {
            if ignoreOpenCancellation {
                // Simulates a native open that completes after its first cancel.
                try? await Task.sleep(for: .seconds(60))
            } else {
                try await Task.sleep(for: .seconds(60))
            }
        }
        let (stream, continuation) = AsyncThrowingStream<InferenceEvent, Error>.makeStream()
        let events = self.events
        let blockStream = self.blockStream
        let failure = self.streamFailure
        let producer = Task {
            do {
                if blockStream { try await Task.sleep(for: .seconds(60)) }
                for event in events {
                    try Task.checkCancellation()
                    continuation.yield(event)
                }
                self.producers.removeValue(forKey: generationID)
                if let failure { continuation.finish(throwing: failure) } else { continuation.finish() }
            } catch {
                self.producers.removeValue(forKey: generationID)
                continuation.finish(throwing: error)
            }
        }
        producers[generationID] = producer
        continuation.onTermination = { @Sendable _ in producer.cancel() }
        return stream
    }

    func cancelGeneration(generationID: UUID) async {
        cancellationCallCount += 1
        cancelledGenerationIDs.insert(generationID)
        let producer = producers[generationID]
        producer?.cancel()
        if let producer { await producer.value }
        for waiter in cancellationWaiters { waiter.yield(()); waiter.finish() }
        cancellationWaiters.removeAll()
    }

    func waitForLoadStart() async {
        if loading { return }
        let stream = AsyncStream<Void> { loadWaiters.append($0) }
        for await _ in stream { return }
    }

    func waitForGenerationStart() async {
        if !generationIDs.isEmpty { return }
        let stream = AsyncStream<Void> { generationWaiters.append($0) }
        for await _ in stream { return }
    }

    func waitForCancellation() async {
        if !cancelledGenerationIDs.isEmpty { return }
        let stream = AsyncStream<Void> { cancellationWaiters.append($0) }
        for await _ in stream { return }
    }
}
