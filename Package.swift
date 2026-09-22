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
        .executableTarget(
            name: "DoyahCLI",
            dependencies: ["DoyahCore"],
            path: "CLI"
        ),
        // 让 SwiftPM 也能编译 App 源码（Xcode 工程之外的第二条验证路径）。
        // 打包成 .app 由 Scripts/build-app.sh 负责。
        .executableTarget(
            name: "DoyahStudioApp",
            dependencies: ["DoyahCore"],
            path: "App",
            exclude: ["DoyahStudio.entitlements"]
        ),
        .testTarget(
            name: "DoyahCoreTests",
            dependencies: ["DoyahCore"],
            path: "Tests"
        )
    ]
)
