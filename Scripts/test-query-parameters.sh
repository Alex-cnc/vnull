#!/bin/bash
# 验证：查询参数绑定（FR-EXEC-17）。
#
# 最要紧的一条：**恶意输入只能变成数据**。所以这里真的把 `x'; DROP TABLE users; --`
# 当参数值插进去，然后确认表还在、值原样存着。
# 用本机 16.2 实例（写库需要可支配的库）。
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"
PGBIN="$HOME/tools/pgserver/pgserver/pginstall/bin"
DATADIR="$PWD/.build/pgdata-session-test"
PORT=55433
DB="doyah_param_check"
STARTED=0

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }

cleanup() { [ "$STARTED" = "1" ] && "$PGBIN/pg_ctl" -D "$DATADIR" stop >/dev/null 2>&1; }
trap cleanup EXIT

echo "== 0) 起本机实例 =="
if [ ! -f "${DATADIR}/PG_VERSION" ]; then
    mkdir -p "$DATADIR"
    "$PGBIN/initdb" -D "$DATADIR" -U postgres --auth=trust -E UTF8 >/dev/null 2>&1
fi
if ! "$PGBIN/pg_ctl" -D "$DATADIR" status >/dev/null 2>&1; then
    "$PGBIN/pg_ctl" -D "$DATADIR" -o "-p ${PORT} -k /tmp" -l /tmp/doyah-param-pg.log start >/dev/null 2>&1
    STARTED=1
    sleep 2
fi
"$PGBIN/pg_ctl" -D "$DATADIR" status >/dev/null 2>&1 && echo "  ✅ 实例在跑（端口 ${PORT}）" || { echo "  ❌ 实例没起来"; exit 1; }

export PGHOST=127.0.0.1 PGPORT="$PORT" PGUSER=postgres PGPASSWORD=""
PGDATABASE=postgres "$CLI" -c "DROP DATABASE IF EXISTS ${DB};" >/dev/null 2>&1
PGDATABASE=postgres "$CLI" -c "CREATE DATABASE ${DB};" >/dev/null 2>&1
export PGDATABASE="$DB"
"$CLI" -c "CREATE TABLE users (id integer primary key, name text, note text); INSERT INTO users VALUES (1, 'alice', 'first');" >/dev/null 2>&1

echo ""
echo "== 1) 文本参数：引号与恶意值都只是数据 =="
ATTACK="x'; DROP TABLE users; --"
OUT="$("$CLI" -c "SELECT count(*) AS n FROM users WHERE name = :name" --param "name=${ATTACK}" 2>&1)"
echo "$OUT" | grep -E "^SQL：" -A 2 | sed 's/^/  /'
COUNT=$(echo "$OUT" | awk '/^[0-9]+$/{print $1}' | head -1)
[ "${COUNT:-x}" = "0" ] && check "恶意值被当作数据（查不到任何行，而不是报错或命中）" 0 \
    || check "应当查不到行（实际 ${COUNT:-未解析}）" 1
STILL="$("$CLI" -c "SELECT count(*) AS n FROM users;" 2>/dev/null | awk '/^[0-9]+$/{print $1}' | head -1)"
[ "${STILL:-x}" = "1" ] && check "**users 表还在**（注入没有生效）" 0 || check "表不该消失（实际 ${STILL:-?} 行）" 1

echo ""
echo "== 2) 值原样入库（双写引号是转义，不是改数据）=="
"$CLI" -c "INSERT INTO users VALUES (2, :name, 'x')" --param "name=O'Brien" >/dev/null 2>&1
STORED="$("$CLI" -c "SELECT name FROM users WHERE id = 2;" 2>/dev/null | grep -c "O'Brien")"
[ "${STORED:-0}" -ge 1 ] && check "含单引号的值原样存进去并在查回来时一致" 0 || check "含引号的值应原样存取" 1

echo ""
echo "== 3) 数字参数：不加引号（否则索引失效），且非法值被拒 =="
NUM_OUT="$("$CLI" -c "SELECT count(*) AS n FROM users WHERE id = :id" --param "id=1:number" 2>&1)"
echo "$NUM_OUT" | grep -q "WHERE id = 1" && check "数字参数渲染成 1（无引号）" 0 \
    || { check "数字不该带引号" 1; echo "$NUM_OUT" | grep -E "^SQL" -A 1; }
BAD_OUT="$("$CLI" -c "SELECT 1 WHERE 1 = :id" --param "id=1; DROP TABLE users:number" 2>&1)"
echo "$BAD_OUT" | grep -q "不是合法数字" && check "非法数字被拒并说明原因" 0 \
    || { check "非法数字应被拒" 1; echo "$BAD_OUT" | tail -2; }
STILL2="$("$CLI" -c "SELECT count(*) AS n FROM users;" 2>/dev/null | awk '/^[0-9]+$/{print $1}' | head -1)"
[ "${STILL2:-x}" = "2" ] && check "表仍在（非法数字没有变成语句）" 0 || check "表不该消失" 1

echo ""
echo "== 4) 字符串 / 注释里的 :name 不是参数 =="
LIT="$("$CLI" -c "SELECT ':name' AS literal" 2>&1)"
LIT_CODE=$?
[ "$LIT_CODE" -eq 0 ] && check "字符串里的 :name 没被当成参数（语句不需要填值就能跑）" 0 \
    || { check "字符串里的 :name 不该被当成参数" 1; echo "$LIT" | tail -2; }
echo "$LIT" | grep -q ":name" && check "字符串内容原样返回" 0 || check "字符串内容应原样返回" 1

echo ""
echo "== 5) 缺值要说清缺哪个；拼错名字要提示 =="
MISSING="$("$CLI" -c "SELECT * FROM users WHERE id = :id AND name = :name" --param "id=1:number" 2>&1)"
MISSING_CODE=$?
[ "$MISSING_CODE" -ne 0 ] && check "缺值时报错（退出码 ${MISSING_CODE}）" 0 || check "缺值应报错" 1
echo "$MISSING" | grep -q "name" && check "报错里点名缺的是 name" 0 || { check "应点名缺哪个参数" 1; echo "$MISSING" | tail -2; }
TYPO="$("$CLI" -c "SELECT * FROM users WHERE id = :id" --param "id=1:number" --param "idd=2:number" 2>&1)"
echo "$TYPO" | grep -q "没有在 SQL 里用到" && check "多填的参数被提示（多半是拼错）" 0 \
    || { check "多余参数应被提示" 1; echo "$TYPO" | head -3; }

echo ""
echo "== 6) 清理现场 =="
PGDATABASE=postgres "$CLI" -c "DROP DATABASE IF EXISTS ${DB};" >/dev/null 2>&1
echo "  ✅ 已删除临时库 ${DB}"

echo ""
if [ "$fail" -eq 0 ]; then
    echo "通过：参数绑定安全（恶意值只是数据、表还在）、类型化转义、字符串里的占位符不受影响"
else
    echo "有失败项，见上"
fi
exit "$fail"
