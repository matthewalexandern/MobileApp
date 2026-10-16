import SwiftUI

@MainActor
struct MemoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var pendingForget: MemoryItem?

    var body: some View {
        Group {
            if !model.supports("memory") {
                CapabilityUnavailableView(title: "Memory unavailable", symbol: "brain.head.profile")
            } else {
                List {
                    Section {
                        Label("Private to this iPhone", systemImage: "iphone")
                            .foregroundStyle(KernalTheme.accent)
                        Text("Your local Kernal automatically creates eligible memories from chats. Memories are data, never system instructions.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Section("Find a memory") {
                        TextField("Search terms or a project", text: $query)
                            .submitLabel(.search).onSubmit(search)
                            .accessibilityLabel("Search your private memory")
                        Button(action: search) { Label("Search memory", systemImage: "magnifyingglass") }
                            .disabled(!model.canAct || model.selectedSessionID == nil || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if model.selectedSessionID == nil {
                            Text("Choose a local chat first.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Section(model.isPreview ? "Sample memory" : "Results") {
                        if model.memories.isEmpty {
                            Text("Search to see relevant memories stored in this app’s local SQLite database.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        ForEach(model.memories) { memory in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(alignment: .top) {
                                    Text(verbatim: memory.title).font(.headline)
                                    Spacer(minLength: 4)
                                    Text(verbatim: memory.kind).font(.caption).foregroundStyle(KernalTheme.accent)
                                }
                                Text(verbatim: memory.body).textSelection(.enabled)
                                if !memory.sourceURL.isEmpty {
                                    Text(verbatim: memory.sourceURL)
                                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                HStack {
                                    Text(verbatim: memory.origin).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(memory.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                                }
                                if memory.canForget {
                                    Button("Forget memory", role: .destructive) { pendingForget = memory }
                                        .font(.subheadline).disabled(!model.canAct)
                                        .accessibilityLabel("Forget memory: \(memory.title)")
                                }
                            }
                            .padding(.vertical, 10)
                        }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .navigationTitle("Memory")
        .confirmationDialog("Forget this memory?", isPresented: Binding(
            get: { pendingForget != nil }, set: { if !$0 { pendingForget = nil } }
        ), titleVisibility: .visible) {
            Button("Forget memory", role: .destructive) {
                if let memory = pendingForget { model.forget(memory) }
                pendingForget = nil
            }
            Button("Cancel", role: .cancel) { pendingForget = nil }
        } message: {
                    Text("It will be suppressed from future recall on this device. Existing backups may still contain it.")
        }
    }

    private func search() { model.searchMemory(query) }
}
