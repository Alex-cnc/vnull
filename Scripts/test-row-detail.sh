#!/bin/bash
# 验证：单行竖排详情与 JSON 格式化（FR-DATA-05）。
#
# 界面侧栏没法脚本化，但**"值检查"这层可以**：往真表里塞进长 JSON / 二进制 / NULL /
# 空串 / 多字节字符，然后用 CLI 的竖排输出逐项核对形态与摘要。
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"
PGBIN="$HOME/tools/pgserver/pgserver/pginstall/bin"
DATADIR="$PWD/.build/pgdata-session-test"
PORT=55433
DB="doyah_row_check"
STARTED=0

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }
cleanup() { [ "$STARTED" = "1" ] && "$PGBIN/pg_ctl" -D "$DATADIR" stop >/dev/null 2>&1; }
trap cleanup EXIT

echo "== 0) 起本机实例并造一行每个坑都有的数据 =="
if [ ! -f "${DATADIR}/PG_VERSION" ]; then
    mkdir -p "$DATADIR"
    "$PGBIN/initdb" -D "$DATADIR" -U postgres --auth=trust -E UTF8 >/dev/null 2>&1
fi
if ! "$PGBIN/pg_ctl" -D "$DATADIR" status >/dev/null 2>&1; then
    "$PGBIN/pg_ctl" -D "$DATADIR" -o "-p ${PORT} -k /tmp" -l /tmp/doyah-row-pg.log start >/dev/null 2>&1
    STARTED=1
    sleep 2
fi
export PGHOST=127.0.0.1 PGPORT="$PORT" PGUSER=postgres PGPASSWORD=""
PGDATABASE=postgres "$CLI" -c "DROP DATABASE IF EXISTS ${DB};" >/dev/null 2>&1
PGDATABASE=postgres "$CLI" -c "CREATE DATABASE ${DB};" >/dev/null 2>&1
export PGDATABASE="$DB"
"$CLI" -c "CREATE TABLE payloads (
  id int primary key,
  doc jsonb,
  blob bytea,
  note text,
  empty_text text,
  multi text,
  hex_text text
);
INSERT INTO payloads VALUES (
  1,
  '{\"b\": 1, \"a\": [1,2,3], \"名称\": \"鲸鱼娘\"}',
  decode('48656c6c6f', 'hex'),
  NULL,
  '',
  'line1' || chr(10) || 'line2',
  '\\x48656c6c6f'
);" >/dev/null 2>&1
[ $? -eq 0 ] && echo "  ✅ payloads 表已就绪（jsonb / bytea / NULL / 空串 / 多行）" || { echo "  ❌ 造现场失败"; exit 1; }

echo ""
echo "== 1) 竖排详情：形态与摘要逐项核对 =="
OUT="$("$CLI" row --table payloads --where "id = 1" 2>&1)"
echo "$OUT" | head -14 | sed 's/^/  /'
check "输出标题带列数" $([ "$(echo "$OUT" | grep -c '行详情（7 列）')" = "1" ] && echo 0 || echo 1)
echo "$OUT" | grep -qE "doc \[[^]]*\]：JSON 对象" && check "jsonb 识别为 JSON 对象" 0 || check "jsonb 形态" 1
# **实测边界**：驱动把 bytea 按 UTF-8 解码（`\x48656c6c6f` → `Hello`），
# 因此这里看到的是文本而不是十六进制 —— 脚本按**实际行为**断言，不按我的想象。
echo "$OUT" | grep -qE "blob \[[^]]*\]：文本 · 5 字符" && check "bytea 被驱动解码为文本（已知边界，见需求行说明）" 0 \
    || { check "bytea 形态" 1; echo "$OUT" | grep blob; }
echo "$OUT" | grep -qE "note \[[^]]*\]：NULL" && check "NULL 与空串区分（note 是 NULL）" 0 || check "NULL" 1
echo "$OUT" | grep -qE "empty_text \[[^]]*\]：空字符串" && check "空串显示为「空字符串」而不是 NULL" 0 || check "空串" 1
echo "$OUT" | grep -qE "multi \[[^]]*\]：文本 · 11 字符 · 2 行" && check "多行文本报告行数" 0 || check "行数" 1
# 文本列里存十六进制（例如从别处搬来的 bytea 文本）→ 走二进制摘要分支
echo "$OUT" | grep -qE "hex_text \[[^]]*\]：二进制 5 字节" && check "十六进制文本被识别为二进制并给字节数" 0 \
    || { check "十六进制文本" 1; echo "$OUT" | grep hex_text; }

echo ""
echo "== 2) JSON 真的被格式化了（换行 + 键有序），中文没被转义 =="
echo "$OUT" | grep -q '"a"' && check "JSON 键可见" 0 || check "JSON 键" 1
echo "$OUT" | grep -q "鲸鱼娘" && check "中文原样显示（没被 \\\\u 转义）" 0 || check "中文" 1
# 键排序：a 出现在 b 之前
A_LINE=$(echo "$OUT" | grep -n '"a"' | head -1 | cut -d: -f1)
B_LINE=$(echo "$OUT" | grep -n '"b"' | head -1 | cut -d: -f1)
[ -n "$A_LINE" ] && [ -n "$B_LINE" ] && [ "$A_LINE" -lt "$B_LINE" ] && check "键按字典序（显示顺序稳定）" 0 \
    || check "键有序（a 在 b 前）" 1

echo ""
echo "== 3) JSON 出口（脚本可断言）=="
JSON_OUT="$("$CLI" row --table payloads --where "id = 1" --json 2>&1)"
echo "$JSON_OUT" | head -6 | sed 's/^/  /'
echo "$JSON_OUT" | grep -q '"shape"\|"summary"' && check "结构化输出含摘要字段" 0 || check "结构化输出" 1
# 用 Python 解析，确认它是合法 JSON 且字段稳定
python3 - "$JSON_OUT" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
by_name = {item["column"]: item for item in payload}
assert by_name["doc"]["summary"].startswith("JSON 对象"), by_name["doc"]["summary"]
# 驱动已按 UTF-8 解码 bytea → 这里是文本；二进制的判定由文本列里的 hex 覆盖
assert by_name["blob"]["summary"].startswith("文本"), by_name["blob"]["summary"]
assert "二进制 5 字节" in by_name["hex_text"]["summary"], by_name["hex_text"]["summary"]
assert by_name["note"]["summary"] == "NULL"
assert by_name["empty_text"]["summary"] == "空字符串"
print("  ✅ 结构化输出可被程序解析且字段稳定")
PY

echo ""
echo "== 4) 危险输入不接受（--where 里带分号）=="
BAD="$("$CLI" row --table payloads --where "1=1; DROP TABLE payloads" 2>&1)"
BAD_CODE=$?
[ "$BAD_CODE" -ne 0 ] && check "带分号的 --where 被拒绝（退出码 ${BAD_CODE}）" 0 || check "应拒绝" 1
STILL="$("$CLI" -c "SELECT count(*) AS n FROM payloads;" 2>/dev/null | awk '/^[0-9]+$/{print $1}' | head -1)"
[ "${STILL:-x}" = "1" ] && check "表仍在（拒绝生效）" 0 || check "表不该消失" 1

echo ""
echo "== 5) 清理现场 =="
PGDATABASE=postgres "$CLI" -c "DROP DATABASE IF EXISTS ${DB};" >/dev/null 2>&1
echo "  ✅ 已删除临时库 ${DB}"

echo ""
if [ "$fail" -eq 0 ]; then
    echo "通过：竖排详情的形态判定、JSON 格式化、NULL/空串区分与危险输入拒绝都成立"
else
    echo "有失败项，见上"
fi
exit "$fail"
