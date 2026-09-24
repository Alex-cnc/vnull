#!/bin/bash
# 验证：CSV / JSON 导入（FR-IO-03）。
#
# 重点不是"能导入"，而是**别把数据读错位**：引号内的逗号与换行、`""` 转义、BOM、CRLF、
# NULL 与空串的区分 —— 这些在真实导出文件里每一个都常见。用本机 16.2 实例。
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"
PGBIN="$HOME/tools/pgserver/pgserver/pginstall/bin"
DATADIR="$PWD/.build/pgdata-session-test"
PORT=55433
DB="doyah_import_check"
STARTED=0

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }
cleanup() { [ "$STARTED" = "1" ] && "$PGBIN/pg_ctl" -D "$DATADIR" stop >/dev/null 2>&1; }
trap cleanup EXIT

echo "== 0) 起本机实例并建目标表 =="
if [ ! -f "${DATADIR}/PG_VERSION" ]; then
    mkdir -p "$DATADIR"
    "$PGBIN/initdb" -D "$DATADIR" -U postgres --auth=trust -E UTF8 >/dev/null 2>&1
fi
if ! "$PGBIN/pg_ctl" -D "$DATADIR" status >/dev/null 2>&1; then
    "$PGBIN/pg_ctl" -D "$DATADIR" -o "-p ${PORT} -k /tmp" -l /tmp/doyah-import-pg.log start >/dev/null 2>&1
    STARTED=1
    sleep 2
fi
export PGHOST=127.0.0.1 PGPORT="$PORT" PGUSER=postgres PGPASSWORD=""
PGDATABASE=postgres "$CLI" -c "DROP DATABASE IF EXISTS ${DB};" >/dev/null 2>&1
PGDATABASE=postgres "$CLI" -c "CREATE DATABASE ${DB};" >/dev/null 2>&1
export PGDATABASE="$DB"
"$CLI" -c "CREATE TABLE items (
  id integer PRIMARY KEY,
  name text NOT NULL,
  note text,
  amount numeric(10,2),
  active boolean,
  created_at timestamp
);" >/dev/null 2>&1
echo "  ✅ items 表已建好"

echo ""
echo "== 1) 造一个\"每个坑都踩到\"的 CSV =="
# BOM + CRLF + 引号内的逗号 + 引号内的换行 + 双写引号 + 空字段(NULL) + 引号空串
CSV="$(mktemp -t doyah-import).csv"
printf '\xEF\xBB\xBFid,name,note,amount,active,created_at\r\n' > "$CSV"
printf '1,"alice","a, b",12.50,true,2026-09-23 10:00:00\r\n' >> "$CSV"
printf '2,"bob","line1\nline2",7.00,false,2026-09-23 11:00:00\r\n' >> "$CSV"
printf '3,"carol ""quoted""",,99.99,true,2026-09-23 12:00:00\r\n' >> "$CSV"
printf '4,"dave","","",,2026-09-23 13:00:00\r\n' >> "$CSV"
echo "  ✅ CSV 已生成（$(wc -l < "$CSV" | tr -d ' ') 个物理行，含内嵌换行，因此逻辑行是 5 行）"

echo ""
echo "== 2) 默认不写库：先看映射与预检 =="
DRY="$("$CLI" import --table items --file "$CSV" 2>&1)"
echo "$DRY" | grep -E "列映射|→|未加 --write" | head -8 | sed 's/^/  /'
COUNT="$("$CLI" -c "SELECT count(*) AS n FROM items;" 2>/dev/null | awk '/^[0-9]+$/{print $1}' | head -1)"
[ "${COUNT:-x}" = "0" ] && check "没有 --write 时表是空的" 0 || check "不该写库（实际 ${COUNT:-?} 行）" 1

echo ""
echo "== 3) --write 真导入，并逐项核对读对了"
WRITE_OUT="$("$CLI" import --table items --file "$CSV" --write 2>&1)"
echo "$WRITE_OUT" | grep -E "导入完成|共 " | sed 's/^/  /'
COUNT="$("$CLI" -c "SELECT count(*) AS n FROM items;" 2>/dev/null | awk '/^[0-9]+$/{print $1}' | head -1)"
[ "${COUNT:-0}" = "4" ] && check "4 行都进来了（内嵌换行没被当成新行）" 0 || check "应有 4 行，实际 ${COUNT:-未解析}" 1

# 引号内的逗号
V="$("$CLI" -c "SELECT note FROM items WHERE id = 1;" 2>/dev/null | grep -c "a, b")"
[ "${V:-0}" -ge 1 ] && check "引号内的逗号是数据（a, b）" 0 || check "引号内逗号" 1
# 引号内的换行
V="$("$CLI" -c "SELECT length(note) AS n FROM items WHERE id = 2;" 2>/dev/null | awk '/^[0-9]+$/{print $1}' | head -1)"
[ "${V:-0}" = "11" ] && check "引号内的换行是数据（line1\\nline2 长度 11）" 0 || check "内嵌换行长度应为 11，实际 ${V:-?}" 1
# 双写引号
V="$("$CLI" -c "SELECT name FROM items WHERE id = 3;" 2>/dev/null | grep -c 'carol "quoted"')"
[ "${V:-0}" -ge 1 ] && check '双写引号还原成 carol "quoted"' 0 || check "双写引号" 1
# NULL 与空串的区分
V="$("$CLI" -c "SELECT count(*) AS n FROM items WHERE id = 3 AND note IS NULL;" 2>/dev/null | awk '/^[0-9]+$/{print $1}' | head -1)"
[ "${V:-x}" = "1" ] && check "未加引号的空字段是 NULL" 0 || check "空字段应为 NULL" 1
V="$("$CLI" -c "SELECT count(*) AS n FROM items WHERE id = 4 AND note = '';" 2>/dev/null | awk '/^[0-9]+$/{print $1}' | head -1)"
[ "${V:-x}" = "1" ] && check '加了引号的空串是空字符串（"" ≠ NULL）' 0 || check "引号空串应为空字符串" 1
# 类型：数字未加引号（amount 是 numeric）、布尔转对了
# 判据用**语义比较**而不是显示格式：PostgreSQL 的 numeric 输出会去掉尾零
# （存的是 12.50，直接 select 显示 12.5，要 `::text` 才看得到小数位）。
# 依赖显示格式的断言是脆的 —— 这一轮已经是第四次踩"判据本身不对"。
V="$("$CLI" -c "SELECT count(*) AS n FROM items WHERE id = 1 AND amount = 12.50;" 2>/dev/null | awk '/^[0-9]+$/{print $1}' | head -1)"
[ "${V:-x}" = "1" ] && check "数字列按数字写入（amount = 12.50 成立）" 0 || check "数字列（实际 ${V:-?}）" 1
SCALE="$("$CLI" -c "SELECT amount::text FROM items WHERE id = 1;" 2>/dev/null | grep -c "^12.50$")"
[ "${SCALE:-0}" -ge 1 ] && check "小数位按 numeric(10,2) 存下来了（::text = 12.50）" 0 || check "小数位（实际 ${SCALE:-?}）" 1
V="$("$CLI" -c "SELECT count(*) AS n FROM items WHERE active = true;" 2>/dev/null | awk '/^[0-9]+$/{print $1}' | head -1)"
[ "${V:-0}" = "2" ] && check "布尔值转换正确（2 行为 true）" 0 || check "布尔转换（实际 ${V:-?}）" 1

echo ""
echo "== 4) JSON 导入（对象数组；null 是 NULL，嵌套转 JSON 文本）=="
JSON="$(mktemp -t doyah-import).json"
cat > "$JSON" <<'JSON'
[{"id": 101, "name": "json-a", "note": null, "amount": 1.5},
 {"id": 102, "name": "json-b", "note": "ok", "amount": 2.5}]
JSON
"$CLI" import --table items --file "$JSON" --format json --write >/tmp/doyah-json-import.log 2>&1
[ $? -eq 0 ] && check "JSON 导入成功" 0 || { check "JSON 导入" 1; tail -3 /tmp/doyah-json-import.log; }
V="$("$CLI" -c "SELECT count(*) AS n FROM items WHERE id >= 101;" 2>/dev/null | awk '/^[0-9]+$/{print $1}' | head -1)"
[ "${V:-0}" = "2" ] && check "JSON 的两行都进来了" 0 || check "JSON 行数（实际 ${V:-?}）" 1
V="$("$CLI" -c "SELECT count(*) AS n FROM items WHERE id = 101 AND note IS NULL;" 2>/dev/null | awk '/^[0-9]+$/{print $1}' | head -1)"
[ "${V:-x}" = "1" ] && check "JSON null 落成 NULL" 0 || check "JSON null" 1

echo ""
echo "== 5) 安全网：必填列缺失要说清、坏值要列出来 =="
BAD="$(mktemp -t doyah-import).csv"
printf 'id,note\n1,hello\n' > "$BAD"   # 少掉 NOT NULL 的 name
BAD_OUT="$("$CLI" import --table items --file "$BAD" --write 2>&1)"
BAD_CODE=$?
[ "$BAD_CODE" -ne 0 ] && check "必填列缺失时**拒绝导入**（退出码 ${BAD_CODE}）" 0 || check "应拒绝导入" 1
echo "$BAD_OUT" | grep -q "必填列" && check "说明了缺哪一列" 0 || { check "应说明缺哪列" 1; echo "$BAD_OUT" | tail -2; }

TYPED="$(mktemp -t doyah-import).csv"
printf 'id,name,amount\n201,ok,abc\n' > "$TYPED"
TYPED_OUT="$("$CLI" import --table items --file "$TYPED" 2>&1)"
echo "$TYPED_OUT" | grep -q "无法按目标列类型转换" && check "坏值被列出（并说明会写成 NULL）" 0 \
    || { check "坏值应被列出" 1; echo "$TYPED_OUT" | tail -3; }

echo ""
echo "== 5.5) 无表头文件：按位置映射（FR-IO-06 / FR-IO-03）=="
# 以前 `--no-header` 读出来的表头是空的，而列映射按名字匹配 → 一列都对不上，功能等于不可用。
"$CLI" -c "CREATE TABLE positional (a integer, b text, c text);" >/dev/null 2>&1
PLAIN="$(mktemp -t doyah-import).csv"
printf '1,hello,世界\n2,again,\n' > "$PLAIN"
POS_OUT="$("$CLI" import --table positional --file "$PLAIN" --no-header --write 2>&1)"
POS_CODE=$?
[ "$POS_CODE" -eq 0 ] && check "无表头文件能导入（退出码 0）" 0 || { check "无表头文件能导入" 1; echo "$POS_OUT" | tail -4; }
echo "$POS_OUT" | grep -q "column1" && check "预览里给的是位置列名（column1…）" 0 || check "应有位置列名" 1

"$CLI" export --query "SELECT count(*) AS n, count(*) FILTER (WHERE a = 1 AND b = 'hello' AND c = '世界') AS first_row, count(*) FILTER (WHERE a = 2 AND c IS NULL) AS second_row FROM positional" --out /tmp/doyah-positional.csv > /dev/null 2>&1
POSLINE="$(tail -1 /tmp/doyah-positional.csv | tr -d '\r')"
[ "$POSLINE" = "2,1,1" ] && check "两行按位置落到了正确的列（第 1 列→a、第 2 列→b、第 3 列→c）" 0 \
    || { check "按位置落列不对（实际 $POSLINE）" 1; }

# 文件比表宽：多出来的列要点名（而不是悄悄丢）
WIDE="$(mktemp -t doyah-import).csv"
printf '1,hello,世界,多出来的一列\n' > "$WIDE"
WIDE_OUT="$("$CLI" import --table positional --file "$WIDE" --no-header 2>&1)"
echo "$WIDE_OUT" | grep -q "column4" && check "文件比表宽时，多出来的列被点名" 0 \
    || { check "应点名多出来的列" 1; echo "$WIDE_OUT" | tail -4; }

# 文件比表窄且目标列非空：提前拦住，别写坏一半
"$CLI" -c "CREATE TABLE positional_strict (a integer NOT NULL, b text NOT NULL);" >/dev/null 2>&1
NARROW="$(mktemp -t doyah-import).csv"
printf '7\n' > "$NARROW"
NARROW_OUT="$("$CLI" import --table positional_strict --file "$NARROW" --no-header --write 2>&1)"
NARROW_CODE=$?
[ "$NARROW_CODE" -ne 0 ] && check "文件比表窄且非空列缺来源时**拒绝导入**（退出码 ${NARROW_CODE}）" 0 \
    || check "应拒绝导入" 1
echo "$NARROW_OUT" | grep -q "必填列" && check "说明了缺哪一列（b）" 0 || { check "应说明缺哪列" 1; echo "$NARROW_OUT" | tail -3; }

echo ""
echo "== 6) 清理现场 =="
rm -f "$CSV" "$JSON" "$BAD" "$TYPED" "$PLAIN" "$WIDE" "$NARROW"
PGDATABASE=postgres "$CLI" -c "DROP DATABASE IF EXISTS ${DB};" >/dev/null 2>&1
echo "  ✅ 已删除临时库 ${DB}"

echo ""
if [ "$fail" -eq 0 ]; then
    echo "通过：CSV / JSON 导入读对了每一个坑（BOM / CRLF / 引号内逗号与换行 / 双写引号 / NULL vs 空串），坏值与必填缺失有安全网"
else
    echo "有失败项，见上"
fi
exit "$fail"
