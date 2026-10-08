// swift-tools-version: 6.0
import PackageDescription

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
        .target(name: "LlamaCppAdapter", dependencies: ["RuntimeCore"]),
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"])]),
        .target(name: "RuntimeStorage", dependencies: ["CSQLite"]),
        .target(name: "RuntimeIntelligence"),
        .testTarget(name: "RuntimeCoreTests", dependencies: ["RuntimeCore"]),
        .testTarget(name: "LlamaCppAdapterTests", dependencies: ["LlamaCppAdapter", "RuntimeCore"]),
        .testTarget(name: "RuntimeStorageTests", dependencies: ["RuntimeStorage"]),
        .testTarget(name: "RuntimeIntelligenceTests", dependencies: ["RuntimeIntelligence"])
    ],
    swiftLanguageModes: [.v6]
)
