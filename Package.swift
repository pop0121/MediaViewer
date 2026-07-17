// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MediaViewer",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MediaViewer", targets: ["MediaViewer"])
    ],
    targets: [
        .executableTarget(name: "MediaViewer")
    ]
)
