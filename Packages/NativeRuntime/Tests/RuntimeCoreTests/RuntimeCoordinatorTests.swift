import Foundation
import Testing
@testable import RuntimeCore

struct RuntimeCoordinatorTests {
    @Test func defaultConfigurationAndInvalidSampling() throws {
        let configuration = InferenceConfiguration()
        #expect(configuration.contextSize == 2_048)
        try configuration.validate()
        #expect(throws: RuntimeError.self) {
            try InferenceConfiguration(sampling: .init(temperature: .nan)).validate()
        }
        #expect(throws: RuntimeError.self) {
            try InferenceConfiguration(maximumOutputTokens: 2_048).validate()
        }
    }

    @Test func cannotGenerateBeforeLoading() async {
        let runtime = RuntimeCoordinator(engine: MockInferenceEngine())
        do {
            _ = try await runtime.generate(request: .init(prompt: "test"))
            Issue.record("Generation should require a loaded engine.")
        } catch {
            #expect(error as? RuntimeError == .invalidState(operation: "generate", state: "uninstalled"))
        }
    }

    @Test func demonstrationStreamsExplicitNoticeAndMeasuredEvents() async throws {
        let runtime = RuntimeCoordinator(engine: MockInferenceEngine())
        try await runtime.startDemonstration()
        let initial = await runtime.snapshot()
        #expect(initial.state == .ready)
        #expect(initial.mode == .demonstration)
        var text = ""
        var terminal: InferenceMetrics?
        for try await event in try await runtime.generate(request: .init(prompt: "private prompt never echoed")) {
            switch event {
            case .token(let token): text += token
            case .finished(let metrics): terminal = metrics
            }
        }
        #expect(text.contains(MockInferenceEngine.demonstrationNotice))
        #expect(!text.contains("private prompt"))
        #expect(terminal?.generatedTokenCount == 4)
        #expect(terminal?.timeToFirstTokenSeconds != nil)
        // Finishing the stream and clearing generation state occur in the same actor turn.
        #expect(!(await runtime.snapshot()).isGenerating)
    }

    @Test func backgroundUnloadsAndForegroundRequiresExplicitRestart() async throws {
        let runtime = RuntimeCoordinator(engine: MockInferenceEngine())
        try await runtime.startDemonstration()
        await runtime.didEnterBackground()
        #expect((await runtime.snapshot()).state == .uninstalled)
        do {
            try await runtime.startDemonstration()
            Issue.record("Backgrounded runtime should reject new loads.")
        } catch {
            #expect(error as? RuntimeError == .backgrounded)
        }
        await runtime.didBecomeActive()
        #expect((await runtime.snapshot()).state == .uninstalled)
        try await runtime.startDemonstration()
        #expect((await runtime.snapshot()).state == .ready)
    }

    @Test func cancellingLoadCleansPartialResources() async {
        let engine = TestEngine(loadBehavior: .blocked)
        let runtime = RuntimeCoordinator(engine: engine)
        let load = Task { try await runtime.load(model: fixture()) }
        await engine.waitForLoadStart()
        #expect((await runtime.snapshot()).state == .loading)
        load.cancel()
        do {
            try await load.value
            Issue.record("Cancelled load should fail.")
        } catch {
            #expect(error as? RuntimeError == .cancelled)
        }
        #expect((await runtime.snapshot()).state == .uninstalled)
        #expect(await engine.unloadCount == 1)
        #expect(!(await engine.unloadedDuringLoad))
    }

    @Test func backgroundDuringLoadDoesNotAllowStaleReadyState() async {
        let engine = TestEngine(loadBehavior: .blocked)
        let runtime = RuntimeCoordinator(engine: engine)
        let load = Task { try await runtime.load(model: fixture()) }
        await engine.waitForLoadStart()
        await runtime.didEnterBackground()
        do {
            try await load.value
            Issue.record("Background transition should cancel loading.")
        } catch {
            #expect(error as? RuntimeError == .cancelled)
        }
        #expect((await runtime.snapshot()).state == .uninstalled)
        #expect(!(await engine.unloadedDuringLoad))
    }

    @Test func concurrentLoadsAreRejected() async {
        let engine = TestEngine(loadBehavior: .blocked)
        let runtime = RuntimeCoordinator(engine: engine)
        let first = Task { try await runtime.load(model: fixture()) }
        await engine.waitForLoadStart()
        do {
            try await runtime.load(model: fixture())
            Issue.record("Concurrent load should be rejected.")
        } catch {
            #expect(error as? RuntimeError == .invalidState(operation: "load a model", state: "loading"))
        }
        await runtime.unload()
        _ = await first.result
        #expect(await engine.loadCount == 1)
    }

    @Test func concurrentUnloadsSettleBeforeReturning() async throws {
        let engine = TestEngine()
        let runtime = RuntimeCoordinator(engine: engine)
        try await runtime.load(model: fixture())
        async let first: Void = runtime.unload()
        async let second: Void = runtime.unload()
        _ = await (first, second)
        #expect((await runtime.snapshot()).state == .uninstalled)
        #expect(await engine.unloadCount == 1)
    }

    @Test func loadFailureCanRecoverAfterCleanup() async throws {
        let engine = TestEngine(loadBehavior: .failOnce)
        let runtime = RuntimeCoordinator(engine: engine)
        do {
            try await runtime.load(model: fixture())
            Issue.record("First load should fail.")
        } catch {
            #expect(error as? RuntimeError == .engineFailure(operation: "model loading"))
        }
        #expect((await runtime.snapshot()).state == .failed(.engineFailure(operation: "model loading")))
        try await runtime.load(model: fixture())
        #expect((await runtime.snapshot()).state == .ready)
        #expect(!(await engine.unloadedDuringLoad))
    }

    @Test func engineCannotExceedRequestedOutputLimit() async throws {
        let engine = TestEngine(tokens: Array(repeating: "token", count: 10))
        let runtime = RuntimeCoordinator(engine: engine)
        try await runtime.load(model: fixture())
        var count = 0
        do {
            for try await event in try await runtime.generate(request: .init(prompt: "test", maximumOutputTokens: 2)) {
                if case .token = event { count += 1 }
            }
            Issue.record("An engine ignoring the token limit should fail.")
        } catch {
            #expect(error as? RuntimeError == .resourceLimit(reason: "The engine exceeded the output-token limit."))
        }
        #expect(count == 2)
    }

    @Test func generationTimeoutCancelsTheUpstreamProducer() async throws {
        let engine = TestEngine(blockGeneration: true)
        let runtime = RuntimeCoordinator(engine: engine, configuration: .init(generationTimeoutSeconds: 0.02))
        try await runtime.load(model: fixture())
        do {
            for try await _ in try await runtime.generate(request: .init(prompt: "test")) {}
            Issue.record("An idle stream should time out.")
        } catch {
            #expect(error as? RuntimeError == .resourceLimit(reason: "Generation exceeded the configured time limit."))
        }
        #expect(!(await runtime.snapshot()).isGenerating)
    }

    @Test func backgroundCancelsGenerationAndSerializesUnload() async throws {
        let engine = TestEngine(blockGeneration: true)
        let runtime = RuntimeCoordinator(engine: engine)
        try await runtime.load(model: fixture())
        let stream = try await runtime.generate(request: .init(prompt: "test"))
        let consumer = Task {
            do {
                for try await _ in stream {}
                return false
            } catch { return error as? RuntimeError == .cancelled }
        }
        await engine.waitForGenerationStart()
        do {
            _ = try await runtime.generate(request: .init(prompt: "second"))
            Issue.record("Only one generation may be active.")
        } catch {
            #expect(error as? RuntimeError == .invalidState(operation: "generate", state: "generating"))
        }
        await runtime.didEnterBackground()
        #expect(await consumer.value)
        #expect((await runtime.snapshot()).state == .uninstalled)
    }

    @Test func snapshotsHaveInitialStateAndFailedImportIsStructured() async {
        let runtime = RuntimeCoordinator(engine: MockInferenceEngine())
        var iterator = await runtime.stateUpdates().makeAsyncIterator()
        #expect(await iterator.next()?.state == .uninstalled)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let importer = ModelImporter(modelsDirectory: root)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await runtime.importModel(from: root.appendingPathComponent("missing.gguf"), manifest: fixture().manifest, using: importer)
            Issue.record("Missing imports should fail closed.")
        } catch {
            #expect(error as? RuntimeError == .modelValidationFailed)
        }
        #expect((await runtime.snapshot()).state == .failed(.modelValidationFailed))
    }

    @Test func invalidRequestsAreRejectedWithoutStartingGeneration() async throws {
        let runtime = RuntimeCoordinator(engine: MockInferenceEngine(), configuration: .init(maximumPromptBytes: 16))
        try await runtime.startDemonstration()
        for request in [InferenceRequest(prompt: "   "), .init(prompt: String(repeating: "x", count: 17)), .init(prompt: "test", maximumOutputTokens: 257)] {
            do {
                _ = try await runtime.generate(request: request)
                Issue.record("Out-of-bounds request should be rejected.")
            } catch {
                #expect(error is RuntimeError)
            }
        }
        #expect(!(await runtime.snapshot()).isGenerating)
    }

    private func fixture() -> ValidatedModel {
        ValidatedModel(
            fileURL: URL(fileURLWithPath: "/test-fixtures/model.gguf"),
            manifest: ModelManifest(
                id: "test-fixture", displayName: "Test fixture", quantization: .q8_0,
                expectedByteCount: 16, sha256: String(repeating: "a", count: 64),
                provenance: .init(sourceURL: URL(string: "https://example.invalid/model")!, revision: "fixture", license: "Test only")
            )
        )
    }
}

private actor TestEngine: InferenceEngine {
    enum LoadBehavior: Sendable { case immediate, blocked, failOnce }
    enum Failure: Error { case requested }

    nonisolated let mode: InferenceMode = .local
    private let loadBehavior: LoadBehavior
    private let tokens: [String]
    private let blockGeneration: Bool
    private var isLoading = false
    private var generationStarted = false
    private var loadWaiters: [AsyncStream<Void>.Continuation] = []
    private var generationWaiters: [AsyncStream<Void>.Continuation] = []
    private(set) var loadCount = 0
    private(set) var unloadCount = 0
    private(set) var unloadedDuringLoad = false

    init(loadBehavior: LoadBehavior = .immediate, tokens: [String] = ["test"], blockGeneration: Bool = false) {
        self.loadBehavior = loadBehavior
        self.tokens = tokens
        self.blockGeneration = blockGeneration
    }

    func load(model: ValidatedModel, configuration: InferenceConfiguration) async throws {
        loadCount += 1
        isLoading = true
        for waiter in loadWaiters { waiter.yield(()); waiter.finish() }
        loadWaiters.removeAll()
        defer { isLoading = false }
        switch loadBehavior {
        case .immediate: break
        case .blocked: try await Task.sleep(for: .seconds(60))
        case .failOnce: if loadCount == 1 { throw Failure.requested }
        }
    }

    func unload() async {
        unloadCount += 1
        unloadedDuringLoad = unloadedDuringLoad || isLoading
    }

    func generate(request: InferenceRequest) async throws -> AsyncThrowingStream<InferenceEvent, Error> {
        generationStarted = true
        for waiter in generationWaiters { waiter.yield(()); waiter.finish() }
        generationWaiters.removeAll()
        let tokens = self.tokens
        let blocked = blockGeneration
        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    if blocked { try await Task.sleep(for: .seconds(60)) }
                    for token in tokens {
                        try Task.checkCancellation()
                        continuation.yield(.token(token))
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    func waitForLoadStart() async {
        if isLoading { return }
        let stream = AsyncStream<Void> { loadWaiters.append($0) }
        for await _ in stream { return }
    }

    func waitForGenerationStart() async {
        if generationStarted { return }
        let stream = AsyncStream<Void> { generationWaiters.append($0) }
        for await _ in stream { return }
    }
}
