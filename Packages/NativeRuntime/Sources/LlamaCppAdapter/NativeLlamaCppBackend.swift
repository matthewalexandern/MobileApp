#if canImport(llama)
import Foundation
import RuntimeCore
import llama

private let nativeLoadProgress: llama_progress_callback = { _, data in
    guard let data else { return false }
    return !Unmanaged<NativeCancellationFlag>.fromOpaque(data).takeUnretainedValue().isCancelled
}

private let nativeDecodeAbort: ggml_abort_callback = { data in
    guard let data else { return true }
    return Unmanaged<NativeCancellationFlag>.fromOpaque(data).takeUnretainedValue().shouldStop
}

/// Balances the process-global C lifetime across independently owned workers.
/// The lock covers init/free so a final unload cannot race another model load.
private final class NativeBackendLifetime: @unchecked Sendable {
    static let shared = NativeBackendLifetime()
    private let lock = NSLock()
    private var references = 0

    func acquire() {
        lock.withLock {
            if references == 0 {
                // Upstream diagnostics may include a local path or model text.
                // Expose sanitized Swift errors instead of forwarding C logs.
                llama_log_set({ _, _, _ in }, nil)
                llama_backend_init()
            }
            references += 1
        }
    }

    func release() {
        lock.withLock {
            precondition(references > 0)
            references -= 1
            if references == 0 { llama_backend_free() }
        }
    }
}

/// Concrete implementation for the immutable llama.cpp b7110 API. All model,
/// context, batch, sampler, and vocabulary access runs on one dedicated serial
/// Dispatch worker. `@unchecked Sendable` protects only this queue ownership;
/// the callback cancellation flag has its own lock.
public final class NativeLlamaCppBackend: LlamaCppBackend, @unchecked Sendable {
    private let queue = DispatchQueue(label: "NativeRuntime.llama.worker", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let state = NativeWorkerState()
    private let cancellationRegistry = NativeCancellationRegistry()

    public init() { queue.setSpecific(key: queueKey, value: true) }

    deinit {
        cancellationRegistry.cancelAll()
        if DispatchQueue.getSpecific(key: queueKey) == true {
            state.destroy()
        } else {
            queue.sync { state.destroy() }
        }
    }

    public func load(
        model: ValidatedModel,
        configuration: InferenceConfiguration,
        acceleration: LlamaCppAcceleration
    ) async throws {
        try NativeInferenceLimits.validate(configuration: configuration)
        try Task.checkCancellation()
        let flag = NativeCancellationFlag()
        cancellationRegistry.registerLoad(flag)
        defer { cancellationRegistry.finishLoad(flag) }
        try await withTaskCancellationHandler {
            try await perform { state in
                try flag.check()
                try state.load(model: model, configuration: configuration, acceleration: acceleration, flag: flag)
            }
            if Task.isCancelled {
                // Cancellation can arrive immediately after the final native
                // load check. A throwing load still releases its own handles.
                await join { state in state.destroy() }
                throw CancellationError()
            }
        } onCancel: { flag.cancel() }
    }

    public func unload() async {
        cancellationRegistry.cancelAll()
        await join { state in state.destroy() }
        cancellationRegistry.clear()
    }

    public func generate(
        request: InferenceRequest,
        generationID: UUID
    ) async throws -> AsyncThrowingStream<InferenceEvent, Error> {
        try Task.checkCancellation()
        let flag = cancellationRegistry.generation(generationID)
        let state = self.state
        let registry = cancellationRegistry
        let queue = self.queue
        // Reserving at most the configured maximum prevents unbounded native
        // output buffering even if the adapter consumer does not start reading.
        let (stream, output) = AsyncThrowingStream<InferenceEvent, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(1_025)
        )
        output.onTermination = { termination in
            if case .cancelled = termination { flag.cancel() }
        }
        return try await withTaskCancellationHandler {
            return try await withCheckedThrowingContinuation { opening in
                queue.async {
                    do {
                        try flag.check()
                        guard let configuration = state.configuration, state.context != nil else {
                            throw RuntimeError.invalidState(operation: "generate", state: "unloaded")
                        }
                        let limit = try NativeInferenceLimits.validate(request: request, configuration: configuration)
                        // Resume opening, then decode in THIS queued block. A
                        // cancellation/unload barrier necessarily joins this
                        // complete operation, including GPU synchronization.
                        opening.resume(returning: stream)
                        do {
                            let metrics = try state.run(
                                request: request, outputTokens: limit, flag: flag, output: output
                            )
                            registry.finishGeneration(generationID)
                            try Self.emit(.finished(metrics), to: output)
                            output.finish()
                        } catch {
                            registry.finishGeneration(generationID)
                            output.finish(throwing: error)
                        }
                    } catch {
                        registry.finishGeneration(generationID)
                        output.finish(throwing: error)
                        opening.resume(throwing: error)
                    }
                }
            }
        } onCancel: { flag.cancel() }
    }

    public func cancelGeneration(generationID: UUID) async {
        cancellationRegistry.cancelGeneration(generationID)
        // The flag is visible without waiting for the busy queue. The barrier
        // returns only after the associated stream is finished and GPU work
        // has joined. A later generation's flag is unaffected.
        await join { _ in }
    }

    private func perform<T: Sendable>(
        _ operation: @escaping @Sendable (NativeWorkerState) throws -> T
    ) async throws -> T {
        let state = self.state
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try operation(state)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func join(_ operation: @escaping @Sendable (NativeWorkerState) -> Void) async {
        let state = self.state
        await withCheckedContinuation { continuation in
            queue.async {
                operation(state)
                continuation.resume()
            }
        }
    }

    fileprivate static func emit(
        _ event: InferenceEvent,
        to output: AsyncThrowingStream<InferenceEvent, Error>.Continuation
    ) throws {
        switch output.yield(event) {
        case .enqueued: break
        case .dropped: throw LlamaCppAdapterError.consumerTooSlow
        case .terminated: throw CancellationError()
        @unknown default: throw LlamaCppAdapterError.consumerTooSlow
        }
    }
}

/// This state is never accessed outside its owning serial worker. Its Sendable
/// annotation allows the owner to enqueue blocks without exporting C handles.
private final class NativeWorkerState: @unchecked Sendable {
    var context: OpaquePointer?
    var configuration: InferenceConfiguration?
    private var model: OpaquePointer?
    private var backendAcquired = false

    func load(
        model candidate: ValidatedModel,
        configuration: InferenceConfiguration,
        acceleration: LlamaCppAcceleration,
        flag: NativeCancellationFlag
    ) throws {
        guard model == nil, context == nil else {
            throw RuntimeError.invalidState(operation: "load", state: "loaded")
        }
        guard candidate.fileURL.isFileURL, !candidate.fileURL.path.utf8.contains(0) else {
            throw NativeLlamaCppError.modelLoadFailed
        }
        NativeBackendLifetime.shared.acquire()
        backendAcquired = true
        do {
            var modelParameters = llama_model_default_params()
            modelParameters.n_gpu_layers = acceleration == .metal ? Int32.max : 0
            modelParameters.check_tensors = true
            modelParameters.progress_callback = nativeLoadProgress
            modelParameters.progress_callback_user_data = Unmanaged.passUnretained(flag).toOpaque()
            var devices: [OpaquePointer?] = [nil]
            if acceleration == .metal {
                #if targetEnvironment(simulator)
                throw NativeLlamaCppError.metalUnavailable
                #else
                guard llama_supports_gpu_offload(), let device = metalDevice() else {
                    throw NativeLlamaCppError.metalUnavailable
                }
                devices = [device, nil]
                #endif
            }
            let loaded = devices.withUnsafeMutableBufferPointer { buffer in
                modelParameters.devices = buffer.baseAddress
                return candidate.fileURL.path.withCString {
                    llama_model_load_from_file($0, modelParameters)
                }
            }
            model = loaded
            try flag.check()
            guard let loaded else { throw NativeLlamaCppError.modelLoadFailed }
            let declaredType = try metadata("general.file_type", model: loaded)
            let expectedType = candidate.manifest.quantization == .q8_0
                ? LLAMA_FTYPE_MOSTLY_Q8_0.rawValue : LLAMA_FTYPE_MOSTLY_Q4_K_M.rawValue
            guard UInt32(declaredType) == expectedType else { throw NativeLlamaCppError.quantizationMismatch }
            // A missing or unknown template fails closed; do not substitute a
            // plaintext prompt or a guessed template based on the model name.
            _ = try formattedPrompt("Template compatibility check.", model: loaded, maximumBytes: 4_096)

            var parameters = llama_context_default_params()
            parameters.n_ctx = UInt32(configuration.contextSize)
            parameters.n_batch = UInt32(NativeInferenceLimits.decodeBatchSize)
            parameters.n_ubatch = UInt32(NativeInferenceLimits.decodeBatchSize)
            parameters.n_seq_max = 1
            let threads = Int32(max(1, min(8, ProcessInfo.processInfo.processorCount - 2)))
            parameters.n_threads = threads
            parameters.n_threads_batch = threads
            parameters.offload_kqv = acceleration == .metal
            parameters.op_offload = acceleration == .metal
            context = llama_init_from_model(loaded, parameters)
            try flag.check()
            guard let context else { throw NativeLlamaCppError.contextCreationFailed }
            guard llama_n_ctx(context) >= UInt32(configuration.contextSize), llama_get_memory(context) != nil else {
                throw NativeLlamaCppError.contextCreationFailed
            }
            self.configuration = configuration
        } catch {
            destroy()
            throw error
        }
    }

    func destroy() {
        if let context {
            llama_synchronize(context)
            llama_set_abort_callback(context, nil, nil)
            llama_free(context)
            self.context = nil
        }
        if let model { llama_model_free(model); self.model = nil }
        configuration = nil
        if backendAcquired {
            backendAcquired = false
            NativeBackendLifetime.shared.release()
        }
    }

    func run(
        request: InferenceRequest,
        outputTokens: Int,
        flag: NativeCancellationFlag,
        output: AsyncThrowingStream<InferenceEvent, Error>.Continuation
    ) throws -> InferenceMetrics {
        guard let model, let context, let configuration, let vocabulary = llama_model_get_vocab(model) else {
            throw RuntimeError.invalidState(operation: "generate", state: "unloaded")
        }
        guard let memory = llama_get_memory(context) else { throw NativeLlamaCppError.contextCreationFailed }
        let started = DispatchTime.now().uptimeNanoseconds
        flag.startDeadline(seconds: configuration.generationTimeoutSeconds)
        try flag.check()
        let formatted = try formattedPrompt(
            request.prompt, model: model, maximumBytes: configuration.maximumPromptBytes * 4 + 4_096
        )
        let tokens = try tokenize(formatted, vocabulary: vocabulary)
        try NativeInferenceLimits.validateTokenBudget(
            promptTokens: tokens.count, outputTokens: outputTokens, actualContext: Int(llama_n_ctx(context))
        )
        guard let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params()) else {
            throw NativeLlamaCppError.samplerCreationFailed
        }
        defer { llama_sampler_free(sampler) }
        try addSampler(llama_sampler_init_top_p(Float(configuration.sampling.topP), 1), to: sampler)
        try addSampler(llama_sampler_init_temp(Float(configuration.sampling.temperature)), to: sampler)
        try addSampler(llama_sampler_init_dist(configuration.sampling.seed), to: sampler)

        var batch = llama_batch_init(Int32(NativeInferenceLimits.decodeBatchSize), 0, 1)
        defer { llama_batch_free(batch) }
        guard batch.token != nil, batch.pos != nil, batch.n_seq_id != nil,
              batch.seq_id != nil, batch.logits != nil else {
            throw NativeLlamaCppError.batchAllocationFailed
        }
        llama_memory_clear(memory, true)
        llama_set_abort_callback(context, nativeDecodeAbort, Unmanaged.passUnretained(flag).toOpaque())
        defer {
            // The pinned abort callback is CPU-only. Metal cancellation waits
            // for the current bounded decode batch and joins it here.
            llama_synchronize(context)
            llama_set_abort_callback(context, nil, nil)
            llama_memory_clear(memory, true)
        }

        var offset = 0
        while offset < tokens.count {
            try flag.check()
            let count = min(NativeInferenceLimits.decodeBatchSize, tokens.count - offset)
            batch.n_tokens = Int32(count)
            for index in 0..<count {
                try setBatchToken(&batch, index: index, token: tokens[offset + index], position: offset + index,
                                  logits: offset + index == tokens.count - 1)
            }
            try decode(context: context, batch: batch, flag: flag)
            offset += count
        }

        let generationStarted = DispatchTime.now().uptimeNanoseconds
        var decoder = NativeUTF8Decoder()
        var pendingEvent: String?
        var tokenCount = 0
        var firstTokenTime: Double?
        func emitToken(_ text: String) throws {
            try flag.check()
            try NativeLlamaCppBackend.emit(.token(text), to: output)
            if firstTokenTime == nil { firstTokenTime = secondsSince(started) }
        }
        for index in 0..<outputTokens {
            try flag.check()
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocabulary, token) { break }
            // One-token lookahead lets an incomplete final UTF-8 suffix attach
            // to its real token event instead of inventing another token.
            if let pendingEvent { try emitToken(pendingEvent) }
            pendingEvent = decoder.append(try piece(token, vocabulary: vocabulary))
            tokenCount += 1
            if index == outputTokens - 1 { break }
            batch.n_tokens = 1
            try setBatchToken(&batch, index: 0, token: token, position: tokens.count + index, logits: true)
            try decode(context: context, batch: batch, flag: flag)
        }
        if let pendingEvent { try emitToken(pendingEvent + decoder.finish()) }
        try flag.check()
        return InferenceMetrics(
            generatedTokenCount: tokenCount,
            timeToFirstTokenSeconds: firstTokenTime,
            durationSeconds: secondsSince(started),
            generationDurationSeconds: secondsSince(generationStarted)
        )
    }

    private func decode(context: OpaquePointer, batch: llama_batch, flag: NativeCancellationFlag) throws {
        try flag.check()
        let code = llama_decode(context, batch)
        llama_synchronize(context)
        try flag.check()
        guard code == 0 else { throw NativeLlamaCppError.decodeFailed(code: code) }
    }

    private func setBatchToken(
        _ batch: inout llama_batch, index: Int, token: llama_token, position: Int, logits: Bool
    ) throws {
        guard let sequence = batch.seq_id[index] else { throw NativeLlamaCppError.batchAllocationFailed }
        batch.token[index] = token
        batch.pos[index] = Int32(position)
        batch.n_seq_id[index] = 1
        sequence[0] = 0
        batch.logits[index] = logits ? 1 : 0
    }

    private func addSampler(_ child: UnsafeMutablePointer<llama_sampler>?, to chain: UnsafeMutablePointer<llama_sampler>) throws {
        guard let child else { throw NativeLlamaCppError.samplerCreationFailed }
        llama_sampler_chain_add(chain, child)
    }

    private func metalDevice() -> OpaquePointer? {
        for index in 0..<ggml_backend_dev_count() {
            guard let device = ggml_backend_dev_get(index),
                  let backend = ggml_backend_dev_backend_reg(device),
                  let name = ggml_backend_reg_name(backend) else { continue }
            if String(cString: name) == "Metal" { return device }
        }
        return nil
    }

    private func metadata(_ key: String, model: OpaquePointer) throws -> String {
        let count = llama_model_meta_val_str(model, key, nil, 0)
        guard count >= 0, count < 4_096 else { throw NativeLlamaCppError.quantizationMismatch }
        var bytes = [CChar](repeating: 0, count: Int(count) + 1)
        let actual = llama_model_meta_val_str(model, key, &bytes, bytes.count)
        guard actual == count else { throw NativeLlamaCppError.quantizationMismatch }
        return String(decoding: bytes.prefix(Int(count)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func formattedPrompt(_ prompt: String, model: OpaquePointer, maximumBytes: Int) throws -> String {
        guard let template = llama_model_chat_template(model, nil) else {
            throw NativeLlamaCppError.unsupportedChatTemplate
        }
        return try "user".withCString { role in
            try prompt.withCString { content in
                var message = llama_chat_message(role: role, content: content)
                let size = llama_chat_apply_template(template, &message, 1, true, nil, 0)
                guard size > 0, Int(size) <= maximumBytes else { throw NativeLlamaCppError.unsupportedChatTemplate }
                var result = [CChar](repeating: 0, count: Int(size) + 1)
                let actual = llama_chat_apply_template(template, &message, 1, true, &result, Int32(result.count))
                guard actual == size,
                      let text = String(bytes: result.prefix(Int(size)).map { UInt8(bitPattern: $0) }, encoding: .utf8) else {
                    throw NativeLlamaCppError.unsupportedChatTemplate
                }
                return text
            }
        }
    }

    private func tokenize(_ text: String, vocabulary: OpaquePointer) throws -> [llama_token] {
        try text.withCString { content in
            let required = llama_tokenize(vocabulary, content, Int32(text.utf8.count), nil, 0, true, true)
            guard required < 0, required != Int32.min,
                  -required <= Int32(NativeInferenceLimits.maximumContextSize) else {
                throw NativeLlamaCppError.promptExceedsContext
            }
            var tokens = [llama_token](repeating: 0, count: Int(-required))
            let actual = llama_tokenize(vocabulary, content, Int32(text.utf8.count), &tokens, -required, true, true)
            guard actual > 0, actual == -required else { throw NativeLlamaCppError.tokenizationFailed }
            return tokens
        }
    }

    private func piece(_ token: llama_token, vocabulary: OpaquePointer) throws -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 32)
        var count = llama_token_to_piece(vocabulary, token, &buffer, Int32(buffer.count), 0, false)
        if count < 0 {
            guard count != Int32.min, -count <= 1_048_576 else { throw NativeLlamaCppError.tokenPieceFailed }
            buffer = [CChar](repeating: 0, count: Int(-count))
            count = llama_token_to_piece(vocabulary, token, &buffer, Int32(buffer.count), 0, false)
        }
        guard count >= 0, Int(count) <= buffer.count else { throw NativeLlamaCppError.tokenPieceFailed }
        return buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }
    }

    private func secondsSince(_ start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    }
}
#endif
