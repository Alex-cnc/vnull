#!/bin/bash
# 验证：连接失败的可读文案（R-46 / FR-META-10）。
#
# 为什么值得单独验：连不上库时用户看到的第一句话决定排查方向。原来的输出是
# `PSQLError(code: connectionError, underlying: Connect timeout (10 s))` ——
# 既看不出"是密码错、库不存在、还是网络不通"，也不知道下一步查什么。
# 这里逐种失败造一遍，断言**人话 + 建议 + 错误码**都在，且**原始串没被丢掉**。
#
# 环境：本机临时集群（PG 二进制在 ~/tools/pgserver/...，端口 55433）用于"库不存在"这一档。
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

echo "== 0) 构建 CLI =="
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
if swift build --disable-sandbox --cache-path "$PWD/.build-cache" --scratch-path "$PWD/.build" \
    --manifest-cache local -Xswiftc -disable-sandbox --product DoyahCLI > /tmp/conn-errors-build.log 2>&1; then
    check "CLI 构建成功" 0
else
    check "CLI 构建成功" 1
    tail -5 /tmp/conn-errors-build.log
    exit 1
fi

echo ""
echo "== 1) 端口没人监听（连接超时 / 被拒）=="
OUT="$(PGHOST=127.0.0.1 PGPORT=59999 PGUSER=nobody PGPASSWORD="" PGDATABASE=nothing \
    "$CLI" -c "SELECT 1" 2>&1)"
code=$?
check "失败退出码非 0（实际 ${code}）" "$([ "$code" -ne 0 ] && echo 0 || echo 1)"
echo "$OUT" | grep -qE "连接超时|目标主机拒绝了连接" && check "给了人话（超时 / 拒绝）" 0 || check "给了人话（超时 / 拒绝）" 1
echo "$OUT" | grep -q "建议：" && check "给了排查建议" 0 || check "给了排查建议" 1
echo "$OUT" | grep -q "127.0.0.1:59999/nothing" && check "带上了目标（跨库时才知道是哪个）" 0 || check "带上了目标（跨库时才知道是哪个）" 1
echo "$OUT" | grep -q "调试详情" && echo "$OUT" | grep -q "PSQLError" \
    && check "原始串仍然保留（信息不丢）" 0 || check "原始串仍然保留（信息不丢）" 1

echo ""
echo "== 2) 主机名解析不了 =="
OUT2="$(PGHOST=no-such-host.invalid PGPORT=5432 PGUSER=x PGPASSWORD="" PGDATABASE=x \
    "$CLI" -c "SELECT 1" 2>&1)"
# 本环境把"主机名解析不了"报成 connect timeout（实测），因此这里断言的是**可读且指向解析**：
# 文案要点出目标、并提醒先确认主机名 —— 而不是硬套一个"解析失败"的标签（那样在别的环境会假红）。
if echo "$OUT2" | grep -qE "连接超时|主机名解析不了"; then
    check "给了人话（超时 / 解析不了）" 0
else
    echo "$OUT2" | head -12; check "给了人话（超时 / 解析不了）" 1
fi
echo "$OUT2" | grep -q "主机名" && check "建议里提醒先确认主机名（超时的常见原因是它是打错的）" 0 \
    || check "建议里提醒先确认主机名（超时的常见原因是它是打错的）" 1

echo ""
echo "== 3) 库不存在（真集群）=="
if [ ! -f "${DATADIR}/PG_VERSION" ]; then
    mkdir -p "$DATADIR"
    "$PGBIN/initdb" -D "$DATADIR" -U postgres --auth=trust -E UTF8 >/dev/null 2>&1
fi
if ! "$PGBIN/pg_ctl" -D "$DATADIR" status >/dev/null 2>&1; then
    "$PGBIN/pg_ctl" -D "$DATADIR" -o "-p ${PORT} -k /tmp" -l /tmp/doyah-conn-errors-pg.log start >/dev/null 2>&1
    STARTED=1
    sleep 2
fi
OUT3="$(PGHOST=127.0.0.1 PGPORT="$PORT" PGUSER=postgres PGPASSWORD="" PGDATABASE=no_such_db_xyz \
    "$CLI" -c "SELECT 1" 2>&1)"
echo "$OUT3" | grep -q "数据库不存在或无权连接" && check "识别为库不存在 / 无权连接" 0 \
    || { echo "$OUT3" | head -12; check "识别为库不存在 / 无权连接" 1; }
echo "$OUT3" | grep -q "no_such_db_xyz" && check "把库名写进文案" 0 || check "把库名写进文案" 1

echo ""
echo "== 4) 对照：能连上时不出现任何失败文案 =="
OUT4="$(PGHOST=127.0.0.1 PGPORT="$PORT" PGUSER=postgres PGPASSWORD="" PGDATABASE=postgres \
    "$CLI" -c "SELECT 1" 2>&1)"
code=$?
check "正常连接退出码 0（实际 ${code}）" "$([ "$code" -eq 0 ] && echo 0 || echo 1)"
echo "$OUT4" | grep -q "连接失败" && check "正常路径没有多余的失败文案" 1 || check "正常路径没有多余的失败文案" 0

echo ""
echo "== 5) SQL 类错误**不**被说成连接问题（负例，单测同口径）=="
OUT5="$(PGHOST=127.0.0.1 PGPORT="$PORT" PGUSER=postgres PGPASSWORD="" PGDATABASE=postgres \
    "$CLI" -c "SELECT * FROM no_such_table_xyz" 2>&1)"
if echo "$OUT5" | grep -q "连接中断\|连接超时\|解析不了"; then
    check "SQL 错误没被翻译成连接失败" 1
else
    check "SQL 错误没被翻译成连接失败" 0
fi

echo ""
echo "== 6) **不带口令**（不是空口令，是根本没给）连 trust 库也要成功 =="
# 这一档守的是「无口令认证」这条路：服务端是 trust / peer / 证书时本来就不需要口令，
# 客户端在连接前无从判断 —— 所以 `password = nil` 必须能一路走到底。
# （App 侧原先"没存口令就直接拒绝"，本机 trust 集群于是**永远连不上**；本轮修掉。）
OUT6="$(env -u PGPASSWORD PGHOST=127.0.0.1 PGPORT="$PORT" PGUSER=postgres PGDATABASE=postgres \
    "$CLI" -c "SELECT 1" 2>&1)"
code=$?
check "无口令连接退出码 0（实际 ${code}）" "$([ "$code" -eq 0 ] && echo 0 || echo 1)"
echo "$OUT6" | grep -q "连接成功" && check "无口令也能连上 trust 库（无口令认证不是错误）" 0 \
    || { echo "$OUT6" | head -8; check "无口令也能连上 trust 库（无口令认证不是错误）" 1; }
echo "$OUT6" | grep -q "缺少口令" && check "没有误报「缺少口令」" 1 || check "没有误报「缺少口令」" 0

echo ""
if [ "$fail" -eq 0 ]; then
    echo "全部通过：连接失败给的是人话 + 建议 + 错误码，且原始串仍在调试详情里。"
else
    echo "有失败项，见上"
fi
exit "$fail"
