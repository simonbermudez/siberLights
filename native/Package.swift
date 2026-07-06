// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SiberLights",
    platforms: [.macOS("14.0")],
    targets: [
        .executableTarget(
            name: "SiberLights",
            path: "Sources/SiberLights"
        )
    ]
)
