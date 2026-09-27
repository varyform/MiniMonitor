// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MiniMonitor",
    platforms: [.macOS(.v13)],
    targets: [
        // Header-only C module: SwiftPM needs no sources for a system library target.
        .systemLibrary(name: "SMC"),
        .executableTarget(name: "MiniMonitor", dependencies: ["SMC"]),
    ]
)
