// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Doctopus",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Doctopus",
            path: "Sources/Doctopus",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-Onone"], .when(configuration: .debug)),
            ],
            linkerSettings: [
                // Compiled against the macOS 26 SDK but must launch on macOS 15,
                // where FoundationModels does not exist.
                .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"])
            ]
        )
    ]
)
