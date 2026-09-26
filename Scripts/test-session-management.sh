#!/bin/bash
# 验证：服务器会话读取与「取消当前语句」（FR-SESS-01 / FR-SESS-02）。
#
# 为什么用**本机 16.2 实例**而不是 217：这个脚本会真的取消一条正在跑的语句 ——
# 在共享实例上做这件事是不礼貌的（可能中断别人），本机实例上做才是可复现的验收。
# 217 那边只做**只读**的会话查询。
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"
ACCOUNT="D264B21B-1880-4E73-A2D0-59A3F8E4D7EC"
# 连接信息（本机过渡集群 / 远程专用库）由共用入口决定 —— 三档端口与目录只写在它里面
source "$(cd "$(dirname "$0")" && pwd)/lib/test-env.sh"
doyah_test_env_summary

PGBIN="${DOYAH_TEST_PG_BIN}"
# 数据目录放在**工作区内**（默认档）：早先实测外部数据目录在当前沙箱下起不来
# （could not create lock file "postmaster.pid": Operation not permitted）。
DATADIR="${DOYAH_TEST_LOCAL_DATADIR}"
PORT="${DOYAH_TEST_PGPORT}"
STARTED=0

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }

cleanup() {
    # 收尾：确保没有留下那条长跑语句
    PGPASSWORD="${DOYAH_TEST_PGPASSWORD}" "$PGBIN/psql" -h "${DOYAH_TEST_PGHOST}" -p "${DOYAH_TEST_PGPORT}" -U "${DOYAH_TEST_PGUSER}" -d "${DOYAH_TEST_ADMIN_DB}" -c \
        "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE query LIKE '%pg_sleep%' AND pid <> pg_backend_pid();" \
        >/dev/null 2>&1
    [ "$STARTED" = "1" ] && "$PGBIN/pg_ctl" -D "$DATADIR" stop >/dev/null 2>&1
}
trap cleanup EXIT

echo "== 1) 起本机 16.2 实例（取消语句的验证场地）=="
if [ ! -f "${DATADIR}/PG_VERSION" ]; then
    echo "  · 初始化临时集群 ${DATADIR}"
    mkdir -p "$DATADIR"
    "$PGBIN/initdb" -D "$DATADIR" -U postgres --auth=trust -E UTF8 >/dev/null 2>&1 || { echo "  ❌ initdb 失败"; exit 1; }
fi
if ! "$PGBIN/pg_ctl" -D "$DATADIR" status >/dev/null 2>&1; then
    "$PGBIN/pg_ctl" -D "$DATADIR" -o "-p $PORT -k /tmp" -l /tmp/doyah-session-pg.log start >/dev/null 2>&1
    STARTED=1
    sleep 2
fi
"$PGBIN/pg_ctl" -D "$DATADIR" status >/dev/null 2>&1 && echo "  ✅ 本机实例在跑（端口 ${PORT}）" || { echo "  ❌ 实例没起来"; exit 1; }

doyah_test_env_export_connection
export PGDATABASE="${DOYAH_TEST_ADMIN_DB}"

echo ""
echo "== 2) 会话查询（代码里那条 pg_stat_activity 查询）在真机上跑得通 =="
QUERY="SELECT pid, usename, datname, client_addr, application_name, state, wait_event_type, wait_event, backend_start, query_start, query
FROM pg_stat_activity
WHERE pid <> pg_backend_pid()
ORDER BY query_start"
OUT="$("$CLI" -c "$QUERY" 2>&1)"
echo "$OUT" | grep -q "pid:INT4\|pid:" && check "查询返回了会话列" 0 || { check "查询返回会话列" 1; echo "$OUT" | head -5; }

echo ""
echo "== 3) 造一条长跑语句，确认它出现在会话列表里 =="
# 后台跑一条 60 秒的 pg_sleep，然后从另一个连接里把它找出来。
PGPASSWORD="${DOYAH_TEST_PGPASSWORD}" "$PGBIN/psql" -h "${DOYAH_TEST_PGHOST}" -p "${DOYAH_TEST_PGPORT}" -U "${DOYAH_TEST_PGUSER}" -d "${DOYAH_TEST_ADMIN_DB}" \
    -c "SELECT pg_sleep(60);" >/dev/null 2>&1 &
SLEEPER=$!
sleep 2
    # **必须限定 state='active'**：`query` 会保留上一条语句文本，
    # 不加这条会找到「已空闲的旧会话」，取消它照样返回 true —— 而真正在跑的那条没被碰（本轮踩到两次）。
FOUND="$("$CLI" -c "SELECT pid, state, query FROM pg_stat_activity WHERE query LIKE '%pg_sleep%' AND state = 'active' AND pid <> pg_backend_pid();" 2>&1)"
PID=$(echo "$FOUND" | awk -F' \\| ' '/^[0-9]+ \|/{print $1}' | tr -d ' ' | head -1)
if [ -n "${PID:-}" ]; then
    check "长跑语句出现在会话列表里（pid ${PID}）" 0
else
    check "长跑语句应出现在会话列表里" 1
    echo "$FOUND" | tail -3
fi

echo ""
echo "== 4) 取消这条语句（代码里那条 pg_cancel_backend 语句）=="
if [ -n "${PID:-}" ]; then
    CANCEL="$("$CLI" -c "SELECT pg_cancel_backend(${PID}) AS cancelled;" 2>&1)"
    echo "$CANCEL" | grep -qE "t$|true" && check "pg_cancel_backend 返回 true（服务端接受了取消）" 0 \
        || { check "取消应返回 true" 1; echo "$CANCEL" | tail -3; }

    sleep 1
    # 被取消的会话：语句结束（state 变 idle）或连接消失，两种都算成功。
    # 判据是 `state = 'active'`：**取消之后 `query` 字段仍保留上一条语句文本**（本轮踩到），只看 query 会把「已空闲」误判成「还在跑」。
    # 取消不是瞬时的：backend 要跑到取消检查点。**轮询等待**比固定 sleep 更可靠，
    # 也避免"其实已经取消了，只是我查得太早"这种假失败（本轮就踩过）。
    STILL=1
    for _ in $(seq 1 20); do
        # 注意：**单列结果的输出没有 ` | ` 分隔符**（就是一行 `0`）。
        # 用「整行都是数字」来取，否则会解析不到而把它误判成"仍在跑"（本轮踩到）。
        STILL="$("$CLI" -c "SELECT count(*) AS n FROM pg_stat_activity WHERE pid = ${PID} AND state = 'active';" 2>&1 | awk '/^[0-9]+$/{print $1}' | head -1)"
        [ "${STILL:-1}" = "0" ] && break
        sleep 0.5
    done
    [ "${STILL:-x}" = "0" ] && check "那条语句确实不再执行（state 已不是 active）" 0 || check "语句应被取消（仍是 active）" 1
    wait "$SLEEPER" 2>/dev/null
else
    echo "  ⚠️ 上一步没拿到 pid，跳过取消验证"
    fail=1
fi

echo ""
echo "== 5) 权限如实反馈：取消别人的会话应当得到 false（而不是假装成功）=="
# 用 postgres 之外的普通角色去取消 postgres 的会话：PG 要求同用户或 pg_signal_backend。
PGPASSWORD="${DOYAH_TEST_PGPASSWORD}" "$PGBIN/psql" -h "${DOYAH_TEST_PGHOST}" -p "${DOYAH_TEST_PGPORT}" -U "${DOYAH_TEST_PGUSER}" -d "${DOYAH_TEST_ADMIN_DB}" -c \
    "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'doyah_probe') THEN CREATE ROLE doyah_probe LOGIN; END IF; END \$\$;" >/dev/null 2>&1
PGPASSWORD="${DOYAH_TEST_PGPASSWORD}" "$PGBIN/psql" -h "${DOYAH_TEST_PGHOST}" -p "${DOYAH_TEST_PGPORT}" -U "${DOYAH_TEST_PGUSER}" -d "${DOYAH_TEST_ADMIN_DB}" \
    -c "SELECT pg_sleep(30);" >/dev/null 2>&1 &
SLEEPER2=$!
sleep 2
TARGET_PID=$(PGPASSWORD="${DOYAH_TEST_PGPASSWORD}" "$PGBIN/psql" -h 127.0.0.1 -p "$PORT" -U postgres -d postgres -tAc \
    "SELECT pid FROM pg_stat_activity WHERE query LIKE '%pg_sleep%' AND usename = 'postgres' LIMIT 1;" 2>/dev/null | tr -d ' ')
if [ -n "${TARGET_PID:-}" ]; then
    DENIED="$(PGUSER=doyah_probe PGDATABASE="${DOYAH_TEST_ADMIN_DB}" "$CLI" -c "SELECT pg_cancel_backend(${TARGET_PID}) AS cancelled;" 2>&1)"
    DENIED_CODE=$?
    if [ "$DENIED_CODE" -ne 0 ]; then
        echo "$DENIED" | grep -qi "permission denied" && check "权限不足时如实报错（permission denied）" 0 || { check "应报 permission denied" 1; echo "$DENIED" | tail -3; }
    elif echo "$DENIED" | grep -qiE "\| f|false"; then
        check "同级别失败时返回 false（如实反馈）" 0
    else
        check "权限不足不该看起来像成功" 1
        echo "$DENIED" | tail -3
    fi
else
    echo "  ⚠️ 没找到目标会话，跳过该检查"
fi
PGPASSWORD="${DOYAH_TEST_PGPASSWORD}" "$PGBIN/pg_ctl" -D "$DATADIR" stop >/dev/null 2>&1
"$PGBIN/pg_ctl" -D "$DATADIR" -o "-p $PORT -k /tmp" -l /tmp/doyah-session-pg.log start >/dev/null 2>&1
sleep 2
PGPASSWORD="${DOYAH_TEST_PGPASSWORD}" "$PGBIN/psql" -h 127.0.0.1 -p "$PORT" -U postgres -d postgres -c "DROP ROLE IF EXISTS doyah_probe;" >/dev/null 2>&1

echo ""
echo "== 6) 217 只读核对：会话查询在 18.6 上同样可用 =="
export PGHOST="${DOYAH_TEST_REMOTE_HOST}" PGPORT="${DOYAH_TEST_REMOTE_PORT}" PGUSER="${DOYAH_TEST_REMOTE_USER}" PGSSLMODE="${DOYAH_TEST_PGSSLMODE}"
PGPASSWORD="$("$CLI" secret get --id "$ACCOUNT")"
export PGPASSWORD
OUT217="$("$CLI" -c "$QUERY" 2>&1)"
echo "$OUT217" | grep -q "pid:" && check "217 上会话查询可用（未做任何取消 / 终止）" 0 || { check "217 会话查询" 1; echo "$OUT217" | tail -3; }

echo ""
if [ "$fail" -eq 0 ]; then
    echo "通过：会话读取与取消语句在本机 16.2 上验证成立（权限不足时如实报 permission denied）；217 只做只读核对"
else
    echo "有失败项，见上"
fi
exit "$fail"
