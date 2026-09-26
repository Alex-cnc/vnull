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
        // 依赖一律**随仓库带走**（Vendor/，见 §8.2）：版本可复现、离线可构建，
        // 不因为上游发新版就把这个工程编不过。许可证随目录一起留档（都是 Apache-2.0）。
        .package(path: "Vendor/postgres-nio"),
        .package(path: "Vendor/mysql-nio"),
        // 许可校验要 Ed25519 签名（FR-LIC-01）：用 **swift-crypto** 而不是 Apple 的 CryptoKit ——
        // Core 要保持平台中立（同一个 Core 将来要给 Doyah Notes 的 Windows / 安卓 / 鸿蒙版复用）。
        // 它本来就在依赖树里（NIO SSL 用），这里只是**显式声明**，不新增依赖树。
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0")
    ],
    targets: [
        .target(
            name: "DoyahCore",
            dependencies: [
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "MySQLNIO", package: "mysql-nio"),
                .product(name: "Crypto", package: "swift-crypto")
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
        // 许可签发工具（**发行方侧**，不进 .app 包）：keygen / issue / verify / inspect。
        // 为什么单列一个可执行目标：签发要用**私钥**，而私钥不该出现在任何会被分发的东西里 ——
        // 工具与 App 共用 Core 的 `License` 模型与签名实现，但**打包脚本只打 App**。
        .executableTarget(
            name: "doyah-license-tool",
            dependencies: ["DoyahCore"],
            path: "Tools/LicenseTool"
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
        // 界面快照（队列 L-01）：用 `ImageRenderer` **离屏渲染真视图树**成 PNG。
        //
        // 为什么单列一个 test target 并依赖 `DoyahStudioApp`：要取证的是**真界面**，
        // 而不是 `Scripts/design-mock.swift` 那种照着重画的样张；SwiftPM 允许测试目标依赖可执行目标，
        // 于是不用把 App 拆成库、也不用给生产代码开后门。
        // 用例**默认跳过**（`DOYAH_UI_SNAPSHOT=1` 才跑）—— 快照是取证工具，不是回归门禁。
        .testTarget(
            name: "DoyahUISnapshotTests",
            dependencies: ["DoyahStudioApp", "DoyahCore", "DoyahPlatform"],
            path: "TestsUISnapshot"
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
