import SwiftUI

@MainActor
struct ChatView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingSessions = false

    var body: some View {
        Group {
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.selectedSession?.title ?? "Start a conversation")
                                .font(.headline).lineLimit(2)
                            Text(model.status?.modelName ?? "No model loaded")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        StatusPill(title: model.isPreview ? "Preview" : "On device", symbol: "iphone")
                    }
                    .padding(16)
                    if !model.isPreview && !model.modelLoaded {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Import a compatible GGUF to generate replies on this iPhone.")
                                .font(.subheadline).foregroundStyle(.secondary)
                            ModelImportButton().buttonStyle(.bordered)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                    Divider()
                    conversation
                    Divider()
                    composer
                }
        }
        .navigationTitle("Kernal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showingSessions = true } label: { Image(systemName: "sidebar.left") }
                    .accessibilityLabel("Choose or create a chat")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { model.refreshMessages() } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Refresh conversation")
                    .disabled(!model.canAct || model.selectedSessionID == nil)
            }
        }
        .sheet(isPresented: $showingSessions) { SessionPicker() }
    }

    private var conversation: some View {
        ScrollViewReader { reader in
            ScrollView {
                if model.messages.isEmpty {
                    ContentUnavailableView(
                        model.selectedSessionID == nil ? "A space for your next idea" : "What are we building?",
                        systemImage: "sparkle",
                        description: Text(model.selectedSessionID == nil ? "Choose or create a chat to begin." : "Ask your local model to explain, write code or help reason through an idea."))
                        .padding(.top, 40)
                } else {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(model.messages) { message in
                            VStack(alignment: .leading, spacing: 8) {
                                Label(message.role == "user" ? "You" : "Kernal",
                                    systemImage: message.role == "user" ? "person.crop.circle" : "square.stack.3d.up")
                                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text(verbatim: message.text)
                                    .font(.body).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(16)
                            .background(message.role == "user" ? KernalTheme.surface : Color.clear,
                                in: RoundedRectangle(cornerRadius: 18))
                            .id(message.id)
                        }
                    }
                    .padding(16)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.messages.count) { _, _ in
                if let last = model.messages.last { reader.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let status = model.memoryStatus {
                Label(memoryLabel(status), systemImage: status == "failed" ? "exclamationmark.circle" : "brain")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message your Kernal", text: $model.draftText, axis: .vertical)
                    .lineLimit(1...7).padding(12)
                    .background(KernalTheme.surface, in: RoundedRectangle(cornerRadius: 15))
                    .accessibilityLabel("Message")
                    .disabled(model.isPreview || !model.modelLoaded || model.selectedSessionID == nil)
                Button { model.sendMessage() } label: {
                    Image(systemName: "arrow.up").font(.headline)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.circle)
                .foregroundStyle(KernalTheme.background)
                .accessibilityLabel("Send message")
                .disabled(!model.canAct || !model.modelLoaded || model.selectedSessionID == nil || model.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Toggle(isOn: $model.memoryEnabled) {
                Text("Remember this turn").font(.caption)
            }
            .toggleStyle(.switch).controlSize(.small)
            .disabled(model.isPreview || !model.supports("memory"))
            .accessibilityHint("Eligible memories are generated automatically. Turn off to exclude this turn.")
        }
        .padding(16)
    }

    private func memoryLabel(_ status: String) -> String {
        switch status {
        case "scheduled": return "Private memory is processing automatically"
        case "complete": return model.isPreview ? "Sample private memory" : "Private memory processed"
        case "disabled": return "Memory was off for this turn"
        case "failed": return "Local memory processing failed"
        default: return "Memory status unavailable"
        }
    }
}

@MainActor
private struct SessionPicker: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Your chats") {
                    if model.sessions.isEmpty { Text("No chats yet").foregroundStyle(.secondary) }
                    ForEach(model.sessions) { session in
                        Button {
                            model.selectSession(session)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(verbatim: session.title).foregroundStyle(.primary)
                                    Text(session.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if session.id == model.selectedSessionID { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
                Section("New chat") {
                    TextField("Chat title", text: $title)
                    Button("Create chat") {
                        model.createSession(title: title)
                        dismiss()
                    }
                    .disabled(!model.canAct || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Conversations")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.refreshSessions() } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Refresh chats").disabled(!model.canAct)
                }
            }
        }
    }
}
