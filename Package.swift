// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "随手迁",
    defaultLocalization: "zh-Hans",
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
                .process("Assets.xcassets"),
                // 文案只来自 .lproj。String Catalog 会再编译出同名 Localizable.strings，
                // 和新工具链里的 .lproj 拷贝撞车（Multiple commands produce）。
                .process("en.lproj"),
                .process("zh-Hans.lproj"),
            ]
        ),
        .testTarget(
            name: "SuishouqianTests",
            dependencies: [.target(name: "随手迁")],
            path: "Tests/SuishouqianTests"
        )
    ]
)
