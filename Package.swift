// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mimi",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Mimi",
            // EvalKit for ParakeetEngine — the harness-proven engine is the
            // app's default ASR as of Stage 5 (WER 1.92% vs 2.34%, on-ANE).
            // ObjCShims because AVFoundation reports engine/tap misuse as
            // NSExceptions, which Swift cannot catch without an ObjC @try.
            dependencies: ["EvalKit", "ObjCShims"],
            path: "Sources/Mimi",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(name: "ObjCShims", path: "Sources/ObjCShims"),
        // The eval harness: WER scoring, dataset loading, and engine adapters.
        // A library so both the CLI and the tests can use it. Deliberately free
        // of app types — engines plug in behind one protocol.
        .target(
            name: "EvalKit",
            path: "Sources/EvalKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "mimi-eval",
            dependencies: ["EvalKit"],
            path: "Sources/mimi-eval",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(name: "encprobe", dependencies: ["EvalKit"], path: "Sources/encprobe", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "MimiTests",
            dependencies: ["Mimi", "EvalKit"],
            path: "Tests/MimiTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
