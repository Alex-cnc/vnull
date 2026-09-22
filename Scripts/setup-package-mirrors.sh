#!/bin/bash
set -euo pipefail

# 为 SwiftPM / Xcode 配置 PostgresNIO 依赖镜像。
#
# 背景：
# - GitHub 直连在国内网络下经常缓慢或失败；
# - 工程依赖 PostgresNIO 1.33.1 及其 12 个传递依赖；
# - 本脚本把 Swift 包依赖映射到 gitclone.com 代理。
#
# 如果以后网络恢复，可以删除：
#   ~/.swiftpm/configuration/mirrors.json
#
# 注意：这是一个可选的国内网络加速脚本，不是工程运行必需。

CONFIG_DIR="${HOME}/.swiftpm/configuration"
CONFIG_FILE="${CONFIG_DIR}/mirrors.json"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

# PostgresNIO 本身已经打包在工程 Vendor 目录；否则回退到本机 clone 或 GitHub 直连
if [ -d "${PROJECT_ROOT}/Vendor/postgres-nio/.git" ]; then
  POSTGRES_MIRROR="file://${PROJECT_ROOT}/Vendor/postgres-nio"
elif [ -d "${HOME}/.dsh/tools/postgres-nio-1.33.1/.git" ]; then
  POSTGRES_MIRROR="file://${HOME}/.dsh/tools/postgres-nio-1.33.1"
else
  POSTGRES_MIRROR="https://github.com/vapor/postgres-nio.git"
fi

mkdir -p "${CONFIG_DIR}"

cat > "${CONFIG_FILE}" <<JSON
{
  "version": 1,
  "object": [
    {
      "original": "https://github.com/vapor/postgres-nio.git",
      "mirror": "${POSTGRES_MIRROR}"
    },
    {
      "original": "https://github.com/apple/swift-atomics.git",
      "mirror": "https://gitclone.com/github.com/apple/swift-atomics.git"
    },
    {
      "original": "https://github.com/apple/swift-collections.git",
      "mirror": "https://gitclone.com/github.com/apple/swift-collections.git"
    },
    {
      "original": "https://github.com/apple/swift-nio.git",
      "mirror": "https://gitclone.com/github.com/apple/swift-nio.git"
    },
    {
      "original": "https://github.com/apple/swift-nio-transport-services.git",
      "mirror": "https://gitclone.com/github.com/apple/swift-nio-transport-services.git"
    },
    {
      "original": "https://github.com/apple/swift-nio-ssl.git",
      "mirror": "https://gitclone.com/github.com/apple/swift-nio-ssl.git"
    },
    {
      "original": "https://github.com/apple/swift-crypto.git",
      "mirror": "https://gitclone.com/github.com/apple/swift-crypto.git"
    },
    {
      "original": "https://github.com/apple/swift-log.git",
      "mirror": "https://gitclone.com/github.com/apple/swift-log.git"
    },
    {
      "original": "https://github.com/apple/swift-metrics.git",
      "mirror": "https://gitclone.com/github.com/apple/swift-metrics.git"
    },
    {
      "original": "https://github.com/swift-server/swift-service-lifecycle.git",
      "mirror": "https://gitclone.com/github.com/swift-server/swift-service-lifecycle.git"
    },
    {
      "original": "https://github.com/apple/swift-asn1.git",
      "mirror": "https://gitclone.com/github.com/apple/swift-asn1.git"
    },
    {
      "original": "https://github.com/apple/swift-async-algorithms.git",
      "mirror": "https://gitclone.com/github.com/apple/swift-async-algorithms.git"
    },
    {
      "original": "https://github.com/apple/swift-system.git",
      "mirror": "https://gitclone.com/github.com/apple/swift-system.git"
    }
  ]
}
JSON

echo "镜像配置已写入：${CONFIG_FILE}"
echo "在 Xcode 中执行：File → Packages → Reset Package Caches，然后重新 Resolve。"
