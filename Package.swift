// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DoyahCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "DoyahCore",
            targets: ["DoyahCore"]
        )
    ],
    dependencies: [
        .package(path: "Vendor/postgres-nio")
    ],
    targets: [
        .target(
            name: "DoyahCore",
            dependencies: [
                .product(name: "PostgresNIO", package: "postgres-nio")
            ],
            path: "Core"
        ),
        // 平台适配层：只有这里可以 import 平台专属框架（Security / Darwin …）。
        // Core 不含任何平台依赖，这条边界由模块依赖关系强制，而不是靠自觉 ——
        // 见 Scripts/check-core-portability.py（静态闸门）与需求书 §0.8。
        .target(
            name: "DoyahPlatform",
            dependencies: ["DoyahCore"],
            path: "Platform/macOS"
        ),
        .executableTarget(
            name: "DoyahCLI",
            dependencies: ["DoyahCore"],
            path: "CLI"
        ),
        // 让 SwiftPM 也能编译 App 源码（Xcode 工程之外的第二条验证路径）。
        // 打包成 .app 由 Scripts/build-app.sh 负责。
        .executableTarget(
            name: "DoyahStudioApp",
            dependencies: ["DoyahCore", "DoyahPlatform"],
            path: "App",
            // Resources 由 Scripts/build-app.sh 装进 .app；SwiftPM 不处理 .icns/.png，
            // 不排除会报 unhandled files。
            exclude: ["DoyahStudio.entitlements", "Resources"]
        ),
        .testTarget(
            name: "DoyahCoreTests",
            dependencies: ["DoyahCore"],
            path: "Tests"
        ),
        // 平台适配层的测试单独一个 target：真实书签这类用例必须跑在**真实实现**上，
        // 放在 Core 测试里就只能测假实现，等于把最有价值的一条覆盖丢掉。
        .testTarget(
            name: "DoyahPlatformTests",
            dependencies: ["DoyahCore", "DoyahPlatform"],
            path: "TestsPlatform"
        )
    ]
)
