import SwiftUI

@MainActor
struct ChatView: View {
    @ObservedObject var runtime: RuntimeViewModel
    @State private var prompt = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            statusBanner
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if runtime.messages.isEmpty {
                            ContentUnavailableView(
                                "Private by design",
                                systemImage: "lock.shield",
                                description: Text("Try the streaming demonstration. Messages stay in this session; durable conversation storage comes in a later milestone.")
                            )
                            .padding(.top, 40)
                        }
                        ForEach(runtime.messages) { message in
                            messageView(message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: runtime.messages.last?.text) { _, _ in
                    if let lastID = runtime.messages.last?.id {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
            composer
        }
        .navigationTitle("Local Security")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear", systemImage: "trash") {
                    runtime.clearConversation()
                }
                .disabled(runtime.messages.isEmpty || runtime.isGenerating)
            }
        }
    }

    private var statusBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(runtime.selection.title, systemImage: runtime.selection == .demonstration ? "play.rectangle" : "cpu")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(runtime.statusDescription)
                    .font(.caption)
            }
            Text(runtime.selection == .demonstration
                 ? "Scripted mock output. No AI model is running."
                 : "Local model output is untrusted guidance. Review authoritative sources before remediation.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if runtime.selection == .native, let model = runtime.importedModel {
                Text("Selected: \(model.manifest.displayName) · \(model.manifest.quantization.rawValue)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if runtime.selection == .demonstration, !runtime.isReady, !runtime.isBusy {
                Button("Start demonstration") {
                    Task { await runtime.startDemonstration() }
                }
                .font(.subheadline)
            }
        }
        .padding()
        .background(.thinMaterial)
    }

    private func messageView(_ message: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message.role == .user ? "You" : message.origin == .demonstration ? "Demonstration" : "Local model")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(message.text.isEmpty
                 ? (message.wasCancelled ? "Response cancelled." : message.failed ? "Response failed." : "Waiting for output…")
                 : message.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if message.wasCancelled, !message.text.isEmpty {
                Text("Response cancelled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if message.failed, !message.text.isEmpty {
                Text("Response failed before completion.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(message.role == .user ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message", text: $prompt, axis: .vertical)
                .lineLimit(1...5)
                .focused($composerFocused)
                .textFieldStyle(.roundedBorder)
                .disabled(!runtime.isReady || runtime.isBusy || runtime.isGenerating)
                .onSubmit { sendMessage() }
            if runtime.isGenerating {
                Button("Cancel", systemImage: "stop.circle.fill") {
                    runtime.cancelGeneration()
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel("Cancel response")
            } else {
                Button("Send", systemImage: "arrow.up.circle.fill", action: sendMessage)
                    .labelStyle(.iconOnly)
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !runtime.isReady || runtime.isBusy || runtime.isGenerating)
            }
        }
        .font(.title2)
        .padding()
        .background(.bar)
    }

    private func sendMessage() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 16_384,
              runtime.isReady, !runtime.isGenerating, !runtime.isBusy else {
            if text.utf8.count > 16_384 {
                runtime.errorMessage = "Keep the message below 16 KB for this initial runtime."
            }
            return
        }
        runtime.send(text)
        prompt = ""
        composerFocused = false
    }
}
