// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PostgresClientCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "PostgresClientCore",
            targets: ["PostgresClientCore"]
        )
    ],
    dependencies: [
        .package(path: "Vendor/postgres-nio")
    ],
    targets: [
        .target(
            name: "PostgresClientCore",
            dependencies: [
                .product(name: "PostgresNIO", package: "postgres-nio")
            ],
            path: "Core"
        ),
        .executableTarget(
            name: "PostgresClientCLI",
            dependencies: ["PostgresClientCore"],
            path: "CLI"
        ),
        // 让 SwiftPM 也能编译 App 源码（Xcode 工程之外的第二条验证路径）。
        // 打包成 .app 由 Scripts/build-app.sh 负责。
        .executableTarget(
            name: "PostgresClientApp",
            dependencies: ["PostgresClientCore"],
            path: "App",
            exclude: ["PostgresClient.entitlements"]
        ),
        .testTarget(
            name: "PostgresClientCoreTests",
            dependencies: ["PostgresClientCore"],
            path: "Tests"
        )
    ]
)
