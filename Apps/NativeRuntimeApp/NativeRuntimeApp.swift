import Foundation
import SwiftUI
import UIKit

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
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    Task { await runtime.handleMemoryWarning() }
                }
                .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
                    Task { await runtime.handleThermalStateChange() }
                }
        }
    }
}
