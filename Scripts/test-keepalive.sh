#!/bin/bash
# 验证：连接保活心跳（FR-CONN-20）。
#
# 需求只要求"间隔可配置、可关闭"，所以要验的三件事很直白：
#   · 开着的时候**真的按间隔发出去了**且成功；
#   · 关掉之后**一条都不发**；
#   · 间隔有下限（不然就不是保活而是刷屏）。
# "空闲够久才发"那条判据在 Core 的纯函数里，由单测覆盖（这里只验真实发送链路）。
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"
PGBIN="$HOME/tools/pgserver/pgserver/pginstall/bin"
DATADIR="$PWD/.build/pgdata-session-test"
PORT=55433
STARTED=0

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }
cleanup() { [ "$STARTED" = "1" ] && "$PGBIN/pg_ctl" -D "$DATADIR" stop >/dev/null 2>&1; }
trap cleanup EXIT

echo "== 0) 起实例 =="
if [ ! -f "${DATADIR}/PG_VERSION" ]; then
    mkdir -p "$DATADIR"
    "$PGBIN/initdb" -D "$DATADIR" -U postgres --auth=trust -E UTF8 >/dev/null 2>&1
fi
if ! "$PGBIN/pg_ctl" -D "$DATADIR" status >/dev/null 2>&1; then
    "$PGBIN/pg_ctl" -D "$DATADIR" -o "-p ${PORT} -k /tmp" -l /tmp/doyah-keepalive-pg.log start >/dev/null 2>&1
    STARTED=1
    sleep 2
fi
export PGHOST=127.0.0.1 PGPORT="$PORT" PGUSER=postgres PGPASSWORD="" PGDATABASE=postgres

echo ""
echo "== 1) 开启：真发三次心跳且都成功 =="
OUT="$("$CLI" keepalive --pings 3 2>&1)"; CODE=$?
echo "$OUT" | sed 's/^/  /'
[ "$CODE" -eq 0 ] && check "心跳全部成功（退出码 0）" 0 || check "心跳应全部成功" 1
[ "$(echo "$OUT" | grep -c 'SELECT 1 成功')" = "3" ] && check "确实发了三次（逐次报告）" 0 || check "应报告三次成功" 1
echo "$OUT" | grep -q "汇总：心跳成功 3 次" && check "汇总计数正确" 0 || check "汇总计数" 1

echo ""
echo "== 2) 心跳语句必须无副作用 =="
echo "$OUT" | grep -q "SELECT 1" && check "心跳语句是 SELECT 1（只读、最轻）" 0 || check "心跳语句" 1

echo ""
echo "== 3) 关闭：一条都不发 =="
OFF="$("$CLI" keepalive --disabled 2>&1)"; OFF_CODE=$?
echo "$OFF" | sed 's/^/  /'
[ "$OFF_CODE" -eq 0 ] && check "关闭时正常退出" 0 || check "关闭时应正常退出" 1
echo "$OFF" | grep -q "不会发送任何心跳" && check "明确说明不会发送" 0 || check "应说明不发" 1
# 别用裸 `成功` 去 grep：连接横幅里就有「连接成功」，会假失败（我第一版就是这么错的）
echo "$OFF" | grep -q "SELECT 1 成功" && check "关闭后不该有任何发送记录" 1 || check "关闭后确实没发" 0

echo ""
echo "== 4) 间隔有下限（间隔可配置，但不会密到刷屏）=="
FLOOR="$("$CLI" keepalive --interval 1 --pings 1 2>&1)"
echo "$FLOOR" | head -2 | sed 's/^/  /'
echo "$FLOOR" | grep -q "间隔 5 秒" && check "间隔下限为 5 秒（配置 1 被抬到 5）" 0 || check "间隔下限" 1
CUSTOM="$("$CLI" keepalive --interval 30 --pings 1 2>&1)"
echo "$CUSTOM" | grep -q "间隔 30 秒" && check "正常的自定义间隔原样保留" 0 || check "自定义间隔" 1

echo ""
if [ "$fail" -eq 0 ]; then
    echo "通过：心跳真实发送且成功 / 语句无副作用 / 关闭后一条不发 / 间隔可配置且有下限"
    echo "（**边界**：应用内的定时器与设置项仍需人工观察；"空闲够久才发"的判据由 Core 单测覆盖）"
else
    echo "有失败项，见上"
fi
exit "$fail"
