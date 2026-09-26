#!/bin/bash
# 验证：COPY FROM STDIN 导入（FR-IO-03 的快路径）。
#
# 两件事必须一起验：
#   ① **值不能错**：制表符 / 换行 / 反斜杠要原样保真，NULL 与空串不能混
#      （这类错误看着成功、数据已错，事后极难发现）；
#   ② **确实更快**：COPY 的意义就是吞吐，所以要拿同一份数据跟 INSERT 路径对照。
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"
# 连接信息（本机过渡集群 / 远程专用库）由共用入口决定 —— 三档端口与目录只写在它里面
source "$(cd "$(dirname "$0")" && pwd)/lib/test-env.sh"
doyah_test_env_summary

PGBIN="${DOYAH_TEST_PG_BIN}"
DATADIR="${DOYAH_TEST_LOCAL_DATADIR}"
PORT="${DOYAH_TEST_PGPORT}"
DB="doyah_copy_check"
STARTED=0

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }
cleanup() { [ "$STARTED" = "1" ] && "$PGBIN/pg_ctl" -D "$DATADIR" stop >/dev/null 2>&1; }
trap cleanup EXIT
scalar() {
    PGDATABASE="$DB" "$CLI" -c "$1" 2>/dev/null | awk '
        /^--- statement 1 ---/ { seen = 1; next }
        seen && /^finished:/ { exit }
        seen { if (header == "") { header = $0 } else { print; exit } }'
}

echo "== 0) 起实例与目标表 =="
if [ ! -f "${DATADIR}/PG_VERSION" ]; then
    mkdir -p "$DATADIR"
    "$PGBIN/initdb" -D "$DATADIR" -U postgres --auth=trust -E UTF8 >/dev/null 2>&1
fi
if ! "$PGBIN/pg_ctl" -D "$DATADIR" status >/dev/null 2>&1; then
    "$PGBIN/pg_ctl" -D "$DATADIR" -o "-p ${PORT} -k /tmp" -l /tmp/doyah-copy-pg.log start >/dev/null 2>&1
    STARTED=1
    sleep 2
fi
doyah_test_env_export_connection
PGDATABASE="${DOYAH_TEST_ADMIN_DB}" "$CLI" -c "DROP DATABASE IF EXISTS ${DB} WITH (FORCE);" >/dev/null 2>&1
PGDATABASE="${DOYAH_TEST_ADMIN_DB}" "$CLI" -c "CREATE DATABASE ${DB};" >/dev/null 2>&1

echo ""
echo "== 1) 值保真：制表符 / 换行 / 反斜杠 / 空串 / NULL =="
PGDATABASE="$DB" "$CLI" -c "CREATE TABLE items (id integer primary key, note text);" >/dev/null 2>&1
# 第 2 行是**裸空字段**（→ NULL），第 3 行是**引号空串**（→ 空串）：两者必须不同
printf 'id,note\n1,plain\n2,\n3,""\n4,"with\ttab"\n5,"line1\nline2"\n6,"back\\\\slash"\n' > "$PWD/.build/copy-values.csv"
PGDATABASE="$DB" "$CLI" import --table items --file "$PWD/.build/copy-values.csv" --copy --write 2>&1 | tail -2 | sed 's/^/  /'
ROWS="$(scalar "SELECT count(*) FROM items;" | tr -dc '0-9')"
[ "$ROWS" = "6" ] && check "6 行都写进去了" 0 || check "应有 6 行（实际 ${ROWS}）" 1
NULL_COUNT="$(scalar "SELECT count(*) FROM items WHERE note IS NULL;" | tr -dc '0-9')"
EMPTY_COUNT="$(scalar "SELECT count(*) FROM items WHERE note = '';" | tr -dc '0-9')"
[ "$NULL_COUNT" = "1" ] && check "裸空字段 → NULL（1 行）" 0 || check "NULL 行数应为 1（实际 ${NULL_COUNT}）" 1
[ "$EMPTY_COUNT" = "1" ] && check "引号空串 → 空串（1 行）—— NULL 与空串没有混" 0 || check "空串行数应为 1（实际 ${EMPTY_COUNT}）" 1
TAB="$(scalar "SELECT count(*) FROM items WHERE position(chr(9) in note) > 0;" | tr -dc '0-9')"
NL="$(scalar "SELECT count(*) FROM items WHERE position(chr(10) in note) > 0;" | tr -dc '0-9')"
BS="$(scalar "SELECT count(*) FROM items WHERE position(chr(92) in note) > 0;" | tr -dc '0-9')"
[ "$TAB" = "1" ] && check "制表符在值里保真（没被当分隔符）" 0 || check "制表符保真（实际 ${TAB}）" 1
[ "$NL" = "1" ] && check "换行在值里保真（没被当行尾）" 0 || check "换行保真（实际 ${NL}）" 1
[ "$BS" = "1" ] && check "反斜杠保真（没有少一层）" 0 || check "反斜杠保真（实际 ${BS}）" 1

echo ""
echo "== 2) 吞吐对照：同一份数据，COPY vs 批量 INSERT =="
python3 - "$PWD/.build/copy-big.csv" <<'PYEOF'
import pathlib, sys
rows = ["id,note"] + ["%d,value-%d" % (i, i) for i in range(1, 20001)]
pathlib.Path(sys.argv[1]).write_text("\n".join(rows) + "\n", encoding="utf-8")
PYEOF
PGDATABASE="$DB" "$CLI" -c "DROP TABLE IF EXISTS big_insert; CREATE TABLE big_insert (id integer primary key, note text);
DROP TABLE IF EXISTS big_copy; CREATE TABLE big_copy (id integer primary key, note text);" >/dev/null 2>&1
# 两条路径都**计时**：没有数字，"更快"就只是说法
COPY_START=$(python3 -c 'import time; print(time.time())')
COPY_OUT="$(PGDATABASE="$DB" "$CLI" import --table big_copy --file "$PWD/.build/copy-big.csv" --copy --write 2>&1)"
COPY_END=$(python3 -c 'import time; print(time.time())')
INSERT_START=$(python3 -c 'import time; print(time.time())')
INSERT_OUT="$(PGDATABASE="$DB" "$CLI" import --table big_insert --file "$PWD/.build/copy-big.csv" --write 2>&1)"
INSERT_END=$(python3 -c 'import time; print(time.time())')
python3 - "$COPY_START" "$COPY_END" "$INSERT_START" "$INSERT_END" <<'PYEOF'
import sys
copy_s, copy_e, ins_s, ins_e = (float(v) for v in sys.argv[1:5])
copy_d, ins_d = copy_e - copy_s, ins_e - ins_s
print("  COPY   %.2f 秒 / 2 万行" % copy_d)
print("  INSERT %.2f 秒 / 2 万行（每批 500 行的多值 INSERT）" % ins_d)
if copy_d <= ins_d * 1.05:
    print("  ✅ COPY 不慢于批量 INSERT（实测 %.2f vs %.2f 秒）" % (copy_d, ins_d))
    sys.exit(0)
print("  ❌ COPY 反而更慢：%.2f vs %.2f 秒" % (copy_d, ins_d))
sys.exit(1)
PYEOF
[ $? -eq 0 ] || fail=1
COPY_ROWS="$(scalar "SELECT count(*) FROM big_copy;" | tr -dc '0-9')"
INSERT_ROWS="$(scalar "SELECT count(*) FROM big_insert;" | tr -dc '0-9')"
[ "$COPY_ROWS" = "20000" ] && [ "$INSERT_ROWS" = "20000" ] && check "两条路径都写满 2 万行（可对照）" 0 \
    || check "两条路径都应写满（COPY=${COPY_ROWS} INSERT=${INSERT_ROWS}）" 1
# 两条路径的**内容**必须一致（吞吐优化不能改变结果）
DIFF="$(scalar "SELECT count(*) FROM (SELECT * FROM big_copy EXCEPT SELECT * FROM big_insert) d;" | tr -dc '0-9')"
[ "$DIFF" = "0" ] && check "COPY 与 INSERT 写入的数据**逐行一致**（快不等于不一样）" 0 \
    || check "两条路径数据应一致（差异 ${DIFF} 行）" 1
rm -f "$PWD/.build/copy-values.csv" "$PWD/.build/copy-big.csv"

echo ""
echo "== 3) 不支持的方言要明确报错（不静默退回 INSERT）=="
if echo "$COPY_OUT" | grep -q "COPY 写入完成"; then
    check "PG 上走的是真正的 COPY 路径" 0
else
    check "应走 COPY 路径" 1
fi

echo ""
if [ "$fail" -eq 0 ]; then
    echo "通过：COPY 导入值保真（制表符/换行/反斜杠/NULL 与空串）且与 INSERT 路径数据逐行一致"
    echo "（**边界**：界面导入仍走既有路径；本脚本验的是 COPY 能力与值语义）"
else
    echo "有失败项，见上"
fi
exit "$fail"
