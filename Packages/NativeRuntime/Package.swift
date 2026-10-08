// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Keep the portable package usable without Apple binaries. Native integration is
// an explicit build choice; merely having a cached framework must not change it.
let nativeFlag = ProcessInfo.processInfo.environment["NATIVE_RUNTIME_ENABLE_LLAMA"]
if let nativeFlag, nativeFlag != "0" && nativeFlag != "1" {
    fatalError("NATIVE_RUNTIME_ENABLE_LLAMA must be 0 or 1.")
}
let nativeEnabled = nativeFlag == "1"
var adapterDependencies: [Target.Dependency] = ["RuntimeCore"]
var nativeTargets: [Target] = []
if nativeEnabled {
    #if os(macOS)
    let artifactPath = "Artifacts/llama.xcframework"
    let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    guard FileManager.default.fileExists(atPath: packageDirectory.appendingPathComponent(artifactPath).appendingPathComponent("Info.plist").path) else {
        fatalError("Native llama.cpp is enabled, but Artifacts/llama.xcframework is missing. Run scripts/prepare-llama-xcframework.sh from the repository root on macOS with full Xcode, then rebuild with NATIVE_RUNTIME_ENABLE_LLAMA=1.")
    }
    nativeTargets.append(.binaryTarget(name: "llama", path: artifactPath))
    adapterDependencies.append("llama")
    #else
    fatalError("Native llama.cpp integration requires the Apple XCFramework and a macOS/Xcode build host. Leave NATIVE_RUNTIME_ENABLE_LLAMA unset for portable package tests.")
    #endif
}

let package = Package(
    name: "NativeRuntime",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RuntimeCore", targets: ["RuntimeCore"]),
        .library(name: "LlamaCppAdapter", targets: ["LlamaCppAdapter"]),
        .library(name: "RuntimeStorage", targets: ["RuntimeStorage"]),
        .library(name: "RuntimeIntelligence", targets: ["RuntimeIntelligence"])
    ],
    targets: [
        .target(name: "RuntimeCore"),
        .target(name: "LlamaCppAdapter", dependencies: adapterDependencies),
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"])]),
        .target(name: "RuntimeStorage", dependencies: ["CSQLite"]),
        .target(name: "RuntimeIntelligence"),
        .testTarget(name: "RuntimeCoreTests", dependencies: ["RuntimeCore"]),
        .testTarget(name: "LlamaCppAdapterTests", dependencies: ["LlamaCppAdapter", "RuntimeCore"]),
        .testTarget(name: "RuntimeStorageTests", dependencies: ["RuntimeStorage"]),
        .testTarget(name: "RuntimeIntelligenceTests", dependencies: ["RuntimeIntelligence"])
    ] + nativeTargets,
    swiftLanguageModes: [.v6]
)
