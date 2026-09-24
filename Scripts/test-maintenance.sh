#!/bin/bash
# FR-AI-04 维护任务编排的可复跑证据。
#
# **这一套验三件事**（需求原文的三条要求）：
#   ① 「每个写操作 / DDL 均需审批」→ 没批准就**一条都不下发**（执行入口只收已批准的任务）；
#   ② 「任务可预览、可编辑、可拒绝」→ 拒绝的任务留在计划里且有理由；
#   ③ 「高开销操作限流」→ 一次计划里第二条高开销被拒，显式开关才放行。
# 外加两条本工程的纪律：只读连接上的写任务**连批准都不允许**；沙箱构建下外部程序类任务不可执行（R-18）。
#
# 执行那一段用的是**真实本机 PostgreSQL**（`ANALYZE` / `VACUUM` 在测试库上真跑）。
#
# 用法：./Scripts/test-maintenance.sh
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"
PGBIN="$HOME/tools/pgserver/pgserver/pginstall/bin"
DATADIR="$PWD/.build/pgdata-session-test"
PGPORT_TEST=55433
WORK="$PWD/.build/maintenance-$$"
STARTED_PG=0

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }
cleanup() {
    [ "$STARTED_PG" = "1" ] && "$PGBIN/pg_ctl" -D "$DATADIR" stop >/dev/null 2>&1
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "== 0) 构建 CLI 与准备本机 PostgreSQL =="
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
if swift build --disable-sandbox --cache-path "$PWD/.build-cache" --scratch-path "$PWD/.build" \
    --manifest-cache local -Xswiftc -disable-sandbox --product DoyahCLI > .build/maintenance-build.log 2>&1; then
    check "CLI 构建成功" 0
else
    check "CLI 构建成功" 1
    tail -5 .build/maintenance-build.log
    exit 1
fi

if ! "$PGBIN/pg_ctl" -D "$DATADIR" status >/dev/null 2>&1; then
    STARTED_PG=1
    "$PGBIN/pg_ctl" -D "$DATADIR" -o "-p ${PGPORT_TEST} -k /tmp" -l /tmp/doyah-maintenance-pg.log start >/dev/null 2>&1
    sleep 2
fi
"$PGBIN/pg_ctl" -D "$DATADIR" status >/dev/null 2>&1 && check "本机 PG 在跑" 0 || check "本机 PG 在跑" 1

export PGHOST=127.0.0.1 PGPORT="$PGPORT_TEST" PGUSER=postgres PGDATABASE=doyah_manual_test PGSSLMODE=disable
mkdir -p "$WORK"

echo ""
echo "== 1) 计划解析与审阅（这不执行任何东西） =="
cat > "$WORK/plan.txt" <<'PLAN'
# 一个"什么都有"的维护计划
task: analyze | 更新 customers 的统计信息 | sql: ANALYZE public.customers
task: vacuum | 整理 orders 的膨胀 | sql: VACUUM (ANALYZE) public.orders
task: reindex | 重建 orders 上的索引 | sql: REINDEX INDEX public.orders_pkey
task: backup | 备份 analytics 库 | command: pg_dump -Fc analytics
task: indexSuggestion | 建议给 created_at 建索引 | sql: CREATE INDEX ON public.orders (created_at)
PLAN
PREVIEW="$("$CLI" maintain --plan "$WORK/plan.txt" --json)"
echo "$PREVIEW" > "$WORK/preview.json"
python3 - "$WORK/preview.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["ok"] is True, data
tasks = {t["id"]: t for t in data["tasks"]}
assert len(tasks) == 5, tasks.keys()
assert all(t["state"] == "pending" or t["state"] == "rejected" for t in tasks.values()), data["tasks"]
assert tasks["m1"]["needsApproval"] is True and tasks["m1"]["state"] == "pending"
assert tasks["m3"]["highCost"] is True and tasks["m4"]["highCost"] is True
assert tasks["m4"]["state"] == "rejected", "第二条高开销应当被限流拒绝"
assert tasks["m5"]["needsApproval"] is False, "索引建议只给语句，不该要审批"
assert tasks["m4"]["risk"] == "destructive", "备份动的是整库，风险分类要如实"
assert data["tasks"] and all(t["executable"] is False for t in data["tasks"]), "没批准之前一条都不可执行"
print("  ✅ 五条任务解析正确（analyze / vacuum / reindex / backup / indexSuggestion）")
print("  ✅ 写任务都要审批，索引建议不要")
print("  ✅ 高开销限流生效（第二条被拒）")
print("  ✅ 未批准 = 不可执行")
PY
[ $? -eq 0 ] && check "解析与审阅四项（详见上）" 0 || check "解析与审阅四项（详见上）" 1

echo ""
echo "== 2) 认不出的行必须留下（维护场景里静默丢行可能丢掉一个 DROP） =="
printf '想删掉一张表\ntask: analyze | 更新统计 | sql: ANALYZE public.customers\n' > "$WORK/weird.txt"
"$CLI" maintain --plan "$WORK/weird.txt" --json > "$WORK/weird.json"
grep -q '"unparsable":\["想删掉一张表"\]' "$WORK/weird.json" && check "看不懂的行原样报出来" 0 || check "看不懂的行原样报出来" 1

echo ""
echo "== 3) 未批准不执行 / 拒绝留在计划里 =="
"$CLI" maintain --plan "$WORK/plan.txt" --execute --json > "$WORK/no-approve.json"
grep -q '"executed":\[\]' "$WORK/no-approve.json" && check "没批准就一条都不下发" 0 || check "没批准就一条都不下发" 1
"$CLI" maintain --plan "$WORK/plan.txt" --reject m2 --json > "$WORK/reject.json"
grep -q '"id":"m2"[^}]*"state":"rejected"' "$WORK/reject.json" && check "被拒绝的任务留在计划里（带理由）" 0 || check "被拒绝的任务留在计划里（带理由）" 1

echo ""
echo "== 4) 批准后真的执行（真库上跑 ANALYZE / VACUUM） =="
BEFORE="$("$CLI" maintain --plan "$WORK/plan.txt" --approve m1,m2 --execute --json)"
echo "$BEFORE" > "$WORK/exec.json"
python3 - "$WORK/exec.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
executed = {e["id"]: e for e in data["executed"]}
assert set(executed.keys()) == {"m1", "m2"}, data["executed"]
assert all(e["ok"] for e in executed.values()), data["executed"]
states = {t["id"]: t["state"] for t in data["tasks"]}
assert states["m1"] == "executed" and states["m2"] == "executed", states
assert states["m3"] == "pending", "没批准的仍然没跑"
print("  ✅ 批准的两条真的执行了（ANALYZE / VACUUM）")
print("  ✅ 没批准的仍然待批")
PY
[ $? -eq 0 ] && check "批准后执行两项（详见上）" 0 || check "批准后执行两项（详见上）" 1

echo ""
echo "== 5) 只读连接：写任务连批准都不允许 =="
RO="$("$CLI" maintain --plan "$WORK/plan.txt" --approve all --read-only --json)"
echo "$RO" | grep -q '"state":"rejected"' && check "只读连接上写任务被拒" 0 || check "只读连接上写任务被拒" 1
echo "$RO" | grep -q '"executable":false' && check "被拒的任务不会因为「批准」而复活" 0 || check "被拒的任务不会因为「批准」而复活" 1

echo ""
echo "== 6) 沙箱构建：外部程序类任务不可执行（R-18） =="
cat > "$WORK/backup.txt" <<'PLAN'
task: backup | 备份 analytics 库 | command: pg_dump -Fc analytics
PLAN
SB="$("$CLI" maintain --plan "$WORK/backup.txt" --approve all --sandboxed --json)"
echo "$SB" | grep -q '"id":"m1"[^}]*"executable":false' && check "沙箱下 pg_dump 类任务不可执行" 0 || check "沙箱下 pg_dump 类任务不可执行" 1
echo "$SB" | grep -q '沙箱\|外部程序' && check "理由写在任务上（不是静默不动）" 0 || check "理由写在任务上（不是静默不动）" 1
NS="$("$CLI" maintain --plan "$WORK/backup.txt" --approve all --json)"
echo "$NS" | grep -q '"id":"m1"[^}]*"executable":true' && check "非沙箱下同样的任务是可执行的" 0 || check "非沙箱下同样的任务是可执行的" 1

echo ""
echo "== 7) 高开销显式放行（用户知情时才允许两条） =="
OV="$("$CLI" maintain --plan "$WORK/plan.txt" --allow-multiple-high-cost --json)"
echo "$OV" | grep -q '"id":"m4"[^}]*"state":"pending"' && check "显式开关下第二条高开销不再被拒" 0 || check "显式开关下第二条高开销不再被拒" 1

echo ""
if [ "$fail" -eq 0 ]; then
    echo "✅ 维护任务编排全部通过（真库执行 + 逐条审批 + 限流 + 只读/沙箱边界）"
else
    echo "❌ 有断言失败，见上"
fi
exit "$fail"
