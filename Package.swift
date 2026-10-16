// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Mekong",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Mekong",
            path: "Sources/Mekong",
            swiftSettings: [
                // Swift 5 language mode: avoids strict-concurrency
                // friction with CoreAudio / Metal callbacks.
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
