#!/bin/bash
# 验证：慢查询排行（FR-DIAG-03）。
#
# 分两段，因为这条需求的关键在两处：
#   ① **没有扩展时**要给"怎么装"的可读提示（这是最常见的情形，不是异常）；
#   ② **装上之后**排行要真的按口径排序。
# 本机 16.2 实例由我们掌控，可以真的装扩展（需 shared_preload_libraries + 重启）。
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"
ACCOUNT="D264B21B-1880-4E73-A2D0-59A3F8E4D7EC"
PGBIN="$HOME/tools/pgserver/pgserver/pginstall/bin"
DATADIR="$PWD/.build/pgdata-slowquery"
PORT=55434
DB="doyah_slow_check"
STARTED=0

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }
cleanup() { [ "$STARTED" = "1" ] && "$PGBIN/pg_ctl" -D "$DATADIR" stop >/dev/null 2>&1; }
trap cleanup EXIT

echo "== 0) 起一个**独立**的本机实例（要改 shared_preload_libraries 并重启，不动公共测试库）=="
if [ ! -f "${DATADIR}/PG_VERSION" ]; then
    mkdir -p "$DATADIR"
    "$PGBIN/initdb" -D "$DATADIR" -U postgres --auth=trust -E UTF8 >/dev/null 2>&1
fi
# 这个集群的配置就为这一项服务：预加载 pg_stat_statements。
if ! grep -q "shared_preload_libraries" "${DATADIR}/postgresql.conf" 2>/dev/null; then
    echo "shared_preload_libraries = 'pg_stat_statements'" >> "${DATADIR}/postgresql.conf"
fi
if ! "$PGBIN/pg_ctl" -D "$DATADIR" status >/dev/null 2>&1; then
    "$PGBIN/pg_ctl" -D "$DATADIR" -o "-p ${PORT} -k /tmp" -l /tmp/doyah-slow-pg.log start >/dev/null 2>&1
    STARTED=1
    sleep 2
fi
"$PGBIN/pg_ctl" -D "$DATADIR" status >/dev/null 2>&1 && echo "  ✅ 实例在跑（端口 ${PORT}，已预加载 pg_stat_statements）" || { echo "  ❌ 实例没起来"; exit 1; }

export PGHOST=127.0.0.1 PGPORT="$PORT" PGUSER=postgres PGPASSWORD=""
PGDATABASE=postgres "$CLI" -c "DROP DATABASE IF EXISTS ${DB};" >/dev/null 2>&1
PGDATABASE=postgres "$CLI" -c "CREATE DATABASE ${DB};" >/dev/null 2>&1
export PGDATABASE="$DB"

echo ""
echo "== 1) 没装扩展时：给怎么装的可读提示（而不是原始报错）=="
OUT="$("$CLI" slow-queries 2>&1)"
CODE=$?
echo "$OUT" | head -6 | sed 's/^/  /'
[ "$CODE" -eq 3 ] && check "退出码 3（环境不具备，与命令写错区分开）" 0 || check "退出码应为 3，实际 ${CODE}" 1
echo "$OUT" | grep -q "shared_preload_libraries" && check "提示里给了第一步（预加载）" 0 || check "提示预加载" 1
echo "$OUT" | grep -q "重启" && check "提示里说了要重启（只 CREATE EXTENSION 会得到一个困惑状态）" 0 || check "提示重启" 1
echo "$OUT" | grep -q "CREATE EXTENSION" && check "提示里给了建扩展语句" 0 || check "提示建扩展" 1
echo "$OUT" | grep -q "权限" && check "提示里提醒了权限" 0 || check "提示权限" 1

echo ""
echo "== 2) 排行 SQL 在**真库上真的跑一遍**（用同名视图模拟 pg_stat_statements）=="
# 为什么用视图而不是装扩展：本机精简构建（pgserver）**不带该扩展文件**
# （`Could not open extension control file ... pg_stat_statements.control`），
# 而在 217 上装扩展属于对别人服务器的写操作 —— 不该擅自做。
# 同名视图能让生成的 SQL **原样**在真库上执行：列名、排序、过滤、LIMIT 全都验到。
# （唯一例外是 PG 12 的旧列名，那条由单测覆盖。）
"$CLI" -c "CREATE VIEW pg_stat_statements AS
SELECT * FROM (VALUES
  ('SELECT pg_sleep(0.4), count(*) FROM t', 1::bigint, 410.0::float8, 410.0::float8, 1::bigint),
  ('SELECT count(*) FROM t', 7::bigint, 320.0::float8, 45.7::float8, 7::bigint),
  ('SELECT id FROM t WHERE id = 7', 2::bigint, 0.2::float8, 0.1::float8, 2::bigint),
  ('SELECT * FROM pg_stat_statements', 99::bigint, 9999.0::float8, 101.0::float8, 99::bigint)
) AS v(query, calls, total_exec_time, mean_exec_time, rows);" >/dev/null 2>&1
[ $? -eq 0 ] && check "已用同名视图模拟（排行 SQL 会原样执行）" 0 || { check "建视图" 1; exit 1; }

TOTAL="$("$CLI" slow-queries --sort total --limit 5 2>&1)"
TOTAL_CODE=$?
echo "$TOTAL" | head -6 | sed 's/^/  /'
[ "$TOTAL_CODE" -eq 0 ] && check "按总耗时排行执行成功（SQL 在真库上跑通）" 0 || check "总耗时排行" 1
echo "$TOTAL" | grep -q "pg_sleep" && check "总耗时最长的排第一" 0 || check "总耗时排序" 1
echo "$TOTAL" | grep -q "FROM pg_stat_statements" && check "扩展自身查询被过滤掉" 1 || check "已过滤扩展自身查询" 0

echo ""
echo "--- 按平均耗时 ---"
MEAN="$("$CLI" slow-queries --sort mean --limit 5 2>&1)"
echo "$MEAN" | head -5 | sed 's/^/  /'
# 按**内容**取第一条结果行：不带 --json 时输出前面有连接横幅，用行号取会取到横幅（本轮踩到）。
MEAN_TOP=$(echo "$MEAN" | grep -m1 "调用 .* 次 · 总")
echo "$MEAN" | grep -A1 -m1 "调用 .* 次 · 总" | tail -1 | sed 's/^/  /'
echo "$MEAN_TOP" | grep -q "平均 410 ms" && check "平均耗时最高的排第一（410 ms）" 0 \
    || { check "平均耗时排序：${MEAN_TOP}" 1; }

echo ""
echo "--- 按调用次数 ---"
CALLS="$("$CLI" slow-queries --sort calls --limit 3 2>&1)"
echo "$CALLS" | head -5 | sed 's/^/  /'
CALLS_TOP=$(echo "$CALLS" | grep -m1 "调用 .* 次 · 总")
echo "$CALLS_TOP" | grep -q "调用 7 次" && check "调用次数最多的（7 次）排第一" 0 \
    || { check "调用次数排序：${CALLS_TOP}" 1; }

echo ""
echo "--- JSON 出口（机器可读，不带横幅）---"
JSON_OUT="$("$CLI" slow-queries --sort mean --limit 3 --json 2>&1)"
python3 -c '
import json, sys
payload = json.loads(sys.argv[1])
assert isinstance(payload, list) and len(payload) == 3, len(payload)
means = [item["meanMillis"] for item in payload]
assert means == sorted(means, reverse=True), means
assert all("query" in item and "calls" in item and "totalMillis" in item for item in payload)
print("  ✅ JSON 可解析、字段稳定、按平均耗时降序")
' "$JSON_OUT"
[ $? -eq 0 ] || fail=1

echo ""
echo "== 3) 217（18.6）上的真实情形（只读；装没装扩展都要给对的东西）=="
export PGHOST=192.168.5.217 PGPORT=5432 PGUSER=zxvmax PGDATABASE=zxvmax PGSSLMODE=disable
PGPASSWORD="$("$CLI" secret get --id "$ACCOUNT")"
export PGPASSWORD
REMOTE="$("$CLI" slow-queries --limit 3 2>&1)"
REMOTE_CODE=$?
echo "$REMOTE" | head -5 | sed 's/^/  /'
if [ "$REMOTE_CODE" -eq 0 ]; then
    check "217 上扩展可用，排行成功（未做任何写操作）" 0
elif [ "$REMOTE_CODE" -eq 3 ]; then
    check "217 上没装扩展 → 给出可读的安装提示（这正是本项要处理的情形）" 0
else
    check "217 上的行为（退出码 ${REMOTE_CODE}）" 1
fi

echo ""
echo "== 4) 清理现场 =="
unset PGHOST PGPORT PGUSER PGDATABASE PGPASSWORD PGSSLMODE
export PGHOST=127.0.0.1 PGPORT="$PORT" PGUSER=postgres PGPASSWORD=""
PGDATABASE=postgres "$CLI" -c "DROP DATABASE IF EXISTS ${DB};" >/dev/null 2>&1
echo "  ✅ 已删除临时库 ${DB}"

echo ""
if [ "$fail" -eq 0 ]; then
    echo "通过：扩展缺失时给可读的安装指引（本机 + 217 两处都验了）；排行 SQL 用**同名视图**在真库上跑通"
    echo "      （总耗时 / 平均耗时 / 调用次数三种排序、过滤自身查询、JSON 出口都正确）"
    echo "      未验证：真 pg_stat_statements 扩展本身 —— 本机精简构建不带该扩展文件，217 上装扩展属于对别人服务器的写操作"
else
    echo "有失败项，见上"
fi
exit "$fail"
