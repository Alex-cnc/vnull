#!/bin/bash
# 验证：参数化与技能候选（FR-AI-14）。
#
# 事实源仍是归档 `.sql` 文件；这里用**产品自己的 CLI**（archive-add 造现场、memory 读结论），
# 逐项核对四条判据 —— 关键是**每条判据都要单独验一次**：只验"全都满足时出候选"是不够的，
# 那样任何一条判据失效都看不出来。
#
# 四条判据（全部满足才升格）：
#   1. 跨天频次 runCount >= 5
#   2. 跨越天数 days >= 3
#   3. 时刻集中度：3 小时滚动窗口内占比 >= 60%
#   4. 只改参数：>= 2 条不同原文，且都能被同一模板逐字还原
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build-ai14/debug/DoyahCLI"
[ -x "$CLI" ] || CLI=".build/debug/DoyahCLI"

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }

ROOT_DIR="$(mktemp -d -t doyah-routine)"
cleanup() { rm -rf "$ROOT_DIR"; }
trap cleanup EXIT

add() { # add <目录> <sql> <runs> <时刻>
    "$CLI" archive-add --dir "$1" --sql "$2" --connection 生产库 --runs "$3" --at "$4" >/dev/null
}

PAID="SELECT count(*) FROM orders WHERE status = 'paid'"
REFUNDED="SELECT count(*) FROM orders WHERE status = 'refunded'"

# ── 现场 A：四条齐全（五天、集中在上下午 9~11 点、两个取值）──
A="$ROOT_DIR/a"; mkdir -p "$A"
add "$A" "$PAID"     3 2026-09-21T09:00:00Z
add "$A" "$REFUNDED" 2 2026-09-22T10:00:00Z
add "$A" "$PAID"     3 2026-09-23T11:00:00Z
add "$A" "$REFUNDED" 2 2026-09-24T09:30:00Z
add "$A" "$PAID"     2 2026-09-25T10:30:00Z

echo "== 1) 四条齐全 → 是候选，并给出参数模板与槽位样例 =="
OUT="$("$CLI" memory --dir "$A" --routines 2>&1)"
echo "$OUT" | head -8 | sed 's/^/  /'
echo "$OUT" | grep -q "例行候选：1 条" && check "四条齐全 → 1 条候选" 0 || check "应给出 1 条候选" 1
echo "$OUT" | grep -q "status = ?" && check "模板里字面量变成槽位 ?" 0 || check "模板应含槽位" 1
echo "$OUT" | grep -q "槽位 1 样例" && check "给出槽位取值样例" 0 || check "应有槽位样例" 1

echo ""
echo "== 2) 逐条否掉：每条判据都要单独起作用 =="

# 2a 只差「跨天频次」：4 次（< 5），其余齐全
B="$ROOT_DIR/b"; mkdir -p "$B"
add "$B" "$PAID"     1 2026-09-21T09:00:00Z
add "$B" "$REFUNDED" 1 2026-09-22T10:00:00Z
add "$B" "$PAID"     1 2026-09-23T11:00:00Z
add "$B" "$REFUNDED" 1 2026-09-24T09:30:00Z
BOUT="$("$CLI" memory --dir "$B" --routines 2>&1)"
echo "$BOUT" | grep -q "跨天频次 4 < 5" && check "只差频次 → 给出「跨天频次 4 < 5」" 0 || { check "频次判据" 1; echo "$BOUT" | tail -3; }
echo "$BOUT" | grep -q "例行候选：0 条" && check "只差频次 → 不是候选" 0 || check "只差频次不该成为候选" 1

# 2b 只差「跨越天数」：12 次但集中在 2 天
C="$ROOT_DIR/c"; mkdir -p "$C"
add "$C" "$PAID"     3 2026-09-21T09:00:00Z
add "$C" "$REFUNDED" 3 2026-09-21T10:00:00Z
add "$C" "$PAID"     3 2026-09-22T09:30:00Z
add "$C" "$REFUNDED" 3 2026-09-22T10:30:00Z
COUT="$("$CLI" memory --dir "$C" --routines 2>&1)"
echo "$COUT" | grep -q "跨越天数 2 < 3" && check "只差天数 → 给出「跨越天数 2 < 3」" 0 || { check "天数判据" 1; echo "$COUT" | tail -3; }

# 2c 只差「时刻集中度」：摊平在一天里 12 个不同小时
D="$ROOT_DIR/d"; mkdir -p "$D"
for h in 00 02 04 06 08 10 12 14 16 18 20 22; do
    sql="$PAID"; [ $((10#$h % 4)) -eq 0 ] && sql="$REFUNDED"
    add "$D" "$sql" 1 "2026-09-2$((10#$h / 6 + 1))T${h}:00:00Z"
done
DOUT="$("$CLI" memory --dir "$D" --routines 2>&1)"
echo "$DOUT" | grep -q "时刻集中度" && check "只差集中度 → 给出「时刻集中度 …% < 60%」" 0 || { check "集中度判据" 1; echo "$DOUT" | tail -3; }

# 2d 只差「只改参数」：单条原文重复执行（不是参数化，只是重复）
E="$ROOT_DIR/e"; mkdir -p "$E"
for d in 21 22 23 24 25; do add "$E" "$PAID" 3 "2026-09-${d}T09:0$((10#$d - 21)):00Z"; done
EOUT="$("$CLI" memory --dir "$E" --routines 2>&1)"
echo "$EOUT" | grep -q "只改参数" && check "单条原文重复 → 给出「只改参数」未达标" 0 || { check "只改参数判据" 1; echo "$EOUT" | tail -3; }

echo ""
echo "== 3) 一次性排障脚本（单日、单时刻、多取值）不该被升格 =="
F="$ROOT_DIR/f"; mkdir -p "$F"
add "$F" "$PAID"     3 2026-09-21T03:00:00Z
add "$F" "$REFUNDED" 3 2026-09-21T03:10:00Z
FOUT="$("$CLI" memory --dir "$F" --routines 2>&1)"
echo "$FOUT" | tail -2 | sed 's/^/  /'
echo "$FOUT" | grep -q "例行候选：0 条" && check "排障现场不是候选（由统计判据本身挡住）" 0 || check "排障现场不该升格" 1

echo ""
echo "== 4) 人工否决：长期生效（跨进程）=="
FP="$("$CLI" memory --dir "$A" --routines --json 2>&1 | python3 -c 'import json,sys; t=sys.stdin.read(); print(json.loads(t[t.index("{"):])["candidates"][0]["fingerprint"])')"
echo "  指纹：$FP"
"$CLI" memory --dir "$A" --veto "$FP" >/dev/null 2>&1
VOUT="$("$CLI" memory --dir "$A" --routines --json 2>&1)"
echo "$VOUT" | python3 -c '
import json, sys
text = sys.stdin.read()
payload = json.loads(text[text.index("{"):])
assert payload["candidates"] == [], "否决后不该再出现候选"
assert payload["vetoed"], "但要如实报告被否决的指纹"
print("  ✅ 否决后候选为空，且报告里列出被否决项")
' || fail=1
"$CLI" memory --dir "$A" --unveto "$FP" >/dev/null 2>&1
UOUT="$("$CLI" memory --dir "$A" --routines 2>&1)"
echo "$UOUT" | grep -q "例行候选：1 条" && check "取消否决后候选恢复" 0 || check "取消否决应恢复" 1

echo ""
echo "== 5) 保留字面量：模板改回字面量，但频次与聚类不变 =="
"$CLI" memory --dir "$A" --keep-literal "$FP" "'refunded'" >/dev/null 2>&1
KOUT="$("$CLI" memory --dir "$A" --routines --json 2>&1)"
echo "$KOUT" | python3 -c '
import json, sys
text = sys.stdin.read()
payload = json.loads(text[text.index("{"):])
candidate = payload["candidates"][0]
assert "status = \u0027refunded\u0027" in candidate["template"], candidate["template"]
assert candidate["runs"] == 12, candidate["runs"]
assert candidate["days"] == 5, candidate["days"]
assert candidate["variants"] == 2, candidate["variants"]
print("  ✅ 模板里该槽位变回 \u0027refunded\u0027，且次数/天数/变体数不变（只改渲染）")
' || fail=1

echo ""
echo "== 6) 确定性：同一目录两次运行逐字一致 =="
R1="$("$CLI" memory --dir "$A" --routines --json 2>&1)"
R2="$("$CLI" memory --dir "$A" --routines --json 2>&1)"
[ "$R1" = "$R2" ] && check "两次 --routines 输出完全一致" 0 || { check "输出应确定" 1; diff <(echo "$R1") <(echo "$R2") | head -5; }

echo ""
echo "== 7) 只产建议、无副作用 =="
# 评估本身只读：目录里除归档与（人显式写下的）决定文件外，不该多出任何东西
BEFORE="$(ls "$A" | grep -v '^memory-decisions.json$' | sort)"
"$CLI" memory --dir "$A" --routines >/dev/null 2>&1
AFTER="$(ls "$A" | grep -v '^memory-decisions.json$' | sort)"
[ "$BEFORE" = "$AFTER" ] && check "评估不产生任何新文件（只有归档与决定文件）" 0 || { check "评估应无副作用" 1; diff <(echo "$BEFORE") <(echo "$AFTER"); }
# 决定文件里只有人显式做的两类动作
python3 - "$A/memory-decisions.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
assert set(payload) == {"vetoedFingerprints", "keptLiterals"}, payload
print('  ✅ 决定文件只含否决与保留字面量两类（没有顺手建任务这类副作用）')
PY
[ $? -eq 0 ] || fail=1

echo ""
if [ "$fail" -eq 0 ]; then
    echo "通过：四条判据逐条生效（各单独否掉一次）/ 排障脚本不被升格 / 否决跨进程生效 / 保留字面量只改渲染 / 输出确定 / 无副作用"
else
    echo "有失败项，见上"
fi
exit "$fail"
