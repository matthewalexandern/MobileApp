import SwiftUI

@main
@MainActor
struct NativeRuntimeApp: App {
    @StateObject private var runtime = RuntimeViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(runtime: runtime)
                .task { await runtime.start() }
                .onChange(of: scenePhase) { _, phase in
                    Task { await runtime.handleScenePhase(phase) }
                }
        }
    }
}
