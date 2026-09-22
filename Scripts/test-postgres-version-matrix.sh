#!/bin/bash
set -euo pipefail

# PostgreSQL 版本兼容性回归（T-14 / NFR-COMP-03）
#
# 对**任意** PostgreSQL 实例跑一遍客户端关键链路，并打印一行可直接粘贴到
# `Docs/兼容性矩阵.md` 的 Markdown 表格行。
#
# 覆盖：
#   1. 连接与版本（server_version / current_database / current_user）
#   2. 多语句拆分 + 中文 / NULL 往返
#   3. DML 影响行数（command tag，FR-EXEC-10）
#   4. 服务端取消（pg_sleep + pg_cancel_backend，FR-EXEC-08）
#   5. 对象树（服务器 → 数据库 → schema → 表 → 列，FR-META-01 / 09 / 10）
#
# 用法：
#   PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres PGPASSWORD=secret \
#     PGDATABASE=postgres PGSSLMODE=disable ./Scripts/test-postgres-version-matrix.sh
#
# 说明：
#   - 需要目标库有建表 / 建 schema 权限（用后自动清理）；
#   - 跨库用例需要 CREATEDB 权限，没有时加 `--skip-cross-db`；
#   - 端口默认 5432，SSL 默认 prefer（本地可显式 disable）。

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SWIFT="${DEVELOPER_DIR}/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
SCRATCH="${ROOT}/.build"
CACHE="${ROOT}/.build-cache"
CLI="${SCRATCH}/debug/PostgresClientCLI"

export DEVELOPER_DIR
export CLANG_MODULE_CACHE_PATH="${SCRATCH}/clang-module-cache"
export SWIFT_MODULE_CACHE_PATH="${SCRATCH}/swift-module-cache"
mkdir -p "${SCRATCH}" "${CACHE}" "${CLANG_MODULE_CACHE_PATH}" "${SWIFT_MODULE_CACHE_PATH}"

SKIP_CROSS_DB=0
if [ "${1:-}" = "--skip-cross-db" ]; then
  SKIP_CROSS_DB=1
fi

echo "==> 编译 CLI（增量）"
"${SWIFT}" build \
  --product PostgresClientCLI \
  --disable-sandbox \
  --package-path "${ROOT}" \
  --cache-path "${CACHE}" \
  --scratch-path "${SCRATCH}" \
  --manifest-cache local \
  -Xswiftc -disable-sandbox >/dev/null

run_cli() {
  "${CLI}" "$@"
}

run_cli_db() {
  local database="$1"
  shift
  PGDATABASE="${database}" "${CLI}" "$@"
}

PASS=0
FAIL=0

check() {
  local name="$1"
  local output="$2"
  local needle="$3"
  if grep -qF -- "${needle}" <<<"${output}"; then
    echo "  ✅ ${name}"
    PASS=$((PASS + 1))
  else
    echo "  ❌ ${name}（未找到：${needle}）"
    echo "${output}" | sed 's/^/     | /'
    FAIL=$((FAIL + 1))
  fi
}

# 任意一个 needle 命中即通过：用于服务端返回文案会被 lc_messages 本地化的断言
# （例如取消查询在中文实例上回的是「由于用户请求而正在取消查询」）。
check_any() {
  local name="$1"
  local output="$2"
  shift 2
  local needle
  for needle in "$@"; do
    if grep -qF -- "${needle}" <<<"${output}"; then
      echo "  ✅ ${name}"
      PASS=$((PASS + 1))
      return
    fi
  done
  echo "  ❌ ${name}（以下均未找到：$*）"
  echo "${output}" | sed 's/^/     | /'
  FAIL=$((FAIL + 1))
}

echo ""
echo "==> 用例 1：连接与版本"
set +e
OUTPUT="$(run_cli -c "SELECT version();" 2>&1)"
STATUS=$?
set -e
if [ "${STATUS}" -ne 0 ] || ! grep -qF "连接成功" <<<"${OUTPUT}"; then
  echo "  ❌ 无法连接目标数据库：${PGUSER:-postgres}@${PGHOST:-127.0.0.1}:${PGPORT:-5432}/${PGDATABASE:-<default>}"
  echo "${OUTPUT}" | sed 's/^/     | /'
  echo ""
  echo "请检查：实例是否可达 / 账号密码 / pg_hba.conf 是否放行客户端 IP / SSL 模式（PGSSLMODE=disable 可先排除 TLS 问题）。"
  exit 1
fi
check "连接成功" "${OUTPUT}" "连接成功"
# 版本号取自连接横幅（`server_version: 16.2`），避免误抓 IP 里的数字。
VERSION="$(sed -n 's/^server_version: *//p' <<<"${OUTPUT}" | head -1 | tr -d '[:space:]')"
check "返回 server_version" "${OUTPUT}" "PostgreSQL"

echo ""
echo "==> 用例 2：多语句 + 中文 / NULL"
OUTPUT="$(run_cli -c "DROP TABLE IF EXISTS compat_check;
CREATE TABLE compat_check(id int, name text);
INSERT INTO compat_check VALUES (1, '中文'), (2, NULL);
SELECT * FROM compat_check ORDER BY id;")" || true
check "4 条语句全部执行" "${OUTPUT}" "finished: 4 statement(s)"
check "中文往返正确" "${OUTPUT}" "1 | 中文"
check "NULL 显示为 NULL" "${OUTPUT}" "2 | NULL"

echo ""
echo "==> 用例 3：DML 影响行数"
OUTPUT="$(run_cli -c "INSERT INTO compat_check VALUES (10), (11), (12);
UPDATE compat_check SET name = 'x' WHERE id >= 10;
DELETE FROM compat_check WHERE id = 12;")" || true
check "INSERT 影响 3 行" "${OUTPUT}" "affectedRows: 3"
check "UPDATE 影响 3 行" "${OUTPUT}" "affectedRows: 3"
check "DELETE 影响 1 行" "${OUTPUT}" "affectedRows: 1"

echo ""
echo "==> 用例 4：服务端取消"
set +e
OUTPUT="$(run_cli --cancel-after 1 -c "SELECT pg_sleep(30);" 2>&1)"
STATUS=$?
set -e
if [ "${STATUS}" -eq 2 ]; then
  echo "  ✅ 取消后以退出码 2 返回"
  PASS=$((PASS + 1))
else
  echo "  ❌ 退出码为 ${STATUS}，期望 2"
  FAIL=$((FAIL + 1))
fi
check_any "取消由服务端执行" "${OUTPUT}" "canceling statement due to user request" "由于用户请求而正在取消查询" "57014"

echo ""
echo "==> 用例 5：对象树"
OUTPUT="$(run_cli --tree --columns)" || true
check "根节点是服务器" "${OUTPUT}" "server"
check "列出数据库" "${OUTPUT}" "database"
check "列出 schema" "${OUTPUT}" "schema"
check "列出表" "${OUTPUT}" "table compat_check"
check "列出列与类型" "${OUTPUT}" "column name"

if [ "${SKIP_CROSS_DB}" -eq 0 ]; then
  run_cli -c "DROP DATABASE IF EXISTS ic_compat_second;" >/dev/null 2>&1 || true
  if run_cli -c "CREATE DATABASE ic_compat_second;" >/dev/null 2>&1; then
    run_cli_db ic_compat_second -c "CREATE TABLE IF NOT EXISTS compat_second(id int);" >/dev/null 2>&1 || true
    OUTPUT="$(run_cli --tree)" || true
    check "跨数据库浏览" "${OUTPUT}" "database ic_compat_second"
    run_cli -c "DROP DATABASE IF EXISTS ic_compat_second;" >/dev/null 2>&1 || true
  else
    echo "  ⚠️  无 CREATEDB 权限，跳过跨库用例（可加 --skip-cross-db 显式跳过）"
  fi
else
  echo "  ⚠️  已按参数跳过跨库用例"
fi

run_cli -c "DROP TABLE IF EXISTS compat_check;" >/dev/null 2>&1 || true

TOTAL=$((PASS + FAIL))
if [ "${FAIL}" -eq 0 ]; then
  RESULT="✅ 通过（${PASS}/${TOTAL}）"
else
  RESULT="❌ 失败 ${FAIL}/${TOTAL}"
fi

echo ""
echo "================================"
echo "通过 ${PASS} 项，失败 ${FAIL} 项"
echo "================================"
echo ""
echo "粘贴到 Docs/兼容性矩阵.md 的行："
echo ""
echo "| ${VERSION:-?} | $(uname -m) | $(date +%Y-%m-%d) | ${PASS}/${TOTAL} | ${RESULT} | \`Scripts/test-postgres-version-matrix.sh\` |"
echo ""

[ "${FAIL}" -eq 0 ]
