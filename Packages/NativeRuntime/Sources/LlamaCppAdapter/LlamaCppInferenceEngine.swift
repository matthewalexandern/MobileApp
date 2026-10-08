import Foundation
import RuntimeCore

public enum LlamaCppAcceleration: String, Sendable, Equatable {
    case metal
    case cpu
}

public enum LlamaCppAdapterError: Error, Sendable, Equatable, LocalizedError {
    case nativeBackendUnavailable
    case consumerTooSlow

    public var errorDescription: String? {
        switch self {
        case .nativeBackendUnavailable:
            "This build does not link llama.cpp. Build with the reviewed native framework to enable local inference."
        case .consumerTooSlow:
            "Generation stopped because queued output exceeded the consumer buffer limit."
        }
    }
}

/// The only boundary that a future `import llama` implementation may cross.
///
/// The backend must own native resources on a serial worker, make load and stream
/// creation cancellable, and make unload idempotent. Cancellation is scoped to
/// the generation ID so delayed stream termination cannot stop a later request.
/// `cancelGeneration` must be idempotent, stop decode and finish its stream before returning;
/// `unload` must never free a context that is still decoding.
public protocol LlamaCppBackend: Sendable {
    func load(
        model: ValidatedModel,
        configuration: InferenceConfiguration,
        acceleration: LlamaCppAcceleration
    ) async throws
    func unload() async
    func generate(
        request: InferenceRequest,
        generationID: UUID
    ) async throws -> AsyncThrowingStream<InferenceEvent, Error>
    func cancelGeneration(generationID: UUID) async
}

/// Portable builds report unavailable instead of substituting demonstration output.
public struct UnavailableLlamaCppBackend: LlamaCppBackend {
    public init() {}

    public func load(
        model: ValidatedModel,
        configuration: InferenceConfiguration,
        acceleration: LlamaCppAcceleration
    ) async throws {
        throw LlamaCppAdapterError.nativeBackendUnavailable
    }

    public func unload() async {}

    public func generate(
        request: InferenceRequest,
        generationID: UUID
    ) async throws -> AsyncThrowingStream<InferenceEvent, Error> {
        throw LlamaCppAdapterError.nativeBackendUnavailable
    }

    public func cancelGeneration(generationID: UUID) async {}
}

/// Serializes native lifecycle operations and bounds queued stream output.
/// Backend metrics are forwarded unchanged; this adapter invents no benchmarks.
public actor LlamaCppInferenceEngine: InferenceEngine {
    public nonisolated let mode: InferenceMode = .local
    public nonisolated static var isNativeBackendLinked: Bool { LlamaCppBackendFactory.isLinked }
    public nonisolated static var nativeIntegrationStatus: String {
        isNativeBackendLinked
            ? "llama.cpp is linked. Compatibility and memory fit require verification on your iPhone."
            : "This build does not link llama.cpp. The demonstration remains available."
    }

    private enum State: Equatable {
        case unloaded
        case loading(UUID)
        case ready
        case generating(UUID)
        case cancelling(UUID)
        case unloading(UUID)
    }

    private let backend: any LlamaCppBackend
    private let acceleration: LlamaCppAcceleration
    private var state = State.unloaded
    private var configuration: InferenceConfiguration?
    private var loadTask: Task<Void, Error>?
    private var openStreamTask: Task<AsyncThrowingStream<InferenceEvent, Error>, Error>?
    private var streamTask: Task<Void, Never>?
    private var cancellationTask: Task<Void, Never>?
    private var teardownTask: Task<Void, Never>?

    public init(
        backend: any LlamaCppBackend = LlamaCppBackendFactory.makeDefault(),
        acceleration: LlamaCppAcceleration = .metal
    ) {
        self.backend = backend
        self.acceleration = acceleration
    }

    public func load(model: ValidatedModel, configuration: InferenceConfiguration) async throws {
        try configuration.validate()
        try Task.checkCancellation()
        guard state == .unloaded else { throw invalidState("load") }
        let operationID = UUID()
        state = .loading(operationID)
        let backend = self.backend
        let acceleration = self.acceleration
        let operation = Task {
            try await backend.load(model: model, configuration: configuration, acceleration: acceleration)
        }
        loadTask = operation
        do {
            try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: {
                operation.cancel()
            }
            try Task.checkCancellation()
            guard state == .loading(operationID) else { throw CancellationError() }
            loadTask = nil
            self.configuration = configuration
            state = .ready
        } catch {
            if state == .loading(operationID) { await unload() }
            throw Self.sanitized(error)
        }
    }

    public func unload() async {
        if state == .unloaded { return }
        if case .unloading(let operationID) = state, let operation = teardownTask {
            await operation.value
            completeUnload(operationID)
            return
        }
        let operationID = UUID()
        let generationID: UUID?
        switch state {
        case .generating(let id), .cancelling(let id): generationID = id
        default: generationID = nil
        }
        let loading = loadTask
        let opening = openStreamTask
        let streaming = streamTask
        let cancelling = cancellationTask
        let backend = self.backend
        state = .unloading(operationID)
        configuration = nil
        let operation = Task {
            loading?.cancel()
            opening?.cancel()
            streaming?.cancel()
            if let generationID { await backend.cancelGeneration(generationID: generationID) }
            if let loading { _ = try? await loading.value }
            if let opening { _ = try? await opening.value }
            // Stream creation may have completed immediately after the first
            // cancellation. Join it, then cancel the same ID again before free.
            if let generationID { await backend.cancelGeneration(generationID: generationID) }
            if let streaming { await streaming.value }
            if let cancelling { await cancelling.value }
            await backend.unload()
        }
        teardownTask = operation
        await operation.value
        completeUnload(operationID)
    }

    /// Capture one operation identity before suspending. Repeated calls share its
    /// join; delayed cleanup cannot cancel a later generation or advertise readiness.
    public func cancelGeneration() async {
        if case .cancelling(let generationID) = state, let operation = cancellationTask {
            await operation.value
            completeCancellation(generationID)
            return
        }
        if case .unloading(let operationID) = state, let operation = teardownTask {
            await operation.value
            completeUnload(operationID)
            return
        }
        guard case .generating(let generationID) = state else { return }
        let opening = openStreamTask
        let streaming = streamTask
        let backend = self.backend
        state = .cancelling(generationID)
        let operation = Task {
            opening?.cancel()
            streaming?.cancel()
            await backend.cancelGeneration(generationID: generationID)
            if let opening { _ = try? await opening.value }
            // A backend may finish opening after receiving the first cancellation.
            await backend.cancelGeneration(generationID: generationID)
            if let streaming { await streaming.value }
        }
        cancellationTask = operation
        await operation.value
        completeCancellation(generationID)
    }

    public func generate(
        request: InferenceRequest
    ) async throws -> AsyncThrowingStream<InferenceEvent, Error> {
        try Task.checkCancellation()
        guard state == .ready, let configuration else { throw invalidState("generate") }
        guard !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.prompt.utf8.count <= configuration.maximumPromptBytes else {
            throw RuntimeError.invalidRequest(reason: "Prompt is empty or exceeds the configured byte limit.")
        }
        let maximumOutputTokens = request.maximumOutputTokens ?? configuration.maximumOutputTokens
        guard maximumOutputTokens > 0, maximumOutputTokens <= configuration.maximumOutputTokens else {
            throw RuntimeError.invalidRequest(reason: "Output token limit exceeds the loaded configuration.")
        }
        let generationID = UUID()
        state = .generating(generationID)
        let backend = self.backend
        let opening = Task { try await backend.generate(request: request, generationID: generationID) }
        openStreamTask = opening
        let nativeStream: AsyncThrowingStream<InferenceEvent, Error>
        do {
            nativeStream = try await withTaskCancellationHandler {
                try await opening.value
            } onCancel: {
                opening.cancel()
                Task { await backend.cancelGeneration(generationID: generationID) }
            }
            try Task.checkCancellation()
            guard state == .generating(generationID) else { throw CancellationError() }
            openStreamTask = nil
        } catch {
            if state == .generating(generationID) {
                await backend.cancelGeneration(generationID: generationID)
                finishGeneration(generationID)
            }
            throw Self.sanitized(error)
        }

        let (stream, continuation) = AsyncThrowingStream<InferenceEvent, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(maximumOutputTokens + 1)
        )
        let producing = Task { [weak self] in
            do {
                for try await event in nativeStream {
                    try Task.checkCancellation()
                    switch continuation.yield(event) {
                    case .enqueued: break
                    case .dropped: throw LlamaCppAdapterError.consumerTooSlow
                    case .terminated: throw CancellationError()
                    @unknown default: throw LlamaCppAdapterError.consumerTooSlow
                    }
                }
                try Task.checkCancellation()
                await self?.finishGeneration(generationID)
                continuation.finish()
            } catch {
                await backend.cancelGeneration(generationID: generationID)
                await self?.finishGeneration(generationID)
                continuation.finish(throwing: Self.sanitized(error))
            }
        }
        streamTask = producing
        continuation.onTermination = { termination in
            if case .cancelled = termination {
                producing.cancel()
                Task { await backend.cancelGeneration(generationID: generationID) }
            }
        }
        return stream
    }

    private func finishGeneration(_ generationID: UUID) {
        guard state == .generating(generationID) else { return }
        openStreamTask = nil
        streamTask = nil
        state = .ready
    }

    private func completeUnload(_ operationID: UUID) {
        guard state == .unloading(operationID) else { return }
        loadTask = nil
        openStreamTask = nil
        streamTask = nil
        cancellationTask = nil
        teardownTask = nil
        configuration = nil
        state = .unloaded
    }

    private func completeCancellation(_ generationID: UUID) {
        guard state == .cancelling(generationID) else { return }
        openStreamTask = nil
        streamTask = nil
        cancellationTask = nil
        state = .ready
    }

    private func invalidState(_ operation: String) -> RuntimeError {
        RuntimeError.invalidState(operation: operation, state: String(describing: state))
    }

    private nonisolated static func sanitized(_ error: any Error) -> any Error {
        if let nativeError = error as? NativeLlamaCppError {
            return RuntimeError.backendFailure(reason: nativeError.localizedDescription)
        }
        return error
    }
}
