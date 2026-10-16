import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            KernalTheme.background.ignoresSafeArea()
            if model.isWorkspaceOpen { MainTabs() } else { WelcomeView() }
            if scenePhase != .active {
                KernalTheme.background.ignoresSafeArea()
                VStack(spacing: 14) {
                    Image(systemName: "lock.shield.fill").font(.system(size: 42))
                    Text("Kernal").font(.title.bold())
                    Text("Your workspace is private").foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .tint(KernalTheme.accent)
        .task { model.restoreOnce() }
        .alert("Couldn’t complete request", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(verbatim: model.errorMessage ?? "") }
    }
}

@MainActor
private struct MainTabs: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.isPreview {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "eye")
                    Text("Preview · Fixed sample screens. No AI generation.").font(.caption)
                    Spacer(minLength: 0)
                    Button("Exit") { model.exitPreview() }.font(.caption.bold())
                }
                .padding(12).background(KernalTheme.accent.opacity(0.12))
            }
            OperationStatusView()
            if let notice = model.notice {
                HStack(alignment: .top) {
                    Text(verbatim: notice).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button { model.notice = nil } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Dismiss notice")
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            TabView {
                NavigationStack { ChatView() }
                    .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                NavigationStack { MemoryView() }
                    .tabItem { Label("Memory", systemImage: "brain.head.profile") }
                NavigationStack { WorkspaceView() }
                    .tabItem { Label("Workspace", systemImage: "doc.text") }
                NavigationStack { SettingsView() }
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
        }
    }
}

@MainActor
struct OperationStatusView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        if model.isWorking {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(model.operationLabel).font(.caption)
                Spacer()
                Button("Cancel") { model.cancel() }.font(.caption.bold())
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }
}

@MainActor
struct ModelImportButton: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingImporter = false

    var body: some View {
        Button { showingImporter = true } label: {
            Label("Import GGUF model", systemImage: "square.and.arrow.down")
        }
        .disabled(model.isWorking || model.isPreview)
        .fileImporter(isPresented: $showingImporter,
            allowedContentTypes: [UTType(filenameExtension: "gguf") ?? .data],
            allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { model.importModel(from: url) }
                case .failure(let error):
                    if (error as? CocoaError)?.code != .userCancelled {
                        model.errorMessage = "The model file could not be opened. Choose a GGUF file already downloaded to this iPhone."
                    }
                }
            }
    }
}

@MainActor
private struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 38)).foregroundStyle(KernalTheme.accent)
                    .padding(18).background(KernalTheme.surface, in: RoundedRectangle(cornerRadius: 22))
                    .accessibilityHidden(true)
                StatusPill(title: "Fully on this iPhone", symbol: "iphone")
                Text("Your Kernal.\nAnywhere, offline.")
                    .font(.largeTitle.bold()).fixedSize(horizontal: false, vertical: true)
                Text("Run a compatible local model, keep private memories and work through ideas without an AI server or account.")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 14) {
                    Text("Bring your model").font(.headline)
                    Text("Choose a GGUF already downloaded to this iPhone. Model size and context must fit your device’s available memory. Importing a model does not establish its quality or speed.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    ModelImportButton()
                        .buttonStyle(.borderedProminent).foregroundStyle(KernalTheme.background)
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .background(KernalTheme.surface, in: RoundedRectangle(cornerRadius: 20))
                OperationStatusView()
                if let notice = model.notice {
                    Text(verbatim: notice).font(.footnote).foregroundStyle(.secondary)
                }
                Button("Open local chats and memory") { model.openWorkspace() }
                    .disabled(model.isWorking)
                Button("Explore a preview") { model.enterPreview() }.disabled(model.isWorking)
                Text("Your model, chats and SQLite memory stay in the app’s protected storage. No telemetry, login, web search or network inference.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(26).frame(maxWidth: 600).frame(maxWidth: .infinity)
        }
    }
}
