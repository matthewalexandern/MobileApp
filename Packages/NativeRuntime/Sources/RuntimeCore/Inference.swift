import Foundation

public enum InferenceMode: String, Codable, Sendable {
    case demonstration
    case local
}

public struct InferenceSampling: Sendable, Equatable {
    public var temperature: Double
    public var topP: Double
    public var seed: UInt32

    public init(temperature: Double = 0.7, topP: Double = 0.9, seed: UInt32 = 0) {
        self.temperature = temperature
        self.topP = topP
        self.seed = seed
    }
}

public struct InferenceConfiguration: Sendable, Equatable {
    public var contextSize: Int
    public var maximumOutputTokens: Int
    public var maximumPromptBytes: Int
    public var generationTimeoutSeconds: Double
    public var sampling: InferenceSampling

    public init(
        contextSize: Int = 2_048,
        maximumOutputTokens: Int = 256,
        maximumPromptBytes: Int = 32_768,
        generationTimeoutSeconds: Double = 60,
        sampling: InferenceSampling = .init()
    ) {
        self.contextSize = contextSize
        self.maximumOutputTokens = maximumOutputTokens
        self.maximumPromptBytes = maximumPromptBytes
        self.generationTimeoutSeconds = generationTimeoutSeconds
        self.sampling = sampling
    }

    public func validate() throws {
        guard (128...32_768).contains(contextSize),
              (1...1_024).contains(maximumOutputTokens),
              maximumOutputTokens < contextSize,
              (1...1_048_576).contains(maximumPromptBytes),
              generationTimeoutSeconds.isFinite,
              (0.001...300).contains(generationTimeoutSeconds),
              sampling.temperature.isFinite,
              (0...2).contains(sampling.temperature),
              sampling.topP.isFinite,
              (0.001...1).contains(sampling.topP) else {
            throw RuntimeError.invalidConfiguration(reason: "Context, sampling, and generation limits must be finite and within supported bounds.")
        }
    }
}

public struct InferenceRequest: Sendable, Equatable {
    public let prompt: String
    public let maximumOutputTokens: Int?

    public init(prompt: String, maximumOutputTokens: Int? = nil) {
        self.prompt = prompt
        self.maximumOutputTokens = maximumOutputTokens
    }
}

/// Token counts are counts of engine token events, not an estimate based on words.
/// These timings describe this process; physical-device memory and thermal benchmarks remain separate.
public struct InferenceMetrics: Sendable, Equatable {
    public let generatedTokenCount: Int
    public let timeToFirstTokenSeconds: Double?
    public let durationSeconds: Double
    /// Native sampling/decode duration after prompt evaluation; nil for demonstration engines.
    public let generationDurationSeconds: Double?

    public var tokensPerSecond: Double? {
        guard generatedTokenCount > 0, let generationDurationSeconds,
              generationDurationSeconds.isFinite, generationDurationSeconds > 0 else { return nil }
        return Double(generatedTokenCount) / generationDurationSeconds
    }

    public init(generatedTokenCount: Int, timeToFirstTokenSeconds: Double?, durationSeconds: Double, generationDurationSeconds: Double? = nil) {
        self.generatedTokenCount = generatedTokenCount
        self.timeToFirstTokenSeconds = timeToFirstTokenSeconds
        self.durationSeconds = durationSeconds
        self.generationDurationSeconds = generationDurationSeconds
    }
}

public enum InferenceEvent: Sendable, Equatable {
    case token(String)
    case finished(InferenceMetrics)
}

/// Implementations must cooperate with task cancellation, including while loading and waiting for tokens.
/// A native backend must enforce the configured context using its actual tokenizer and release partial
/// allocations when loading fails. Unload must be idempotent. The coordinator serializes unload after
/// in-flight engine work settles. Close streams only after generation resources are safe to reuse.
/// `cancelGeneration` must join the active generation, including native/GPU work, before returning.
/// Cancelling an AsyncThrowingStream consumer alone does not establish that its producer has stopped.
public protocol InferenceEngine: Sendable {
    var mode: InferenceMode { get }
    func load(model: ValidatedModel, configuration: InferenceConfiguration) async throws
    func unload() async
    func generate(request: InferenceRequest) async throws -> AsyncThrowingStream<InferenceEvent, Error>
    func cancelGeneration() async
}

public extension InferenceEngine {
    /// Suitable only for resource-less demonstration and test streams. Engines owning
    /// asynchronous workers or native resources must override this cancellation barrier.
    func cancelGeneration() async {}
}

public enum RuntimeError: Error, Sendable, Equatable, LocalizedError {
    case invalidConfiguration(reason: String)
    case invalidRequest(reason: String)
    case invalidState(operation: String, state: String)
    case cancelled
    case backgrounded
    case resourceLimit(reason: String)
    case engineFailure(operation: String)
    /// Sanitized diagnostics from a typed native backend error, never generated text.
    case backendFailure(reason: String)
    case modelValidationFailed
    case demonstrationUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let reason), .invalidRequest(let reason), .resourceLimit(let reason):
            return reason
        case .invalidState(let operation, let state):
            return "Cannot \(operation) while the runtime is \(state)."
        case .cancelled:
            return "The runtime operation was cancelled."
        case .backgrounded:
            return "Activate the app before starting inference."
        case .engineFailure(let operation):
            return "The inference engine failed during \(operation)."
        case .backendFailure(let reason):
            return reason
        case .modelValidationFailed:
            return "The model could not be verified. Check its manifest and file before importing it again."
        case .demonstrationUnavailable:
            return "Demonstration mode requires the demonstration engine."
        }
    }
}
