import Foundation

/// A deterministic UI and concurrency fixture. It performs no model inference and never opens a GGUF.
public actor MockInferenceEngine: InferenceEngine {
    public nonisolated let mode: InferenceMode = .demonstration
    public static let demonstrationNotice = "Demonstration mode — no local model inference is running."

    private var configuration: InferenceConfiguration?

    public init() {}

    public func load(model: ValidatedModel, configuration: InferenceConfiguration) async throws {
        try configuration.validate()
        try Task.checkCancellation()
        self.configuration = configuration
    }

    public func unload() async {
        configuration = nil
    }

    public func generate(request: InferenceRequest) async throws -> AsyncThrowingStream<InferenceEvent, Error> {
        guard let configuration else {
            throw RuntimeError.invalidState(operation: "generate", state: "uninstalled")
        }
        let maximumTokens = request.maximumOutputTokens ?? configuration.maximumOutputTokens
        guard (1...configuration.maximumOutputTokens).contains(maximumTokens),
              !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.prompt.utf8.count <= configuration.maximumPromptBytes else {
            throw RuntimeError.invalidRequest(reason: "The demonstration request exceeds the configured limits or has an empty prompt.")
        }
        try Task.checkCancellation()

        // Do not echo potentially private prompts or produce fabricated security findings.
        let tokens = [
            Self.demonstrationNotice + "\n\n",
            "Use this screen to verify streaming, cancellation, and model lifecycle controls. ",
            "Import a verified model and connect the native backend to enable local inference. ",
            "Security actions require explicit review and approval."
        ]
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(tokens.count + 1)) { continuation in
            let producer = Task {
                do {
                    for token in tokens.prefix(maximumTokens) {
                        try Task.checkCancellation()
                        continuation.yield(.token(token))
                        await Task.yield()
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: RuntimeError.cancelled)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    /// Internal fixture identity used only by startDemonstration(). It is never passed to ModelImporter.
    static let demonstrationModel = ValidatedModel(
        fileURL: URL(fileURLWithPath: "/demonstration/no-model-weights"),
        manifest: ModelManifest(
            id: "demonstration-only",
            displayName: "Demonstration — no model loaded",
            quantization: .q4_k_m,
            expectedByteCount: 0,
            sha256: String(repeating: "0", count: 64),
            provenance: ModelProvenance(
                sourceURL: URL(string: "https://example.invalid/demonstration")!,
                revision: "demonstration-only",
                license: "No model weights"
            )
        )
    )
}
