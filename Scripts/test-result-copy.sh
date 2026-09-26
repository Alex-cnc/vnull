#!/bin/bash
# 验证：复制为多格式（FR-RES-12）。
#
# 剪贴板本身没法脚本化，但**渲染层可以**：这里用 CLI 的 insert 导出（与复制共用同一套渲染）
# 把一段含"坑"的数据渲染成 INSERT，再**真的执行回库**并逐值核对 ——
# 复制粘贴最怕的就是"看着一样、贴进去变了"。格式细节由 13 项单测钉住。
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"
# 连接信息（本机过渡集群 / 远程专用库）由共用入口决定 —— 三档端口与目录只写在它里面
source "$(cd "$(dirname "$0")" && pwd)/lib/test-env.sh"
doyah_test_env_summary

PGBIN="${DOYAH_TEST_PG_BIN}"
DATADIR="${DOYAH_TEST_LOCAL_DATADIR}"
PORT="${DOYAH_TEST_PGPORT}"
DB="doyah_clipboard_check"
STARTED=0

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }
cleanup() {
    rm -f /tmp/doyah-clip-*.sql /tmp/doyah-clip-*.txt
    [ "$STARTED" = "1" ] && "$PGBIN/pg_ctl" -D "$DATADIR" stop >/dev/null 2>&1
}
trap cleanup EXIT

echo "== 0) 起本机实例，造含坑的数据 =="
if [ ! -f "${DATADIR}/PG_VERSION" ]; then
    mkdir -p "$DATADIR"
    "$PGBIN/initdb" -D "$DATADIR" -U postgres --auth=trust -E UTF8 >/dev/null 2>&1
fi
if ! "$PGBIN/pg_ctl" -D "$DATADIR" status >/dev/null 2>&1; then
    "$PGBIN/pg_ctl" -D "$DATADIR" -o "-p ${PORT} -k /tmp" -l /tmp/doyah-clip-pg.log start >/dev/null 2>&1
    STARTED=1
    sleep 2
fi
doyah_test_env_export_connection
PGDATABASE="${DOYAH_TEST_ADMIN_DB}" "$CLI" -c "DROP DATABASE IF EXISTS ${DB};" >/dev/null 2>&1
PGDATABASE="${DOYAH_TEST_ADMIN_DB}" "$CLI" -c "CREATE DATABASE ${DB};" >/dev/null 2>&1
export PGDATABASE="$DB"
"$CLI" -c "CREATE TABLE src (id int primary key, note text, amount numeric(10,2));
INSERT INTO src VALUES
  (1, 'plain', 10.5),
  (2, 'has ''quote'' inside', 20),
  (3, 'has | pipe and ' || chr(9) || ' tab', 30),   -- 真制表符（普通字符串里的 \t 是字面量，不是制表符）
  (4, 'line1' || chr(10) || 'line2', 40),
  (5, NULL, NULL);" >/dev/null 2>&1
[ $? -eq 0 ] && echo "  ✅ src 表已就绪（含单引号 / 竖线 / 制表符 / 换行 / NULL）" || { echo "  ❌ 造现场失败"; exit 1; }

echo ""
echo "== 1) 渲染成 INSERT 并**真的执行回去** =="
# 与结果区「复制为 INSERT」共用同一套渲染（ResultExporter.insertStatements）。
# **必须带 --table**：否则生成的 INSERT 指向 `table_name` 这张不存在的表。
# （这是产品侧的守卫：本轮实测发现旧行为会产出"看着对、跑不通"的 SQL，现已改为提前报错。）
# 目标表写 **dst**：渲染的 INSERT 要与"执行到哪张表"一致 ——
# 写成 src 会插回源表、撞主键（本轮踩到：duplicate key on src_pkey）。
"$CLI" export --query "SELECT * FROM src ORDER BY id" --table dst --out /tmp/doyah-clip-insert.sql --format insert --fetch-size 100 >/dev/null 2>&1
[ $? -eq 0 ] && check "INSERT 文本已生成" 0 || check "生成 INSERT" 1

# 守卫本身也要验：不给 --table 时应当**报错**而不是产出坏 SQL
GUARD="$("$CLI" export --query "SELECT * FROM src" --out /tmp/doyah-clip-bad.sql --format insert 2>&1)"
GUARD_CODE=$?
[ "$GUARD_CODE" -ne 0 ] && check "不给 --table 时拒绝（退出码 ${GUARD_CODE}）" 0 || check "应当拒绝" 1
echo "$GUARD" | grep -q "需要 --table" && check "拒绝原因可读" 0 || check "拒绝原因" 1
[ ! -f /tmp/doyah-clip-bad.sql ] && check "没有产出坏 SQL 文件" 0 || check "不该产出文件" 1
head -2 /tmp/doyah-clip-insert.sql | sed 's/^/  /' | cut -c1-100

# 目标表（结构与 src 相同），把复制出来的语句执行进去
"$CLI" -c "CREATE TABLE dst (LIKE src INCLUDING ALL);" >/dev/null 2>&1
"$CLI" -c "$(cat /tmp/doyah-clip-insert.sql)" >/tmp/doyah-clip-apply.log 2>&1
[ $? -eq 0 ] && check "复制出来的 INSERT 能被 PostgreSQL 执行（语法与转义都对）" 0 \
    || { check "INSERT 可执行" 1; tail -3 /tmp/doyah-clip-apply.log; }

COUNT="$("$CLI" -c "SELECT count(*) AS n FROM dst;" 2>/dev/null | awk '/^[0-9]+$/{print $1}' | head -1)"
[ "${COUNT:-0}" = "5" ] && check "5 行都插进去了" 0 || check "应有 5 行，实际 ${COUNT:-?}" 1

echo ""
echo "== 2) 逐值核对（含引号 / 竖线 / 制表符 / 换行 / NULL）=="
for check_sql in \
  "SELECT count(*) AS n FROM dst WHERE id = 2 AND note = 'has ''quote'' inside';" \
  "SELECT count(*) AS n FROM dst WHERE id = 3 AND note = 'has | pipe and ' || chr(9) || ' tab';" \
  "SELECT count(*) AS n FROM dst WHERE id = 4 AND note = 'line1' || chr(10) || 'line2';" \
  "SELECT count(*) AS n FROM dst WHERE id = 5 AND note IS NULL AND amount IS NULL;" \
  "SELECT count(*) AS n FROM dst WHERE id = 1 AND amount = 10.5;"
do
    V="$("$CLI" -c "$check_sql" 2>/dev/null | awk '/^[0-9]+$/{print $1}' | head -1)"
    [ "${V:-x}" = "1" ] && check "值原样回来了（$(echo "$check_sql" | grep -o "id = [0-9]" | head -1)）" 0 \
        || check "值核对失败：${check_sql}" 1
done

echo ""
echo "== 3) 另外三种格式的渲染（与复制共用同一层）=="
for fmt in tsv markdown csv; do
    "$CLI" export --query "SELECT * FROM src ORDER BY id" --out "/tmp/doyah-clip-$fmt.txt" --format "$fmt" --fetch-size 100 >/dev/null 2>&1
    if [ -s "/tmp/doyah-clip-$fmt.txt" ]; then
        check "${fmt} 渲染非空" 0
    else
        check "${fmt} 渲染" 1
    fi
done
# TSV 的关键性质：值里的制表符 / 换行被替换掉，所以**行数固定为 表头 + 5**
TSV_LINES=$(wc -l < /tmp/doyah-clip-tsv.txt | tr -d ' ')
[ "${TSV_LINES:-0}" -eq 6 ] && check "TSV 行数固定（表头 + 5 行）—— 值里的换行没把行数撑破" 0 \
    || check "TSV 应为 6 行，实际 ${TSV_LINES:-?}" 1
# Markdown 的竖线必须被转义，否则表格多一列
grep -q '\\|' /tmp/doyah-clip-markdown.txt && check "Markdown 里的竖线被转义" 0 || check "Markdown 竖线转义" 1

echo ""
echo "== 4) 清理现场 =="
PGDATABASE="${DOYAH_TEST_ADMIN_DB}" "$CLI" -c "DROP DATABASE IF EXISTS ${DB};" >/dev/null 2>&1
echo "  ✅ 已删除临时库 ${DB}"

echo ""
if [ "$fail" -eq 0 ]; then
    echo "通过：复制出来的 INSERT 能真的执行回库、含坑的值逐项核对一致；其余格式的渲染也验了"
else
    echo "有失败项，见上"
fi
exit "$fail"
