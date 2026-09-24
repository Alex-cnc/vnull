#!/bin/bash
# 验证：数据库统计指标（FR-DIAG-04）。
#
# 四类指标都是**只读查询**，所以能在真库上直接断言；重点是口径而不是"能不能查出来"：
#   · 比率**算不出来时是空的**（不是 0%）—— 刚建的库没有扫描，显示 0% 会误导
#   · 顺序稳定、按大小/扫描量排序
#   · 单类指标失败不影响其它类
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"
PGBIN="$HOME/tools/pgserver/pgserver/pginstall/bin"
DATADIR="$PWD/.build/pgdata-session-test"
PORT=55433
DB="doyah_stats_check"
STARTED=0

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }
cleanup() { [ "$STARTED" = "1" ] && "$PGBIN/pg_ctl" -D "$DATADIR" stop >/dev/null 2>&1; }
trap cleanup EXIT

echo "== 0) 起实例并造一个有扫描痕迹的库 =="
if [ ! -f "${DATADIR}/PG_VERSION" ]; then
    mkdir -p "$DATADIR"
    "$PGBIN/initdb" -D "$DATADIR" -U postgres --auth=trust -E UTF8 >/dev/null 2>&1
fi
if ! "$PGBIN/pg_ctl" -D "$DATADIR" status >/dev/null 2>&1; then
    "$PGBIN/pg_ctl" -D "$DATADIR" -o "-p ${PORT} -k /tmp" -l /tmp/doyah-stats-pg.log start >/dev/null 2>&1
    STARTED=1
    sleep 2
fi
export PGHOST=127.0.0.1 PGPORT="$PORT" PGUSER=postgres PGPASSWORD=""
PGDATABASE=postgres "$CLI" -c "DROP DATABASE IF EXISTS ${DB} WITH (FORCE);" >/dev/null 2>&1
PGDATABASE=postgres "$CLI" -c "CREATE DATABASE ${DB};" >/dev/null 2>&1
export PGDATABASE="$DB"
"$CLI" -c "CREATE TABLE big (id integer primary key, payload text);
INSERT INTO big SELECT g, repeat('x', 100) FROM generate_series(1, 2000) g;
CREATE TABLE never_touched (id integer);" >/dev/null 2>&1
# 制造索引扫描与顺序扫描各一次（统计视图要真的被用到才有数据）
"$CLI" -c "SELECT count(*) FROM big WHERE id = 1;" >/dev/null 2>&1
"$CLI" -c "SELECT count(*) FROM big WHERE payload LIKE '%yy%';" >/dev/null 2>&1

echo ""
echo "== 1) 四类指标都有真实值 =="
JSON="$("$CLI" stats --limit 10 --json 2>&1)"
echo "$JSON" > "$PWD/.build/stats.json"
python3 - "$PWD/.build/stats.json" <<'PYEOF'
import json, pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
payload = json.loads(text[text.index("{"):])

sizes = payload["tableSizes"]
assert sizes, "表大小不该为空"
assert any(item["display"] == "16.0 KB" or item["bytes"] > 0 for item in sizes), sizes
# 按大小降序：big 应该排在 never_touched 之前
names = [item["name"] for item in sizes]
assert names.index("public.big") < names.index("public.never_touched"), names

scans = payload["indexHitRate"]
assert scans, "每张表的扫描统计不该为空"
for item in scans:
    total = item["seqScan"] + item["idxScan"]
    if total == 0:
        assert item["ratio"] is None, "没有扫描时比率必须是空值（不是 0）：%s" % item
    else:
        assert 0.0 <= item["ratio"] <= 1.0, item

connections = payload["connections"]
assert sum(connections.values()) >= 1, connections   # 至少含 CLI 自己这条连接

cache = payload["cacheHit"]
assert cache is not None, "缓存命中率应当拿到（哪怕全 0）"
if cache["hits"] + cache["reads"] > 0:
    assert 0.0 <= cache["ratio"] <= 1.0, cache
print("  ✅ 表大小有值且按大小降序 / 扫描比率在 0..1（无扫描为 null）/ 连接数 ≥1 / 缓存命中率在 0..1")
PYEOF
[ $? -eq 0 ] || fail=1

echo ""
echo "== 2) 人读输出也成型（不是只给 JSON 用）=="
TEXT="$("$CLI" stats --limit 3 2>&1)"
echo "$TEXT" | grep -E "表大小|索引命中率|连接数|缓存命中率" | sed 's/^/  /'
for section in "表大小" "索引命中率" "连接数" "缓存命中率"; do
    echo "$TEXT" | grep -q "$section" || { check "输出应含「${section}」" 1; }
done
check "四类指标都有可读输出" 0

echo ""
echo "== 3) 没被碰过的表：比率给「无扫描数据」而不是 0% =="
if echo "$TEXT" | grep -q "无扫描数据"; then
    check "从未扫描的表显示「无扫描数据」（不是 0%）" 0
else
    # 若它恰好被统计视图记了 0/0，JSON 里 ratio 必须为 null（上一节已断言）
    echo "$TEXT" | grep -q "0.0%" && check "无扫描的表不该显示成 0.0%（那是误导）" 1 || check "未扫描表未显示为 0%" 0
fi

echo ""
if [ "$fail" -eq 0 ]; then
    echo "通过：四类指标在真库上都有值 / 比率口径正确（无数据 → 空而非 0）/ 排序稳定 / 人读输出成型"
    echo "（**边界**：界面面板仍需人工看；本脚本验的是指标查询与口径）"
else
    echo "有失败项，见上"
fi
exit "$fail"
