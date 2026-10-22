// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Tether",
    platforms: [.macOS("26.0")],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(name: "TetherCore", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreGraphics"), .linkedFramework("SystemConfiguration"), .linkedFramework("Security"), .linkedLibrary("bsm")]),
        .executableTarget(name: "TetherHelper", dependencies: ["TetherCore"]),
        .executableTarget(name: "TetherRecoveryCLI", dependencies: ["TetherCore"]),
        .executableTarget(name: "Tether", dependencies: ["TetherCore", .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "TetherCLI", dependencies: ["TetherCore"]),
        // Isolated crash-test driver; scripts/build.sh never packages this executable.
        .executableTarget(name: "TetherWriterFixture", dependencies: ["TetherCore"], path: "Tests/PowerWriterFixture"),
        .testTarget(name: "TetherCoreTests", dependencies: ["TetherCore"]),
        .testTarget(name: "TetherUpdateTests", dependencies: ["Tether", "TetherCore", .product(name: "Sparkle", package: "Sparkle")]),
    ],
    swiftLanguageModes: [.v5]
)
