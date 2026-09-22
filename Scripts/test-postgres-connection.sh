#!/bin/bash
set -euo pipefail

# 连接真实 PostgreSQL 的 CLI 测试。
#
# 推荐使用环境变量，避免密码进入 shell 历史：
#
#   PGHOST=192.0.2.10 \
#   PGPORT=5432 \
#   PGUSER=postgres \
#   PGPASSWORD='your-password' \
#   PGDATABASE=postgres \
#   PGSSLMODE=disable \
#   ./Scripts/test-postgres-connection.sh
#
# PGSSLMODE 可选值：
#   disable / allow / prefer / require / verify-ca / verify-full

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SWIFT="${DEVELOPER_DIR}/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
SCRATCH="${ROOT}/.build"
CACHE="${ROOT}/.build-cache"

export DEVELOPER_DIR
export CLANG_MODULE_CACHE_PATH="${SCRATCH}/clang-module-cache"
export SWIFT_MODULE_CACHE_PATH="${SCRATCH}/swift-module-cache"
mkdir -p "${SCRATCH}" "${CACHE}" "${CLANG_MODULE_CACHE_PATH}" "${SWIFT_MODULE_CACHE_PATH}"

PGHOST="${PGHOST:-127.0.0.1}"
PGPORT="${PGPORT:-5432}"
export PGHOST PGPORT

# 先做 TCP 可达性检查，区分“网络不通”和“认证/协议问题”
python3 - <<'PY'
import os
import socket
import sys

host = os.environ.get("PGHOST", "127.0.0.1")
port = int(os.environ.get("PGPORT", "5432"))

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.settimeout(5)
try:
    sock.connect((host, port))
except Exception as error:
    print(f"TCP 不可达：{host}:{port}")
    print(f"错误：{error!r}")
    print("")
    print("请检查：")
    print("1. 两台机器是否在同一局域网")
    print("2. 数据库服务器 postgresql.conf 是否设置 listen_addresses = '*'")
    print("3. 防火墙是否放行 5432 端口")
    print("4. 主机地址是不是写成了 localhost（跨机器不能用 localhost）")
    sys.exit(1)
finally:
    sock.close()

print(f"TCP 可达：{host}:{port}")
print("")
PY

exec "${SWIFT}" run \
  --disable-sandbox \
  --package-path "${ROOT}" \
  --cache-path "${CACHE}" \
  --scratch-path "${SCRATCH}" \
  --manifest-cache local \
  -Xswiftc -disable-sandbox \
  DoyahCLI "$@"
