// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Chest",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "Chest", targets: ["Chest"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0"),
    ],
    targets: [
        // Pure logic: the allow list format and menu bar geometry. Tested without a UI.
        .target(name: "ChestCore"),
        .executableTarget(
            name: "Chest",
            dependencies: [
                "ChestCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            linkerSettings: [
                // scripts/package.sh puts Sparkle.framework in Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                // Embeds Info.plist in the binary, so `swift run` already has the bundle
                // identifier (for its preferences) and runs as a menu bar agent.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", Context.packageDirectory + "/Resources/Info.plist",
                ]),
            ]
        ),
        .testTarget(name: "ChestCoreTests", dependencies: ["ChestCore"]),
    ]
)
