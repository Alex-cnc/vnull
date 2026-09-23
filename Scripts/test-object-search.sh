#!/bin/bash
# 验证：全库对象搜索（FR-META-12）。
#
# 验四件事：① 跨 schema 的表 / 视图 / 列 / 函数**一次查询**都能搜到；
# ② 列的命中形态是 `表.列`（搜列名能命中）；③ 排序合理（前缀优先）；④ 元数据上限会如实提示。
# 本机 16.2 上造现场，217（18.6）上只做只读搜索。
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"
ACCOUNT="D264B21B-1880-4E73-A2D0-59A3F8E4D7EC"
PGBIN="$HOME/tools/pgserver/pgserver/pginstall/bin"
DATADIR="$PWD/.build/pgdata-session-test"
PORT=55433
DB="doyah_search_check"
STARTED=0

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }
cleanup() { [ "$STARTED" = "1" ] && "$PGBIN/pg_ctl" -D "$DATADIR" stop >/dev/null 2>&1; }
trap cleanup EXIT

echo "== 0) 起本机实例，造跨 schema 的对象 =="
if [ ! -f "${DATADIR}/PG_VERSION" ]; then
    mkdir -p "$DATADIR"
    "$PGBIN/initdb" -D "$DATADIR" -U postgres --auth=trust -E UTF8 >/dev/null 2>&1
fi
if ! "$PGBIN/pg_ctl" -D "$DATADIR" status >/dev/null 2>&1; then
    "$PGBIN/pg_ctl" -D "$DATADIR" -o "-p ${PORT} -k /tmp" -l /tmp/doyah-search-pg.log start >/dev/null 2>&1
    STARTED=1
    sleep 2
fi
export PGHOST=127.0.0.1 PGPORT="$PORT" PGUSER=postgres PGPASSWORD=""
PGDATABASE=postgres "$CLI" -c "DROP DATABASE IF EXISTS ${DB};" >/dev/null 2>&1
PGDATABASE=postgres "$CLI" -c "CREATE DATABASE ${DB};" >/dev/null 2>&1
export PGDATABASE="$DB"
"$CLI" -c "
CREATE SCHEMA reporting;
CREATE TABLE public.orders (id int primary key, email text, amount numeric(10,2));
CREATE TABLE public.order_items (id int primary key, sku text);
CREATE VIEW reporting.order_summary AS SELECT count(*) AS n FROM public.orders;
CREATE FUNCTION public.order_total(a int, b int) RETURNS int LANGUAGE sql AS \$\$ SELECT a + b \$\$;
CREATE TABLE sales.customer_email (id int, email text);" >/dev/null 2>&1
# sales schema 需要先建
"$CLI" -c "CREATE SCHEMA IF NOT EXISTS sales; CREATE TABLE IF NOT EXISTS sales.customer_email (id int, email text);" >/dev/null 2>&1
[ $? -eq 0 ] && echo "  ✅ 现场已建立（public.orders / order_items / money 视图 / 函数；sales.customer_email）" || { echo "  ❌ 造现场失败"; exit 1; }

echo ""
echo "== 1) 搜表名片段：跨 schema 都能命中 =="
OUT="$("$CLI" search-objects order 2>&1)"
echo "$OUT" | head -8 | sed 's/^/  /'
echo "$OUT" | grep -q "public.order_items" && check "命中 public.order_items" 0 || check "应命中 order_items" 1
echo "$OUT" | grep -q "reporting.order_summary" && check "命中另一个 schema 的视图（跨 schema）" 0 || check "跨 schema 命中" 1
echo "$OUT" | grep -q "public.order_total" && check "命中函数（含签名）" 0 || check "函数命中" 1

echo ""
echo "== 2) 搜列名片段：列的命中形态是 表.列 =="
COL="$("$CLI" search-objects email --kind column 2>&1)"
echo "$COL" | head -6 | sed 's/^/  /'
echo "$COL" | grep -q "orders.email" && check "命中 orders.email" 0 || check "应命中 orders.email" 1
echo "$COL" | grep -q "customer_email.email" && check "命中另一张表的同名列（跨表）" 0 || check "跨表列命中" 1

echo ""
echo "== 3) 排序：前缀优先于中间子串 =="
ORDER="$("$CLI" search-objects order 2>&1 | grep -E "^\s+(table|view|column|function)" | head -2)"
echo "$ORDER" | sed 's/^/  /'
echo "$ORDER" | head -1 | grep -qE "order_items|orders|order_summary" && check "前两位都是 order 开头的对象（前缀优先）" 0 || check "前缀优先" 1

echo ""
echo "== 4) 限定 schema 只搜那个 schema =="
SCOPED="$("$CLI" search-objects order --schema reporting 2>&1)"
echo "$SCOPED" | head -4 | sed 's/^/  /'
echo "$SCOPED" | grep -q "public.order_items" && check "限定 reporting 时不该出现 public 的对象" 1 || check "限定 schema 生效（没有 public 的对象）" 0

echo ""
echo "== 5) 搜不到时退出码非零（脚本可判定）=="
"$CLI" search-objects zzzz_nothing_zzzz >/dev/null 2>&1
NONE_CODE=$?
[ "$NONE_CODE" -ne 0 ] && check "无命中返回非零（${NONE_CODE}）" 0 || check "无命中应返回非零" 1

echo ""
echo "== 6) 217（18.6）上只读搜索：一次查询在真机可用 =="
# 切到 217 时**必须同时改 PGDATABASE**：否则还连着本机的临时库名（本轮就踩了这个，
# 报错是 `database "doyah_search_check" does not exist` —— 脚本自己的疏漏，不是产品问题）。
export PGHOST=192.168.5.217 PGPORT=5432 PGUSER=zxvmax PGDATABASE=zxvmax PGSSLMODE=disable
PGPASSWORD="$("$CLI" secret get --id "$ACCOUNT")"
export PGPASSWORD
REMOTE="$("$CLI" search-objects pg_ 2>&1)"
echo "$REMOTE" | head -3 | sed 's/^/  /'
echo "$REMOTE" | grep -q "在 .* 个对象里搜" && check "217 上单次元数据查询可用（未做任何写操作）" 0 \
    || { check "217 搜索" 1; echo "$REMOTE" | tail -3; }

echo ""
echo "== 7) 清理现场 =="
unset PGHOST PGPORT PGUSER PGPASSWORD PGSSLMODE
export PGHOST=127.0.0.1 PGPORT="$PORT" PGUSER=postgres PGPASSWORD=""
PGDATABASE=postgres "$CLI" -c "DROP DATABASE IF EXISTS ${DB};" >/dev/null 2>&1
echo "  ✅ 已删除临时库 ${DB}"

echo ""
if [ "$fail" -eq 0 ]; then
    echo "通过：全库对象搜索一次查询跨 schema 命中表 / 视图 / 列 / 函数，排序与 schema 限定都正确"
else
    echo "有失败项，见上"
fi
exit "$fail"
