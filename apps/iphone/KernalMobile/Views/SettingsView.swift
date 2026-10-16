import SwiftUI

@MainActor
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            Section("On this iPhone") {
                LabeledContent("Mode", value: model.isPreview ? "Fixed sample preview" : "Fully offline · single user")
                LabeledContent("Model", value: model.status?.modelName ?? "No model loaded")
                if let context = model.status?.nativeContextTarget, context > 0 {
                    LabeledContent(model.isPreview ? "Sample context target" : "Model context target", value: context.formatted())
                    Text("A model’s declared context does not prove it fits this iPhone. Loading fails if its native context cannot be supported; the app does not silently shorten it.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    LabeledContent("Model context", value: "No model loaded")
                }
                ModelImportButton()
                Button("Load imported model") { model.reloadModel() }
                    .disabled(!model.canAct || model.modelLoaded)
                Button("Unload model") { model.unloadModel() }
                    .disabled(!model.canAct || !model.modelLoaded)
                Text("Unloading releases the model. Local chats and memories remain in app storage.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Private local memory") {
                Label("One private workspace on this device", systemImage: "person.crop.circle")
                Label("Protected app storage", systemImage: "lock.shield")
                Label("SQLite and FTS5 memory", systemImage: "brain.head.profile")
                Text("Eligible memories are created automatically from chats. Use “Remember this turn” in Chat to opt out before sending. You can forget memories in the Memory tab.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("This app has no account system. Device access controls protect the local workspace. It does not connect to your server or upload chats, models or memories.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Offline capabilities") {
                capability("Local model generation", enabled: model.modelLoaded)
                capability("Private memory", enabled: !model.isPreview && model.supports("memory"))
                capability("Network and web search", enabled: false)
                capability("Terminal and virtual machines", enabled: false)
            }
            if model.isPreview {
                Section { Button("Exit preview") { model.exitPreview() } }
            }
        }
        .navigationTitle("Settings")
    }

    private func capability(_ title: String, enabled: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            Image(systemName: enabled ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(enabled ? KernalTheme.accent : Color.secondary)
                .accessibilityLabel(enabled ? "Available" : "Unavailable")
        }
    }
}
