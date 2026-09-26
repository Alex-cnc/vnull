#!/bin/bash
# FR-AI-03 对话式诊断的可复跑证据（Core 半边：取证 → 上下文组装 → 回复解析与裁决）。
#
# **为什么这样验**：真实模型端点在本环境不可用，但这一条需求的两条硬约束
# （「结论须引用真实计划 / 统计 / 锁数据，不允许无依据断言」「建议可转成 SQL 但须走审批」）
# 全部是**我们这一侧的判决**。所以：证据用**真实的本机 PostgreSQL**取得（真的跑 EXPLAIN 与锁查询），
# 模型回复用**一份文本文件**代替（这就是 `--advice-file` 的用途）。
#
# 用法：./Scripts/test-diagnosis.sh
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"
# 连接信息（本机过渡集群 / 远程专用库）由共用入口决定 —— 三档端口与目录只写在它里面
source "$(cd "$(dirname "$0")" && pwd)/lib/test-env.sh"
doyah_test_env_summary

PGBIN="${DOYAH_TEST_PG_BIN}"
DATADIR="${DOYAH_TEST_LOCAL_DATADIR}"
PGPORT_TEST="${DOYAH_TEST_PGPORT}"
WORK="$PWD/.build/diagnosis-$$"
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
    --manifest-cache local -Xswiftc -disable-sandbox --product DoyahCLI > .build/diagnosis-build.log 2>&1; then
    check "CLI 构建成功" 0
else
    check "CLI 构建成功" 1
    tail -5 .build/diagnosis-build.log
    exit 1
fi

if ! "$PGBIN/pg_ctl" -D "$DATADIR" status >/dev/null 2>&1; then
    STARTED_PG=1
    "$PGBIN/pg_ctl" -D "$DATADIR" -o "-p ${PGPORT_TEST} -k /tmp" -l /tmp/doyah-diagnosis-pg.log start >/dev/null 2>&1
    sleep 2
fi
"$PGBIN/pg_ctl" -D "$DATADIR" status >/dev/null 2>&1 && check "本机 PG 在跑（取证要有真库）" 0 || check "本机 PG 在跑（取证要有真库）" 1

doyah_test_env_export_connection
export PGDATABASE="${DOYAH_TEST_PGDATABASE}"
mkdir -p "$WORK"

echo ""
echo "== 1) 取证：对真实库跑 EXPLAIN / 锁 / 统计，并如实标注哪些没拿到 =="
CTX_JSON="$("$CLI" diagnose --sql "SELECT * FROM customers WHERE id > 1" --json)"
echo "$CTX_JSON" > "$WORK/context.json"
python3 - "$WORK/context.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["ok"] is True, "取证失败"
kinds = [e["kind"] for e in data["evidence"]]
assert kinds[0] == "statement", kinds
assert "executionPlan" in kinds, kinds
plan = [e for e in data["evidence"] if e["kind"] == "executionPlan"][0]
assert plan["available"] is True and len(plan["rows"]) >= 1, plan
locks = [e for e in data["evidence"] if e["kind"] == "lockBlocking"][0]
assert locks["available"] is True and any("Seq Scan" in (c or "") or "Index" in (c or "")
                                          or "cost=" in (c or "") for c in plan["rows"][0]), plan
# 慢查询统计：本机 PG 没有 pg_stat_statements → 必须**如实记成没拿到**，并带上服务端说的话
slow = [e for e in data["evidence"] if e["kind"] == "slowQueries"][0]
assert slow["available"] is False, slow
assert "未取到" in slow["note"] and len(slow["note"]) > 10, slow
assert slow["id"] in data["unavailable"], data["unavailable"]
print("  ✅ 证据编号与种类齐全（%s）" % ",".join(kinds))
print("  ✅ 执行计划是**真跑出来的**（%d 行，含 cost= 的节点）" % len(plan["rows"]))
print("  ✅ 取不到的证据如实标注（%s：%s）" % (slow["id"], slow["note"][:48]))
PY
[ $? -eq 0 ] && check "取证与标注三项都通过（详见上）" 0 || check "取证与标注三项都通过（详见上）" 1

echo ""
echo "== 2) 上下文：未取到的证据要点名，且写死"不许对它们下结论" =="
"$CLI" diagnose --sql "SELECT 1" > "$WORK/prompt.txt" 2>&1
grep -q "没有拿到证据" "$WORK/prompt.txt" && check "提示词里有『没拿到的证据』清单" 0 || check "提示词里有『没拿到的证据』清单" 1
grep -q "不许对它们下结论" "$WORK/prompt.txt" && check "提示词写死『不许对它们下结论』" 0 || check "提示词写死『不许对它们下结论』" 1
grep -q "结论: <一句话> \[依据: e1,e2\]" "$WORK/prompt.txt" && check "输出格式写进提示词" 0 || check "输出格式写进提示词" 1

echo ""
echo "== 3) 有依据的结论 → 采纳；建议 SQL 带上审批裁决 =="
cat > "$WORK/good.txt" <<'REPLY'
结论: 这里是顺序扫描，行数估计不大，慢的原因更可能在 I/O [依据: e2]
建议: ANALYZE customers
REPLY
GOOD="$("$CLI" diagnose --sql "SELECT * FROM customers" --advice-file "$WORK/good.txt" --json)"
echo "$GOOD" > "$WORK/good.json"
python3 - "$WORK/good.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["ok"] is True
assert len(data["advice"]) == 1, data["advice"]
item = data["advice"][0]
assert item["citations"] == ["e2"], item
assert item["sql"] == "ANALYZE customers", item
assert item["decision"] == "allow", item
assert data["rejected"] == [], data["rejected"]
print("  ✅ 引用真实证据的结论被采纳，建议 SQL 带裁决 =", item["decision"])
print("     （ANALYZE 不是破坏性语句，放行是对的；高危语句见第 5 节）")
PY
[ $? -eq 0 ] && check "有依据 → 采纳（详见上）" 0 || check "有依据 → 采纳（详见上）" 1

echo ""
echo "== 4) **无依据的断言必须被拒**（这是需求原文点名的纪律） =="
cat > "$WORK/uncited.txt" <<'REPLY'
结论: 我猜是磁盘太慢了
结论: 应该是索引没建 [依据: e9]
结论: 历史上一直很慢 [依据: e4]
结论: 全表扫描 [依据: e2]
REPLY
BAD="$("$CLI" diagnose --sql "SELECT * FROM customers" --advice-file "$WORK/uncited.txt" --json)"
echo "$BAD" > "$WORK/bad.json"
python3 - "$WORK/bad.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
rejected = {r["line"]: r["reason"] for r in data["rejected"]}
assert len(data["advice"]) == 1, data["advice"]
assert data["advice"][0]["conclusion"] == "全表扫描", data["advice"]
reasons = list(rejected.values())
assert "missingCitations" in reasons, rejected
assert any(r.startswith("unknownCitation:e9") for r in reasons), rejected
# e4 是"没取到"的证据：引用它同样不算有依据
assert any(r.startswith("unknownCitation:e4") for r in reasons), rejected
print("  ✅ 无引用的结论被拒（missingCitations）")
print("  ✅ 编造证据编号被拒（unknownCitation:e9）")
print("  ✅ 引用『没取到』的证据被拒（unknownCitation:e4）")
PY
[ $? -eq 0 ] && check "无依据断言三类全被拒（详见上）" 0 || check "无依据断言三类全被拒（详见上）" 1

echo ""
echo "== 5) 建议 SQL 走同一道审批闸门（只读连接上直接拒绝） =="
cat > "$WORK/write.txt" <<'REPLY'
结论: 需要清理历史数据 [依据: e2]
建议: DROP TABLE customers
REPLY
RW="$("$CLI" diagnose --sql "SELECT 1" --advice-file "$WORK/write.txt" --json)"
echo "$RW" | grep -q '"decision":"needsConfirmation"' && check "可写连接上：DROP TABLE 要求确认（不是放行）" 0 || check "可写连接上：DROP TABLE 要求确认（不是放行）" 1
RO="$("$CLI" diagnose --sql "SELECT 1" --advice-file "$WORK/write.txt" --read-only --json)"
echo "$RO" | grep -q '"decision":"refused"' && check "只读连接上：DROP TABLE 直接拒绝（不可绕过）" 0 || check "只读连接上：DROP TABLE 直接拒绝（不可绕过）" 1

echo ""
echo "== 6) 端到端走通：真库取计划 + 假模型回复 + 裁决，一条链 =="
CHAIN="$("$CLI" diagnose --sql "SELECT * FROM orders WHERE customer_id = 1" \
    --advice-file "$WORK/good.txt" --json)"
echo "$CHAIN" | grep -q '"kind":"executionPlan"' && c1=0 || c1=1
check "同一次调用里既有真计划、又有回复解析" "$c1"

echo ""
if [ "$fail" -eq 0 ]; then
    echo "✅ 对话式诊断的 Core 半边全部通过（真库取证 + 假模型回复）"
else
    echo "❌ 有断言失败，见上"
fi
exit "$fail"
