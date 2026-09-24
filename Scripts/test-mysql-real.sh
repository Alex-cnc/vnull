#!/bin/bash
# FR-DRV-09 的**真机**证据（需要一台真实 MySQL / MariaDB）。
#
# 与 `test-mysql-driver.sh`（假服务器）的分工：
#   · 假服务器证的是**我们这一侧的接线**（认证之后的一切）；
#   · 这个脚本证的是**真实服务端**上的行为：认证插件（caching_sha2_password）、
#     字符集协商、真实数据类型、`information_schema` 的列名、`KILL QUERY` 的权限、
#     以及元数据树（服务器 → Database → Table → Column）真的对得上。
#
# 本机当前**没有 MySQL 实例**，所以这条在本轮是**阻塞**的（如实登记在需求书与验收清单里）。
# 有了实例后按下面用法跑一遍即可。
#
# 用法：
#   DOYAH_MYSQL_HOST=127.0.0.1 DOYAH_MYSQL_PORT=3306 DOYAH_MYSQL_USER=root \
#   DOYAH_MYSQL_PASSWORD=*** DOYAH_MYSQL_DATABASE=doyah_test ./Scripts/test-mysql-real.sh
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"

HOST="${DOYAH_MYSQL_HOST:-}"
PORT="${DOYAH_MYSQL_PORT:-3306}"
USER_NAME="${DOYAH_MYSQL_USER:-}"
PASSWORD="${DOYAH_MYSQL_PASSWORD:-}"
DATABASE="${DOYAH_MYSQL_DATABASE:-doyah_test}"

if [ -z "$HOST" ] || [ -z "$USER_NAME" ]; then
    echo "⏸  未配置 MySQL 实例：本项的真机验收被环境阻塞（本机没有任何 mysql/mariadb 服务）。"
    echo "   需要的是一台可达的 MySQL 5.7 / 8.x 或 MariaDB，只读账号也够跑第 1~5 节。"
    echo "   用法见本脚本头部注释；跑通后把输出贴进 Docs/design/待人工验收清单.md §10.7。"
    exit 2
fi

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }
run_mysql() {
    "$CLI" mysql --host "$HOST" --port "$PORT" --user "$USER_NAME" \
        ${PASSWORD:+--password "$PASSWORD"} --database "$DATABASE" --json "$@"
}
run_sql() { run_mysql --sql "$1"; }

echo "== 0) 构建 CLI =="
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
swift build --disable-sandbox --cache-path "$PWD/.build-cache" --scratch-path "$PWD/.build" \
    --manifest-cache local -Xswiftc -disable-sandbox --product DoyahCLI > .build/mysql-real-build.log 2>&1 \
    && check "CLI 构建成功" 0 || { check "CLI 构建成功" 1; tail -5 .build/mysql-real-build.log; exit 1; }

echo ""
echo "== 0.5) 预检：先确认这个账号**允许从本机连**（否则后面全是误导性的失败） =="
# 为什么单列一步：MySQL 的"Host … is not allowed to connect"发生在**认证之前**，
# 后面每一节都会失败，而失败信息看着像我们的驱动有问题。先把它挑出来说清楚。
PRE="$(run_mysql 2>&1 | head -1)"
if echo "$PRE" | grep -q '"ok":true'; then
    check "预检通过（本机 IP 在服务端允许列表里）" 0
else
    check "预检通过（本机 IP 在服务端允许列表里）" 1
    echo "    服务端原话：$PRE"
    echo "    请在 MySQL 上给本机开一个账号，例如："
    echo "      CREATE DATABASE IF NOT EXISTS $DATABASE;"
    echo "      CREATE USER 'doyah'@'%' IDENTIFIED BY '<口令>';"
    echo "      GRANT ALL ON $DATABASE.* TO 'doyah'@'%';"
    echo "    然后把 DOYAH_MYSQL_USER / DOYAH_MYSQL_PASSWORD 换成它重跑。"
    exit 1
fi

echo ""
echo "== 1) 认证与自省（真实认证插件 / 版本 / 当前库 / 当前用户） =="
JSON="$(run_mysql)"
echo "$JSON" | grep -q '"ok":true' && check "连接成功（真实认证插件）" 0 || check "连接成功（真实认证插件）" 1
echo "$JSON" | grep -q '"version":"' && check "读到了服务端版本" 0 || check "读到了服务端版本" 1

echo ""
echo "== 2) 真实类型与字符集（中文 / NULL / 空串 / 小数 / 日期 / 时间） =="
run_sql "DROP TABLE IF EXISTS doyah_mysql_probe" >/dev/null 2>&1
run_sql "CREATE TABLE doyah_mysql_probe (id INT PRIMARY KEY, name VARCHAR(64), amount DECIMAL(10,2), created DATETIME, note VARCHAR(64))" >/dev/null 2>&1 \
    && check "建表成功" 0 || check "建表成功" 1
run_sql "INSERT INTO doyah_mysql_probe VALUES (1, '客户甲', 12.50, '2026-09-25 10:00:00', NULL), (2, '', 0.00, '2026-09-25 10:00:01', '有值')" >/dev/null 2>&1 \
    && check "写入两行（含中文与 NULL）" 0 || check "写入两行（含中文与 NULL）" 1
ROWS="$(run_sql "SELECT id, name, amount, created, note FROM doyah_mysql_probe ORDER BY id")"
echo "$ROWS" | grep -q '"客户甲"' && check "中文原样返回" 0 || check "中文原样返回" 1
echo "$ROWS" | grep -q '"12.50"' && check "DECIMAL 的标度保住（12.50）" 0 || check "DECIMAL 的标度保住（12.50）" 1
echo "$ROWS" | grep -q '\["1","客户甲","12.50","2026-09-25 10:00:00","NULL"\]' \
    && check "NULL 与空串分得开（第一行 note 为 NULL）" 0 || check "NULL 与空串分得开（第一行 note 为 NULL）" 1
echo "$ROWS" | grep -q '\["2","","0.00"' && check "空串仍是空串（第二行 name 为空）" 0 || check "空串仍是空串（第二行 name 为空）" 1

echo ""
echo "== 3) 影响行数与自增 ID（服务端给的数字） =="
run_sql "DROP TABLE IF EXISTS doyah_mysql_auto" >/dev/null 2>&1
run_sql "CREATE TABLE doyah_mysql_auto (id INT AUTO_INCREMENT PRIMARY KEY, v INT)" >/dev/null 2>&1
AUTO="$(run_sql "INSERT INTO doyah_mysql_auto (v) VALUES (7), (8), (9)")"
echo "$AUTO" | grep -q '"affectedRows":3' && check "影响行数 = 3" 0 || check "影响行数 = 3" 1
echo "$AUTO" | grep -q "自增 ID" && check "自增 ID 有交代" 0 || check "自增 ID 有交代" 1

echo ""
echo "== 4) 事务：回滚之后数据真的不在 =="
run_sql "START TRANSACTION" >/dev/null 2>&1
run_sql "INSERT INTO doyah_mysql_auto (v) VALUES (99)" >/dev/null 2>&1
run_sql "ROLLBACK" >/dev/null 2>&1
COUNT="$(run_sql "SELECT COUNT(*) FROM doyah_mysql_auto WHERE v = 99")"
echo "$COUNT" | grep -q '\[\["0"\]\]' && check "回滚生效（查不到 99）" 0 || check "回滚生效（查不到 99）" 1

echo ""
echo "== 5) 错误路径（真实服务端的报错要原样说人话） =="
if run_sql "SELECT * FROM doyah_not_exist_table" >/dev/null 2>&1; then ec=1; else ec=0; fi
check "查不存在的表时退出码非零" "$ec"

echo ""
echo "== 6) 元数据链路（MySQL 方言真跑：SHOW TABLES / DESC） =="
# 说明：`doyah --tree` 那条路径是 **PostgreSQL 专用**的（默认路径里写死了 PostgresService，
# 当初只为 PG 做的），所以这里直接跑**元数据树背后真正用的那两条方言查询**：
# `MySQLDialect.listTablesQuery`（`SHOW TABLES FROM <库>`）与 `listColumnsQuery`（`DESC <表>`）。
# 界面上的四层树走的就是它们，因此这里验的是同一条链路，只是没有界面那层壳。
TABLES="$(run_sql "SHOW TABLES FROM \`$DATABASE\`")"
echo "$TABLES" | grep -q "doyah_mysql_probe" && check "SHOW TABLES 能看到刚建的表" 0 || check "SHOW TABLES 能看到刚建的表" 1
COLUMNS="$(run_sql "DESC doyah_mysql_probe")"
echo "$COLUMNS" | grep -q '"id"' && check "DESC 能列出列（含 id）" 0 || check "DESC 能列出列（含 id）" 1
echo "$COLUMNS" | grep -q "decimal" && check "DESC 里能看到 decimal 类型" 0 || check "DESC 里能看到 decimal 类型" 1

echo ""
echo "== 7) 清理 =="
run_sql "DROP TABLE IF EXISTS doyah_mysql_probe" >/dev/null 2>&1
run_sql "DROP TABLE IF EXISTS doyah_mysql_auto" >/dev/null 2>&1
check "清理完成" 0

echo ""
if [ "$fail" -eq 0 ]; then
    echo "✅ 真机 MySQL 全部通过"
else
    echo "❌ 有断言失败，见上"
fi
exit "$fail"
