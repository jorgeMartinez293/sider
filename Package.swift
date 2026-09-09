// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "sider",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        // Sparkle: in-app auto-updates. Ships as a binary XCFramework; `make` embeds
        // Sparkle.framework into the .app bundle (swift build alone doesn't).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "sider",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/sider"
        ),
        .testTarget(
            name: "siderTests",
            dependencies: ["sider"],
            path: "Tests/siderTests"
        ),
    ]
)
