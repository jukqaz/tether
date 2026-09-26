// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Tether",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "TetherCore", linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "TetherHelper", dependencies: ["TetherCore"]),
        .executableTarget(name: "Tether", dependencies: ["TetherCore"]),
        .executableTarget(name: "TetherCLI", dependencies: ["TetherCore"]),
        .testTarget(name: "TetherCoreTests", dependencies: ["TetherCore"]),
    ],
    swiftLanguageModes: [.v5]
)
