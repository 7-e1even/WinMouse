// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WinMouse",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "WinMouse", path: "Sources/WinMouse")
    ]
)
