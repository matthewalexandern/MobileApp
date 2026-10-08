import SwiftUI

@MainActor
struct ContentView: View {
    @ObservedObject var runtime: RuntimeViewModel

    var body: some View {
        TabView {
            NavigationStack {
                ChatView(runtime: runtime)
            }
            .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }

            NavigationStack {
                VulnerabilitiesView()
            }
            .tabItem { Label("Vulnerabilities", systemImage: "shield.lefthalf.filled") }

            NavigationStack {
                AssetsView()
            }
            .tabItem { Label("Assets", systemImage: "server.rack") }

            NavigationStack {
                ModelSettingsView(runtime: runtime)
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .alert("Runtime message", isPresented: Binding(
            get: { runtime.errorMessage != nil },
            set: { if !$0 { runtime.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { runtime.errorMessage = nil }
        } message: {
            Text(runtime.errorMessage ?? "")
        }
    }
}
