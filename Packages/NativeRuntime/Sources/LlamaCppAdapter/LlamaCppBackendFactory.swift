import Foundation
import RuntimeCore

public enum LlamaCppBackendFactory {
    public static var isLinked: Bool {
        #if canImport(llama)
        true
        #else
        false
        #endif
    }

    /// Native production composition always uses actual iOS memory/thermal admission.
    /// Explicitly injected backends remain available for isolated contract tests.
    public static func makeDefault() -> any LlamaCppBackend {
        #if canImport(llama)
        ResourceGuardedLlamaCppBackend(backend: NativeLlamaCppBackend())
        #else
        UnavailableLlamaCppBackend()
        #endif
    }
}

/// Used inside LlamaCppInferenceEngine, whose lifecycle serializes calls and joins cancellation.
public actor ResourceGuardedLlamaCppBackend: LlamaCppBackend {
    private let backend: any LlamaCppBackend
    private let monitor: any RuntimeResourceMonitor
    private let policy: RuntimeResourcePolicy
    private var configuration: InferenceConfiguration?

    public init(
        backend: any LlamaCppBackend,
        monitor: any RuntimeResourceMonitor = SystemRuntimeResourceMonitor(),
        policy: RuntimeResourcePolicy = .init()
    ) {
        self.backend = backend
        self.monitor = monitor
        self.policy = policy
    }

    public func load(model: ValidatedModel, configuration: InferenceConfiguration, acceleration: LlamaCppAcceleration) async throws {
        try Task.checkCancellation()
        do {
            _ = try policy.preflightLoad(model: model, configuration: configuration, snapshot: monitor.snapshot())
        } catch let error as RuntimeResourcePolicyError {
            throw RuntimeError.resourceLimit(reason: error.localizedDescription)
        }
        try await backend.load(model: model, configuration: configuration, acceleration: acceleration)
        self.configuration = configuration
    }

    public func unload() async {
        configuration = nil
        await backend.unload()
    }

    public func generate(request: InferenceRequest, generationID: UUID) async throws -> AsyncThrowingStream<InferenceEvent, Error> {
        try Task.checkCancellation()
        guard let configuration else {
            throw RuntimeError.invalidState(operation: "generate", state: "uninstalled")
        }
        do {
            try policy.preflightGeneration(configuration: configuration, snapshot: monitor.snapshot())
        } catch let error as RuntimeResourcePolicyError {
            throw RuntimeError.resourceLimit(reason: error.localizedDescription)
        }
        return try await backend.generate(request: request, generationID: generationID)
    }

    public func cancelGeneration(generationID: UUID) async {
        await backend.cancelGeneration(generationID: generationID)
    }
}
