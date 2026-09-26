#!/bin/bash
set -euo pipefail

# 用内置的 PostgreSQL（pgserver，无需 Homebrew / Docker）验证完整查询链路：
#
#   CLI -> StatementSplitter -> PostgresService -> PostgresNIO -> 本地 PostgreSQL
#
# 覆盖：多语句、字符串内分号、NULL、美元引号函数、SQL 错误码返回。
#
# 前置条件（一次性）：
#   pip3 install --target <pgserver 安装目录> <pgserver wheel>
#
# 可用环境变量：
#   PGSERVER_PREFIX   pginstall 目录，默认由 Scripts/lib/test-env.sh 给出
#   PGSERVER_DATADIR  测试数据目录，默认由 Scripts/lib/test-env.sh 的 querytest 档给出
#   TEST_PGPORT       测试端口，默认由 Scripts/lib/test-env.sh 的 querytest 档给出

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
# 本脚本用 querytest 档集群（端口 / 数据目录与默认档不同，见 test-env.sh 的档位表）
DOYAH_TEST_LOCAL_PROFILE=querytest
# 连接信息（本机过渡集群 / 远程专用库）由共用入口决定 —— 三档端口与目录只写在它里面
source "$(cd "$(dirname "$0")" && pwd)/lib/test-env.sh"
doyah_test_env_summary

# `PGSERVER_PREFIX`（pginstall 目录）仍是可覆盖的开关：给了就用它下面的 bin/，否则用 lib 给的。
# 两个口径差一层目录（lib 给的是 `…/pginstall/bin`）—— 原先这里就是 `dirname` 的关系。
PGBIN="${DOYAH_TEST_PG_BIN}"
if [ -n "${PGSERVER_PREFIX:-}" ]; then
    PGBIN="${PGSERVER_PREFIX}/bin"
fi
TEST_PGPORT="${DOYAH_TEST_PGPORT}"
DATADIR="${DOYAH_TEST_LOCAL_DATADIR}"

if [ ! -x "${PGBIN}/initdb" ]; then
  echo "未找到内置 PostgreSQL：${PGBIN}/initdb"
  echo "请先安装 pgserver，或用 PGSERVER_PREFIX 指向 pginstall 目录。"
  exit 1
fi

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SWIFT="${DEVELOPER_DIR}/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
SCRATCH="${ROOT}/.build"
CACHE="${ROOT}/.build-cache"

export DEVELOPER_DIR
export CLANG_MODULE_CACHE_PATH="${SCRATCH}/clang-module-cache"
export SWIFT_MODULE_CACHE_PATH="${SCRATCH}/swift-module-cache"
mkdir -p "${SCRATCH}" "${CACHE}" "${CLANG_MODULE_CACHE_PATH}" "${SWIFT_MODULE_CACHE_PATH}"

CLI="${SCRATCH}/debug/DoyahCLI"
# 每次增量编译，确保 CLI 用的是最新 Core 代码（SwiftPM 增量构建很快）。
echo "==> 编译 CLI（增量）"
"${SWIFT}" build \
  --product DoyahCLI \
  --disable-sandbox \
  --package-path "${ROOT}" \
  --cache-path "${CACHE}" \
  --scratch-path "${SCRATCH}" \
  --manifest-cache local \
  -Xswiftc -disable-sandbox

if [ ! -f "${DATADIR}/PG_VERSION" ]; then
  echo "==> 初始化本地测试数据库：${DATADIR}"
  "${PGBIN}/initdb" -D "${DATADIR}" -U postgres --auth=trust -E UTF8 >/dev/null
fi

STARTED=0
if "${PGBIN}/pg_ctl" -D "${DATADIR}" status >/dev/null 2>&1; then
  echo "==> 本地测试服务器已在运行"
else
  echo "==> 启动本地测试服务器 (127.0.0.1:${TEST_PGPORT})"
  "${PGBIN}/pg_ctl" -D "${DATADIR}" \
    -o "-p ${TEST_PGPORT} -c listen_addresses=127.0.0.1" \
    -l "${DATADIR}/server.log" start >/dev/null
  STARTED=1
fi

cleanup() {
  if [ "${STARTED}" = "1" ]; then
    "${PGBIN}/pg_ctl" -D "${DATADIR}" stop -m fast >/dev/null
  fi
}
trap cleanup EXIT

run_cli() {
  PGHOST="${DOYAH_TEST_PGHOST}" \
  PGPORT="${DOYAH_TEST_PGPORT}" \
  PGUSER="${DOYAH_TEST_PGUSER}" \
  PGPASSWORD="${DOYAH_TEST_PGPASSWORD}" \
  PGDATABASE="${DOYAH_TEST_ADMIN_DB}" \
  PGSSLMODE=disable \
  "${CLI}" "$@"
}

run_cli_db() {
  local database="$1"
  shift
  PGHOST="${DOYAH_TEST_PGHOST}" \
  PGPORT="${DOYAH_TEST_PGPORT}" \
  PGUSER="${DOYAH_TEST_PGUSER}" \
  PGPASSWORD="${DOYAH_TEST_PGPASSWORD}" \
  PGDATABASE="${database}" \
  PGSSLMODE=disable \
  "${CLI}" "$@"
}

PASS=0
FAIL=0

assert_contains() {
  local name="$1"
  local output="$2"
  local needle="$3"
  if grep -qF -- "${needle}" <<<"${output}"; then
    echo "  ✅ ${name}"
    PASS=$((PASS + 1))
  else
    echo "  ❌ ${name}（未找到：${needle}）"
    echo "----- 实际输出 -----"
    echo "${output}"
    echo "--------------------"
    FAIL=$((FAIL + 1))
  fi
}

echo ""
echo "==> 用例 1：字符串内分号不拆句 + NULL 显示"
OUTPUT="$(run_cli -c "SELECT 1 AS one, NULL::text AS empty, 'a;b' AS semi;")"
assert_contains "分号留在字符串里" "${OUTPUT}" "1 | NULL | a;b"
assert_contains "finished 1 statement" "${OUTPUT}" "finished: 1 statement(s)"

echo ""
echo "==> 用例 2：多语句（CREATE / INSERT / SELECT）"
OUTPUT="$(run_cli -c "DROP TABLE IF EXISTS cli_test;
CREATE TABLE cli_test(id int, name text);
INSERT INTO cli_test VALUES (1, '甲'), (2, NULL);
SELECT * FROM cli_test ORDER BY id;")"
assert_contains "4 条语句全部执行" "${OUTPUT}" "finished: 4 statement(s)"
assert_contains "第 4 条语句返回数据" "${OUTPUT}" "1 | 甲"
assert_contains "NULL 显示为 NULL" "${OUTPUT}" "2 | NULL"

echo ""
echo "==> 用例 3：美元引号函数体"
OUTPUT="$(run_cli -c "CREATE OR REPLACE FUNCTION cli_add(a int, b int) RETURNS int LANGUAGE sql AS \$\$ SELECT a + b; \$\$;
SELECT cli_add(20, 22) AS sum;")"
assert_contains "函数体中的分号没有被拆句" "${OUTPUT}" "finished: 2 statement(s)"
assert_contains "函数返回 42" "${OUTPUT}" "42"

echo ""
echo "==> 用例 4：对象树（MetadataService）"
# 造一个空 schema，验证「schema 下没有表」不会中断对象树枚举
run_cli -c "CREATE SCHEMA IF NOT EXISTS ic_empty_schema;" >/dev/null

OUTPUT="$(run_cli --tree)"
# 端口必须用同一个变量：写死端口时，一旦换端口就会**假失败**
assert_contains "根节点是服务器" "${OUTPUT}" "server postgres@127.0.0.1:${TEST_PGPORT}"
assert_contains "服务器下列出数据库" "${OUTPUT}" "database postgres"
assert_contains "列出 schema" "${OUTPUT}" "schema public"
assert_contains "空 schema 也能枚举" "${OUTPUT}" "schema ic_empty_schema"
assert_contains "列出表" "${OUTPUT}" "table cli_test"

OUTPUT="$(run_cli --tree --columns)"
assert_contains "列出列名" "${OUTPUT}" "column id"
assert_contains "列出列类型" "${OUTPUT}" "column name: text"

echo ""
echo "==> 用例 5：跨数据库浏览（服务器 → 多数据库 → 按需连接）"
run_cli -c "DROP DATABASE IF EXISTS ic_second;" >/dev/null
run_cli -c "CREATE DATABASE ic_second;" >/dev/null
run_cli_db ic_second -c "CREATE TABLE IF NOT EXISTS second_table(id int, name text);" >/dev/null

OUTPUT="$(run_cli --tree)"
assert_contains "服务器下列出第二个数据库" "${OUTPUT}" "database ic_second"
assert_contains "按需连接并列出该库的表" "${OUTPUT}" "table second_table"

echo ""
echo "==> 用例 6：DML 影响行数（FR-EXEC-10）"
run_cli -c "DROP TABLE IF EXISTS cli_rows; CREATE TABLE cli_rows(id int);" >/dev/null
OUTPUT="$(run_cli -c "INSERT INTO cli_rows VALUES (1), (2), (3);
UPDATE cli_rows SET id = id + 10 WHERE id <= 2;
DELETE FROM cli_rows WHERE id = 12;")"
assert_contains "INSERT 影响 3 行" "${OUTPUT}" "affectedRows: 3"
assert_contains "UPDATE 影响 2 行" "${OUTPUT}" "affectedRows: 2"
assert_contains "DELETE 影响 1 行" "${OUTPUT}" "affectedRows: 1"
assert_contains "DML 语句没有结果集" "${OUTPUT}" "(no result set)"

echo ""
echo "==> 用例 7：服务端取消（FR-EXEC-08）"
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
assert_contains "取消由服务端执行" "${OUTPUT}" "cancel: 触发服务端取消"
assert_contains "错误信息说明语句被取消" "${OUTPUT}" "canceling statement due to user request"

echo ""
echo "==> 用例 8：建库权限探测与建库（FR-META-11）"
OUTPUT="$(run_cli --can-create-database)"
assert_contains "探测到当前用户可建库" "${OUTPUT}" "canCreateDatabase: true"
run_cli -c "DROP DATABASE IF EXISTS ic_priv_test;" >/dev/null 2>&1 || true
OUTPUT="$(run_cli -c "CREATE DATABASE ic_priv_test;")"
assert_contains "CREATE DATABASE 执行成功" "${OUTPUT}" "finished: 1 statement(s)"
OUTPUT="$(run_cli --tree)"
assert_contains "新库出现在服务器节点下" "${OUTPUT}" "database ic_priv_test"
run_cli -c "DROP DATABASE ic_priv_test;" >/dev/null 2>&1 || true

echo ""
echo "==> 用例 9：SQL 错误应以退出码 2 返回"
set +e
OUTPUT="$(run_cli -c "SELECT * FROM no_such_table_xyz;" 2>&1)"
STATUS=$?
set -e
if [ "${STATUS}" -eq 2 ]; then
  echo "  ✅ 退出码 2"
  PASS=$((PASS + 1))
else
  echo "  ❌ 退出码为 ${STATUS}，期望 2"
  FAIL=$((FAIL + 1))
fi
assert_contains "错误信息包含表名" "${OUTPUT}" "no_such_table_xyz"

echo ""
echo "================================"
echo "通过 ${PASS} 项，失败 ${FAIL} 项"
echo "================================"

if [ "${FAIL}" -gt 0 ]; then
  exit 1
fi
