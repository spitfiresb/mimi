// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mimi",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Mimi",
            path: "Sources/Mimi",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
