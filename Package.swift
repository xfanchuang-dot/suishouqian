// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "随手迁",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "随手迁",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Suishouqian",
            resources: [
                .process("Assets.xcassets")
            ]
        ),
        .testTarget(
            name: "SuishouqianTests",
            dependencies: [.target(name: "随手迁")],
            path: "Tests/SuishouqianTests"
        )
    ]
)
