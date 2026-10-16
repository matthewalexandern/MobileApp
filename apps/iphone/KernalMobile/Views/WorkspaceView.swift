import SwiftUI

@MainActor
struct WorkspaceView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                StatusPill(title: "Offline workspace", symbol: "iphone")
                Text("Think and code, locally.").font(.title2.bold())
                Text("Ask your local model to write or explain code in Chat. Copy its output into your editor. This app does not execute code on iOS.")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 12) {
                    Label("Model files", systemImage: "doc.zipper").font(.headline)
                    Text("Import a GGUF from Files. Choose a file already downloaded to this device; the app does not download models.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    ModelImportButton().buttonStyle(.bordered)
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(KernalTheme.surface, in: RoundedRectangle(cornerRadius: 18))
                VStack(alignment: .leading, spacing: 18) {
                    unavailable("Terminal execution", symbol: "terminal", reason: "No host shell or code execution engine is included in the offline iPhone app.")
                    unavailable("Virtual machines", symbol: "desktopcomputer", reason: "Server coding VMs are unavailable in this fully offline build.")
                    unavailable("Headless browsing", symbol: "globe", reason: "There is no network browsing or live research in offline mode. The model only knows its training data and local memory.")
                }
            }
            .padding(20)
        }
        .navigationTitle("Workspace")
    }

    private func unavailable(_ title: String, symbol: String, reason: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol).font(.headline)
            Text(reason).font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
