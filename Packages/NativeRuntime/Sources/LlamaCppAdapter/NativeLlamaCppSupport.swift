import Foundation
import RuntimeCore

/// Native diagnostics intentionally contain no model path, prompt, or generated text.
public enum NativeLlamaCppError: Error, Sendable, Equatable, LocalizedError {
    case unsupportedContext
    case metalUnavailable
    case modelLoadFailed
    case quantizationMismatch
    case contextCreationFailed
    case unsupportedChatTemplate
    case tokenizationFailed
    case promptExceedsContext
    case samplerCreationFailed
    case batchAllocationFailed
    case decodeFailed(code: Int32)
    case tokenPieceFailed
    case generationTimedOut

    public var errorDescription: String? {
        switch self {
        case .unsupportedContext: "Native inference currently permits contexts up to 2048 tokens; longer contexts require device benchmarks."
        case .metalUnavailable: "The requested Metal backend is unavailable. Select explicit CPU mode for a comparison."
        case .modelLoadFailed: "llama.cpp could not validate and load the imported model."
        case .quantizationMismatch: "The model's declared native quantization does not match its reviewed manifest."
        case .contextCreationFailed: "llama.cpp could not allocate the model context."
        case .unsupportedChatTemplate: "The imported model has no chat template supported by this pinned llama.cpp revision."
        case .tokenizationFailed: "The model tokenizer could not process the formatted chat prompt."
        case .promptExceedsContext: "The tokenized chat prompt and output limit exceed the loaded context."
        case .samplerCreationFailed: "llama.cpp could not allocate the configured sampler."
        case .batchAllocationFailed: "llama.cpp could not allocate a decode batch."
        case .decodeFailed: "llama.cpp could not complete the decode batch."
        case .tokenPieceFailed: "llama.cpp could not decode a generated token."
        case .generationTimedOut: "Generation exceeded its configured time limit."
        }
    }
}

/// A callback-safe cancellation bit. Only this small control object crosses the
/// native worker boundary; C resource handles never do.
final class NativeCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var deadlineNanoseconds: UInt64?

    func cancel() { lock.withLock { cancelled = true } }

    func startDeadline(seconds: Double) {
        let duration = UInt64(seconds * 1_000_000_000)
        let now = DispatchTime.now().uptimeNanoseconds
        lock.withLock { deadlineNanoseconds = now &+ duration }
    }

    var isCancelled: Bool { lock.withLock { cancelled } }

    var deadlineExpired: Bool {
        lock.withLock {
            guard let deadlineNanoseconds else { return false }
            return DispatchTime.now().uptimeNanoseconds >= deadlineNanoseconds
        }
    }

    var shouldStop: Bool { isCancelled || deadlineExpired }

    func check() throws {
        if isCancelled { throw CancellationError() }
        if deadlineExpired { throw NativeLlamaCppError.generationTimedOut }
    }
}

/// Retains cancellations delivered before `generate` reaches the worker. Recent
/// completed IDs absorb repeated/delayed cancellation without affecting a new ID.
final class NativeCancellationRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var generations: [UUID: NativeCancellationFlag] = [:]
    private var loads: [ObjectIdentifier: NativeCancellationFlag] = [:]
    private var completedIDs: [UUID] = []
    private var stopping = false
    private var cancellationCapacityExceeded = false
    private let maximumRememberedGenerations = 256

    func registerLoad(_ flag: NativeCancellationFlag) {
        lock.withLock {
            if stopping { flag.cancel() }
            loads[ObjectIdentifier(flag)] = flag
        }
    }

    func finishLoad(_ flag: NativeCancellationFlag) {
        _ = lock.withLock { loads.removeValue(forKey: ObjectIdentifier(flag)) }
    }

    func generation(_ id: UUID) -> NativeCancellationFlag {
        lock.withLock {
            if let flag = generations[id] { return flag }
            let flag = NativeCancellationFlag()
            // Generation IDs must be unique, as required by the adapter.
            if stopping || completedIDs.contains(id) || cancellationCapacityExceeded {
                flag.cancel()
            }
            guard generations.count < maximumRememberedGenerations else {
                // Do not discard an early cancellation and accidentally open
                // its generation. Refuse new work until an unload clears the
                // bounded control registry instead.
                cancellationCapacityExceeded = true
                flag.cancel()
                return flag
            }
            generations[id] = flag
            return flag
        }
    }

    func cancelGeneration(_ id: UUID) {
        lock.withLock {
            guard !completedIDs.contains(id) else { return }
            if generations[id] == nil, generations.count >= maximumRememberedGenerations {
                cancellationCapacityExceeded = true
                return
            }
            let flag = generations[id] ?? NativeCancellationFlag()
            flag.cancel()
            generations[id] = flag
        }
    }

    func finishGeneration(_ id: UUID) {
        lock.withLock {
            generations.removeValue(forKey: id)
            completedIDs.append(id)
            if completedIDs.count > 128 { completedIDs.removeFirst() }
        }
    }

    func cancelAll() {
        lock.withLock {
            stopping = true
            for flag in loads.values { flag.cancel() }
            for flag in generations.values { flag.cancel() }
        }
    }

    /// Call only after the worker has joined every operation.
    func clear() {
        lock.withLock {
            loads.removeAll()
            generations.removeAll()
            completedIDs.removeAll()
            stopping = false
            cancellationCapacityExceeded = false
        }
    }
}

enum NativeInferenceLimits {
    static let maximumContextSize = 2_048
    static let decodeBatchSize = 64

    static func validate(configuration: InferenceConfiguration) throws {
        try configuration.validate()
        guard configuration.contextSize <= maximumContextSize else {
            throw NativeLlamaCppError.unsupportedContext
        }
    }

    static func validate(request: InferenceRequest, configuration: InferenceConfiguration) throws -> Int {
        guard !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.prompt.utf8.count <= configuration.maximumPromptBytes,
              !request.prompt.utf8.contains(0), !request.prompt.contains("<|") else {
            throw RuntimeError.invalidRequest(reason: "Prompt is empty, too large, or contains reserved chat delimiters.")
        }
        let outputTokens = request.maximumOutputTokens ?? configuration.maximumOutputTokens
        guard outputTokens > 0, outputTokens <= configuration.maximumOutputTokens else {
            throw RuntimeError.invalidRequest(reason: "Output token limit exceeds the loaded configuration.")
        }
        return outputTokens
    }

    static func validateTokenBudget(promptTokens: Int, outputTokens: Int, actualContext: Int) throws {
        guard promptTokens > 0, outputTokens > 0, promptTokens <= actualContext,
              outputTokens <= actualContext - promptTokens else {
            throw NativeLlamaCppError.promptExceedsContext
        }
    }
}

/// Maintains only an incomplete UTF-8 suffix (at most three bytes). Invalid bytes
/// are replaced with U+FFFD; embedded NUL is ordinary text, never a terminator.
/// A caller can merge `finish()` into its last native token event to preserve
/// one event per actual token, even when a token limit splits a character.
struct NativeUTF8Decoder {
    private var pending: [UInt8] = []

    mutating func append(_ bytes: [UInt8]) -> String {
        pending.append(contentsOf: bytes)
        var boundary = pending.count
        if !pending.isEmpty {
            var start = pending.count - 1
            while start > 0, pending[start] & 0xC0 == 0x80 { start -= 1 }
            let lead = pending[start]
            let expected: Int
            switch lead {
            case 0xC2...0xDF: expected = 2
            case 0xE0...0xEF: expected = 3
            case 0xF0...0xF4: expected = 4
            default: expected = 1
            }
            if pending.count - start < expected { boundary = start }
        }
        let text = String(decoding: pending.prefix(boundary), as: UTF8.self)
        pending.removeFirst(boundary)
        return text
    }

    mutating func finish() -> String {
        defer { pending.removeAll(keepingCapacity: true) }
        return String(decoding: pending, as: UTF8.self)
    }
}
