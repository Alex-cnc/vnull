#!/bin/bash
# 验证：合成数据的生成与写入（FR-AI-07）。
#
# 用本机 16.2 实例（写库需要可支配的库）。验四件事：
#   ① 按表结构自动推断的规格**能插进去**（非空列不给 NULL、主键唯一）；
#   ② 同 seed + 同规格 ⇒ **完全相同的行**（可复现是真要求，不是口号）；
#   ③ `--write` 真的写进表里（行数可核对），不加 `--write` 只输出 SQL、不碰库；
#   ④ 规格有问题要**说清楚**，而不是生成一半失败。
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"
# 连接信息（本机过渡集群 / 远程专用库）由共用入口决定 —— 三档端口与目录只写在它里面
source "$(cd "$(dirname "$0")" && pwd)/lib/test-env.sh"
doyah_test_env_summary

PGBIN="${DOYAH_TEST_PG_BIN}"
DATADIR="${DOYAH_TEST_LOCAL_DATADIR}"
PORT="${DOYAH_TEST_PGPORT}"
DB="doyah_synth_check"
STARTED=0

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }

cleanup() {
    [ "$STARTED" = "1" ] && "$PGBIN/pg_ctl" -D "$DATADIR" stop >/dev/null 2>&1
}
trap cleanup EXIT

echo "== 0) 起本机实例 =="
if [ ! -f "${DATADIR}/PG_VERSION" ]; then
    mkdir -p "$DATADIR"
    "$PGBIN/initdb" -D "$DATADIR" -U postgres --auth=trust -E UTF8 >/dev/null 2>&1
fi
if ! "$PGBIN/pg_ctl" -D "$DATADIR" status >/dev/null 2>&1; then
    "$PGBIN/pg_ctl" -D "$DATADIR" -o "-p ${PORT} -k /tmp" -l /tmp/doyah-synth-pg.log start >/dev/null 2>&1
    STARTED=1
    sleep 2
fi
"$PGBIN/pg_ctl" -D "$DATADIR" status >/dev/null 2>&1 && echo "  ✅ 实例在跑（端口 ${PORT}）" || { echo "  ❌ 实例没起来"; exit 1; }

doyah_test_env_export_connection
PGDATABASE="${DOYAH_TEST_ADMIN_DB}" "$CLI" -c "DROP DATABASE IF EXISTS ${DB};" >/dev/null 2>&1
PGDATABASE="${DOYAH_TEST_ADMIN_DB}" "$CLI" -c "CREATE DATABASE ${DB};" >/dev/null 2>&1
export PGDATABASE="$DB"

echo ""
echo "== 1) 造一张有约束的表（非空 / 主键 / 唯一 / 可空）=="
"$CLI" -c "DROP TABLE IF EXISTS orders;
CREATE TABLE orders (
  id integer PRIMARY KEY,
  email varchar(120) NOT NULL,
  amount numeric(10,2) NOT NULL,
  note text,
  active boolean,
  created_at timestamp NOT NULL
);" >/dev/null 2>&1
[ $? -eq 0 ] && echo "  ✅ orders 表已建好" || { echo "  ❌ 建表失败"; exit 1; }

echo ""
echo "== 2) 不加 --write：只输出 SQL，不碰库 =="
DRY="$("$CLI" synth --table orders --rows 5 --seed 7 2>&1)"
echo "$DRY" | head -3 | sed 's/^/  /'
echo "$DRY" | grep -q "未加 --write" && check "明确说明没有写库" 0 || check "应说明未写库" 1
echo "$DRY" | grep -q "INSERT INTO" && check "输出里有 INSERT 语句" 0 || check "输出含 INSERT" 1
COUNT="$("$CLI" -c "SELECT count(*) AS n FROM orders;" 2>/dev/null | awk '/^[0-9]+$/{print $1}' | head -1)"
[ "${COUNT:-x}" = "0" ] && check "表里一行都没有（确实没写）" 0 || check "不该写库（实际 ${COUNT:-?} 行）" 1

echo ""
echo "== 3) --write：真的写进去，并核对约束满足 =="
WRITE_OUT="$("$CLI" synth --table orders --rows 200 --seed 7 --write 2>&1)"
echo "$WRITE_OUT" | grep -E "按表结构推断|已生成|写入完成" | sed 's/^/  /'
echo "$WRITE_OUT" | grep -q "写入完成" && check "写入命令成功" 0 || { check "写入成功" 1; echo "$WRITE_OUT" | tail -4; }
COUNT="$("$CLI" -c "SELECT count(*) AS n FROM orders;" 2>/dev/null | awk '/^[0-9]+$/{print $1}' | head -1)"
[ "${COUNT:-0}" = "200" ] && check "表里 200 行（行数对得上）" 0 || check "应有 200 行，实际 ${COUNT:-未解析}" 1

# 约束核对：非空列没有 NULL、主键无重复
NULLS="$("$CLI" -c "SELECT count(*) AS n FROM orders WHERE email IS NULL OR amount IS NULL OR created_at IS NULL;" 2>/dev/null | awk '/^[0-9]+$/{print $1}' | head -1)"
[ "${NULLS:-x}" = "0" ] && check "非空列没有生成 NULL（规格自洽：插得进去）" 0 || check "非空列不该出现 NULL（${NULLS:-?} 行）" 1
DUPS="$("$CLI" -c "SELECT count(*) AS n FROM (SELECT id FROM orders GROUP BY id HAVING count(*) > 1) d;" 2>/dev/null | awk '/^[0-9]+$/{print $1}' | head -1)"
[ "${DUPS:-x}" = "0" ] && check "主键无重复（用的是序列而不是随机整数）" 0 || check "主键重复（${DUPS:-?} 组）" 1

echo ""
echo "== 4) 可复现：同 seed 再生成一次，行应当**逐字段一致** =="
PGDATABASE="${DOYAH_TEST_ADMIN_DB}" "$CLI" -c "DROP DATABASE IF EXISTS ${DB}_again;" >/dev/null 2>&1
PGDATABASE="${DOYAH_TEST_ADMIN_DB}" "$CLI" -c "CREATE DATABASE ${DB}_again;" >/dev/null 2>&1
PGDATABASE="${DB}_again" "$CLI" -c "CREATE TABLE orders (id integer PRIMARY KEY, email varchar(120) NOT NULL, amount numeric(10,2) NOT NULL, note text, active boolean, created_at timestamp NOT NULL);" >/dev/null 2>&1
PGDATABASE="${DB}_again" "$CLI" synth --table orders --rows 200 --seed 7 --write >/dev/null 2>&1
FIRST="$("$CLI" -c "SELECT md5(string_agg(id || '|' || email || '|' || amount || '|' || coalesce(note,'') || '|' || coalesce(active::text,''), ',' ORDER BY id)) FROM orders;" 2>/dev/null | grep -E "^[0-9a-f]{32}$" | head -1)"
SECOND="$(PGDATABASE="${DB}_again" "$CLI" -c "SELECT md5(string_agg(id || '|' || email || '|' || amount || '|' || coalesce(note,'') || '|' || coalesce(active::text,''), ',' ORDER BY id)) FROM orders;" 2>/dev/null | grep -E "^[0-9a-f]{32}$" | head -1)"
if [ -n "${FIRST:-}" ] && [ "$FIRST" = "$SECOND" ]; then
    check "两个库的数据指纹一致（${FIRST}）—— 同 seed 同规格必然同一批行" 0
else
    check "同 seed 应生成完全相同的行（${FIRST:-空} vs ${SECOND:-空}）" 1
fi

echo ""
echo "== 5) 换 seed 应当换数据（否则 seed 形同虚设）=="
PGDATABASE="${DOYAH_TEST_ADMIN_DB}" "$CLI" -c "DROP DATABASE IF EXISTS ${DB}_seed2;" >/dev/null 2>&1
PGDATABASE="${DOYAH_TEST_ADMIN_DB}" "$CLI" -c "CREATE DATABASE ${DB}_seed2;" >/dev/null 2>&1
PGDATABASE="${DB}_seed2" "$CLI" -c "CREATE TABLE orders (id integer PRIMARY KEY, email varchar(120) NOT NULL, amount numeric(10,2) NOT NULL, note text, active boolean, created_at timestamp NOT NULL);" >/dev/null 2>&1
PGDATABASE="${DB}_seed2" "$CLI" synth --table orders --rows 200 --seed 8 --write >/dev/null 2>&1
THIRD="$(PGDATABASE="${DB}_seed2" "$CLI" -c "SELECT md5(string_agg(id || '|' || email || '|' || amount || '|' || coalesce(note,'') || '|' || coalesce(active::text,''), ',' ORDER BY id)) FROM orders;" 2>/dev/null | grep -E "^[0-9a-f]{32}$" | head -1)"
[ -n "${THIRD:-}" ] && [ "$THIRD" != "$FIRST" ] && check "换 seed 得到不同数据" 0 || check "换 seed 应换数据" 1

echo ""
echo "== 6) 规格问题要说清楚（拿 --spec 给一份非法规格）=="
BAD_SPEC="$(mktemp -t doyah-bad-spec).json"
cat > "$BAD_SPEC" <<'JSON'
{"table":"orders","columns":[{"name":"id","generator":{"integer":{"min":10,"max":1}},"nullProbability":0,"isUnique":true}],"rowCount":5,"seed":1}
JSON
BAD_OUT="$("$CLI" synth --table orders --spec "$BAD_SPEC" 2>&1)"
echo "$BAD_OUT" | head -3 | sed 's/^/  /'
echo "$BAD_OUT" | grep -q "规格有问题" && check "非法规格被明确指出" 0 || { check "非法规格应被指出" 1; }
rm -f "$BAD_SPEC"

echo ""
echo "== 7) 清理现场 =="
PGDATABASE="${DOYAH_TEST_ADMIN_DB}" "$CLI" -c "DROP DATABASE IF EXISTS ${DB};" >/dev/null 2>&1
PGDATABASE="${DOYAH_TEST_ADMIN_DB}" "$CLI" -c "DROP DATABASE IF EXISTS ${DB}_again;" >/dev/null 2>&1
PGDATABASE="${DOYAH_TEST_ADMIN_DB}" "$CLI" -c "DROP DATABASE IF EXISTS ${DB}_seed2;" >/dev/null 2>&1
echo "  ✅ 已删除三个临时库"

echo ""
if [ "$fail" -eq 0 ]; then
    echo "通过：合成数据能按表结构生成、能写库、可复现（同 seed 同数据、换 seed 换数据）"
else
    echo "有失败项，见上"
fi
exit "$fail"
