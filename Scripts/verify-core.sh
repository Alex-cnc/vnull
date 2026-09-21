#!/bin/bash
set -euo pipefail

# 编译并测试 PostgresClientCore（包含 PostgresNIO 驱动）。
#
# 该脚本使用 SwiftPM CLI，不依赖 Xcode GUI；
# 适合在没有数据库服务器时，先验证驱动编译与单元测试。

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SWIFT="${DEVELOPER_DIR}/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
SCRATCH="${ROOT}/.build"
CACHE="${ROOT}/.build-cache"

export DEVELOPER_DIR
export CLANG_MODULE_CACHE_PATH="${SCRATCH}/clang-module-cache"
export SWIFT_MODULE_CACHE_PATH="${SCRATCH}/swift-module-cache"
mkdir -p "${SCRATCH}" "${CACHE}" "${CLANG_MODULE_CACHE_PATH}" "${SWIFT_MODULE_CACHE_PATH}"

cd "${ROOT}"

"${SWIFT}" package \
  --disable-sandbox \
  --package-path . \
  --cache-path "${CACHE}" \
  --scratch-path "${SCRATCH}" \
  --manifest-cache local \
  resolve

"${SWIFT}" test \
  --disable-sandbox \
  --package-path . \
  --cache-path "${CACHE}" \
  --scratch-path "${SCRATCH}" \
  --manifest-cache local \
  -Xswiftc -disable-sandbox
