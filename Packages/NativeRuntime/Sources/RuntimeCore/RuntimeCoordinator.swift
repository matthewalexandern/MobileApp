import Foundation

public enum RuntimeState: Sendable, Equatable {
    case uninstalled
    /// Reserved for an explicitly requested acquisition workflow; M0 never downloads models.
    case downloading
    case validating
    case loading
    case ready
    case unloading
    case failed(RuntimeError)

    public var label: String {
        switch self {
        case .uninstalled: "uninstalled"
        case .downloading: "downloading"
        case .validating: "validating"
        case .loading: "loading"
        case .ready: "ready"
        case .unloading: "unloading"
        case .failed: "failed"
        }
    }
}

public struct RuntimeSnapshot: Sendable, Equatable {
    public let state: RuntimeState
    public let mode: InferenceMode
    public let isGenerating: Bool
    public let model: ModelManifest?
    public let metrics: InferenceMetrics?

    public init(state: RuntimeState, mode: InferenceMode, isGenerating: Bool, model: ModelManifest?, metrics: InferenceMetrics?) {
        self.state = state
        self.mode = mode
        self.isGenerating = isGenerating
        self.model = model
        self.metrics = metrics
    }
}

/// Owns a single model and generation. Operation identities prevent stale completions from reviving
/// an unloaded engine. Unload waits for cancellation to settle before releasing native resources.
public actor RuntimeCoordinator {
    public private(set) var state: RuntimeState = .uninstalled

    private let engine: any InferenceEngine
    private let configuration: InferenceConfiguration
    private var loadedModel: ModelManifest?
    private var lastMetrics: InferenceMetrics?
    private var isInBackground = false
    private var lifecycleID: UUID?
    private var pendingLifecycle: Task<Void, Never>?
    private var cancelLifecycle: (@Sendable () -> Void)?
    private var generationID: UUID?
    private var generationTask: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<RuntimeSnapshot>.Continuation] = [:]

    public init(engine: any InferenceEngine, configuration: InferenceConfiguration = .init()) {
        self.engine = engine
        self.configuration = configuration
    }

    public func snapshot() -> RuntimeSnapshot {
        RuntimeSnapshot(state: state, mode: engine.mode, isGenerating: generationID != nil, model: loadedModel, metrics: lastMetrics)
    }

    public func stateUpdates() -> AsyncStream<RuntimeSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation
            continuation.yield(snapshot())
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
    }

    public func startDemonstration() async throws {
        guard engine is MockInferenceEngine else { throw RuntimeError.demonstrationUnavailable }
        try await load(model: MockInferenceEngine.demonstrationModel)
    }

    public func load(model: ValidatedModel) async throws {
        _ = try await prepareAndLoad(initialState: .loading) { model }
    }

    @discardableResult
    public func importModel(from source: URL, manifest: ModelManifest, using importer: ModelImporter) async throws -> ValidatedModel {
        try await prepareAndLoad(initialState: .validating) {
            try await importer.importModel(from: source, manifest: manifest)
        }
    }

    public func generate(request: InferenceRequest) async throws -> AsyncThrowingStream<InferenceEvent, Error> {
        try Task.checkCancellation()
        guard !isInBackground else { throw RuntimeError.backgrounded }
        guard state == .ready, generationID == nil else {
            throw RuntimeError.invalidState(operation: "generate", state: generationID == nil ? state.label : "generating")
        }
        let limit = request.maximumOutputTokens ?? configuration.maximumOutputTokens
        guard !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.prompt.utf8.count <= configuration.maximumPromptBytes,
              (1...configuration.maximumOutputTokens).contains(limit) else {
            throw RuntimeError.invalidRequest(reason: "The prompt must be nonempty and within the configured byte and output-token limits.")
        }
        let boundedRequest = InferenceRequest(prompt: request.prompt, maximumOutputTokens: limit)
        let id = UUID()
        generationID = id
        lastMetrics = nil
        let stream = AsyncThrowingStream<InferenceEvent, Error>(bufferingPolicy: .bufferingOldest(min(limit + 1, 65))) { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish(throwing: RuntimeError.cancelled)
                    return
                }
                await self.runGeneration(id: id, request: boundedRequest, limit: limit, continuation: continuation)
            }
            generationTask = task
            continuation.onTermination = { @Sendable [weak self] _ in
                task.cancel()
                Task { await self?.cancelGeneration(id: id) }
            }
        }
        publish()
        return stream
    }

    public func cancelGeneration() async {
        guard let id = generationID else { return }
        await cancelGeneration(id: id)
    }

    public func unload() async {
        if state == .uninstalled, lifecycleID == nil, generationID == nil { return }
        if state == .unloading {
            let id = lifecycleID
            await pendingLifecycle?.value
            if let id { completeUnload(id: id) }
            return
        }
        cancelLifecycle?()
        generationTask?.cancel()
        let previousLifecycle = pendingLifecycle
        let previousGeneration = generationTask
        let id = UUID()
        lifecycleID = id
        state = .unloading
        loadedModel = nil
        publish()
        let task = Task { [engine] in
            await previousLifecycle?.value
            await previousGeneration?.value
            await engine.unload()
        }
        pendingLifecycle = task
        cancelLifecycle = nil
        await task.value
        completeUnload(id: id)
    }

    private func completeUnload(id: UUID) {
        guard lifecycleID == id else { return }
        lifecycleID = nil
        pendingLifecycle = nil
        generationID = nil
        generationTask = nil
        state = .uninstalled
        publish()
    }

    public func didEnterBackground() async {
        isInBackground = true
        await unload()
    }

    /// Activation permits a later explicit load; it does not reload a large model automatically.
    public func didBecomeActive() {
        isInBackground = false
        publish()
    }

    private func prepareAndLoad(
        initialState: RuntimeState,
        prepare: @escaping @Sendable () async throws -> ValidatedModel
    ) async throws -> ValidatedModel {
        try Task.checkCancellation()
        try configuration.validate()
        guard !isInBackground else { throw RuntimeError.backgrounded }
        guard state == .uninstalled || isFailed, lifecycleID == nil, generationID == nil else {
            throw RuntimeError.invalidState(operation: "load a model", state: state.label)
        }
        let needsCleanup = isFailed
        let id = UUID()
        lifecycleID = id
        loadedModel = nil
        lastMetrics = nil
        state = initialState
        publish()
        let task = Task { [engine, configuration] in
            do {
                if needsCleanup { await engine.unload() }
                let model = try await prepare()
                try Task.checkCancellation()
                guard self.markLoading(id: id) else { throw RuntimeError.cancelled }
                try await engine.load(model: model, configuration: configuration)
                try Task.checkCancellation()
                return model
            } catch {
                // Also clean up native partial allocations after failed or cancelled loads.
                await engine.unload()
                throw error
            }
        }
        pendingLifecycle = Task { _ = await task.result }
        cancelLifecycle = { task.cancel() }
        do {
            let model = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            if Task.isCancelled {
                if lifecycleID == id { await unload() }
                throw RuntimeError.cancelled
            }
            guard lifecycleID == id else { throw RuntimeError.cancelled }
            lifecycleID = nil
            pendingLifecycle = nil
            cancelLifecycle = nil
            loadedModel = model.manifest
            state = .ready
            publish()
            return model
        } catch {
            guard lifecycleID == id else { throw RuntimeError.cancelled }
            lifecycleID = nil
            pendingLifecycle = nil
            cancelLifecycle = nil
            let failure: RuntimeError
            if error is CancellationError || error as? RuntimeError == .cancelled {
                failure = .cancelled
                state = .uninstalled
            } else {
                failure = (error as? RuntimeError) ?? (state == .validating ? .modelValidationFailed : .engineFailure(operation: "model loading"))
                state = .failed(failure)
            }
            publish()
            throw failure
        }
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func markLoading(id: UUID) -> Bool {
        guard lifecycleID == id, !isInBackground else { return false }
        state = .loading
        publish()
        return true
    }

    private func runGeneration(
        id: UUID,
        request: InferenceRequest,
        limit: Int,
        continuation: AsyncThrowingStream<InferenceEvent, Error>.Continuation
    ) async {
        do {
            let metrics = try await Self.consume(
                engine: engine,
                request: request,
                limit: limit,
                timeoutSeconds: configuration.generationTimeoutSeconds,
                continuation: continuation
            )
            try Task.checkCancellation()
            if generationID == id {
                lastMetrics = metrics
                if case .dropped = continuation.yield(.finished(metrics)) {
                    throw RuntimeError.resourceLimit(reason: "Generation stopped because the consumer could not keep up.")
                }
                continuation.finish()
            } else {
                continuation.finish(throwing: RuntimeError.cancelled)
            }
        } catch {
            let failure = error is CancellationError ? RuntimeError.cancelled : (error as? RuntimeError ?? .engineFailure(operation: "generation"))
            continuation.finish(throwing: failure)
            if generationID == id, state == .ready, case .engineFailure = failure {
                state = .failed(failure)
            }
        }
        if generationID == id {
            generationID = nil
            generationTask = nil
            publish()
        }
    }

    private nonisolated static func consume(
        engine: any InferenceEngine,
        request: InferenceRequest,
        limit: Int,
        timeoutSeconds: Double,
        continuation: AsyncThrowingStream<InferenceEvent, Error>.Continuation
    ) async throws -> InferenceMetrics {
        try await withThrowingTaskGroup(of: InferenceMetrics.self) { group in
            group.addTask {
                let clock = ContinuousClock()
                let start = clock.now
                var firstToken: Double?
                var count = 0
                var sawTerminal = false
                let upstream = try await engine.generate(request: request)
                for try await event in upstream {
                    try Task.checkCancellation()
                    switch event {
                    case .token(let token):
                        guard !sawTerminal else { throw RuntimeError.engineFailure(operation: "generation stream ordering") }
                        guard count < limit else { throw RuntimeError.resourceLimit(reason: "The engine exceeded the output-token limit.") }
                        count += 1
                        if firstToken == nil { firstToken = seconds(start.duration(to: clock.now)) }
                        switch continuation.yield(.token(token)) {
                        case .dropped:
                            throw RuntimeError.resourceLimit(reason: "Generation stopped because the consumer could not keep up.")
                        case .terminated:
                            throw RuntimeError.cancelled
                        case .enqueued:
                            break
                        @unknown default:
                            throw RuntimeError.cancelled
                        }
                    case .finished:
                        // Wait for stream closure so the backend has settled before another request.
                        // Native metrics are not substituted for the coordinator's measured events.
                        sawTerminal = true
                    }
                }
                try Task.checkCancellation()
                return InferenceMetrics(generatedTokenCount: count, timeToFirstTokenSeconds: firstToken, durationSeconds: seconds(start.duration(to: clock.now)))
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                throw RuntimeError.resourceLimit(reason: "Generation exceeded the configured time limit.")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw RuntimeError.cancelled }
            return result
        }
    }

    private nonisolated static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
    }

    private func cancelGeneration(id: UUID) async {
        guard generationID == id else { return }
        let task = generationTask
        task?.cancel()
        await task?.value
    }

    private func publish() {
        let value = snapshot()
        for observer in observers.values { observer.yield(value) }
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }
}
