#!/bin/bash
# 验证：specs 版本化、diff、回滚与重跑语义（FR-AI-11）。
#
# 这一项的三个危险点都能脚本化：
#   · 历史是否**只追加**（可被改写的历史不叫历史）
#   · 回滚是不是"把旧内容再存一次"（那样"曾经回滚过"也留在历史里）
#   · 重跑语义是否与任务声明的写入模式**一致**（不一致时幂等承诺就是空话）
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"
DIR="$(mktemp -d -t doyah-specs)"
TASK_ID="11111111-1111-1111-1111-111111111111"

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }
cleanup() { rm -rf "$DIR"; }
trap cleanup EXIT

task_json() { # task_json <文件> <名称> <规格> <写入模式>
cat > "$1" <<JSON
{"id":"${TASK_ID}","name":"$2","specs":"$3",
 "source":{"table":"orders","columns":[]},
 "transformations":[],
 "target":{"table":"summary","writeMode":"$4","keyColumns":[]},
 "schedule":{"kind":"manual"},
 "isEnabled":true,
 "createdAt":"2026-09-23T09:00:00Z","updatedAt":"2026-09-23T09:00:00Z"}
JSON
}

echo "== 1) 保存即记版本；内容没变不记新版本 =="
task_json "$DIR/v1.json" "夜间汇总" "把订单按天汇总" append
task_json "$DIR/v2.json" "夜间汇总（按小时）" "把订单按小时汇总" append
"$CLI" specs --dir "$DIR" --save "$DIR/v1.json" 2>&1 | sed 's/^/  /'
"$CLI" specs --dir "$DIR" --save "$DIR/v2.json" >/dev/null 2>&1
"$CLI" specs --dir "$DIR" --save "$DIR/v2.json" >/dev/null 2>&1   # 同一内容再存
HIST="$("$CLI" specs --dir "$DIR" --task "$TASK_ID" --history 2>&1)"
echo "$HIST" | sed 's/^/  /'
echo "$HIST" | grep -q "共 2 个版本" && check "两次改动 → 2 个版本（重复保存不记新版）" 0 || check "版本数应为 2" 1
echo "$HIST" | grep -q "v1" && echo "$HIST" | grep -q "v2" && check "历史里 v1 / v2 都在" 0 || check "历史应含 v1 与 v2" 1

echo ""
echo "== 2) diff 指出改了什么（字段级，顺序稳定）=="
DIFF="$("$CLI" specs --dir "$DIR" --task "$TASK_ID" --diff 1 2 2>&1)"
echo "$DIFF" | sed 's/^/  /'
echo "$DIFF" | grep -q "名称" && check "diff 指出名称改动" 0 || check "diff 应含名称" 1
echo "$DIFF" | grep -q "规格说明" && check "diff 指出规格说明改动" 0 || check "diff 应含规格说明" 1
"$CLI" specs --dir "$DIR" --task "$TASK_ID" --diff 1 1 >/dev/null 2>&1
[ $? -eq 1 ] && check "同一版本无差异 → 返回非零（不假装有改动）" 0 || check "无差异应返回非零" 1

echo ""
echo "== 3) 回滚：把旧内容**再存一次**（历史留痕，旧版本仍可查）=="
FIRST_LINE_BEFORE="$(head -1 "$DIR/task-versions.jsonl")"
"$CLI" specs --dir "$DIR" --task "$TASK_ID" --rollback 1 2>&1 | sed 's/^/  /'
HIST2="$("$CLI" specs --dir "$DIR" --task "$TASK_ID" --history 2>&1)"
echo "$HIST2" | sed 's/^/  /'
echo "$HIST2" | grep -q "共 3 个版本" && check "回滚产生第 3 个版本（不是删掉第 2 个）" 0 || check "回滚应记新版本" 1
# 用 python 读 JSON：文件是**美化过**的（`"name" : "…"` 带空格），
# 用 sed 猜格式会取到空串 —— 解析结构化数据就别用正则（这坑我踩过）
CURRENT_NAME="$(python3 -c '
import json, sys
tasks = json.load(open(sys.argv[1], encoding="utf-8"))
print(tasks[0]["name"] if tasks else "")
' "$DIR/data-tasks.json")"
[ "$CURRENT_NAME" = "夜间汇总" ] && check "当前定义已回到 v1 的内容" 0 || { check "回滚后当前定义应为 v1（实际 ${CURRENT_NAME}）" 1; }
[ "$(head -1 "$DIR/task-versions.jsonl")" = "$FIRST_LINE_BEFORE" ] && check "历史文件只追加：首行逐字未变" 0 || check "历史首行不该被改写" 1

echo ""
echo "== 4) 重跑语义：必须显式选，且要与任务声明的写入模式一致 =="
APPEND="$("$CLI" specs --rerun-mode append --task-file "$DIR/v1.json" 2>&1)"; A_CODE=$?
echo "$APPEND" | sed 's/^/  /'
[ "$A_CODE" -eq 0 ] && check "追加语义：允许（与任务声明的 append 一致）" 0 || check "追加应允许" 1
echo "$APPEND" | grep -q "重复数据" && check "追加语义提醒会产生重复数据" 0 || check "应提醒重复数据" 1

MISMATCH="$("$CLI" specs --rerun-mode overwrite --task-file "$DIR/v1.json" 2>&1)"; M_CODE=$?
echo "$MISMATCH" | sed 's/^/  /'
[ "$M_CODE" -eq 3 ] && check "覆盖语义与任务声明的 append **不一致 → 阻止**" 0 || check "不一致时应阻止" 1
echo "$MISMATCH" | grep -q "不一致" && check "阻止理由说明是不一致" 0 || check "理由应说明不一致" 1

RESUME="$("$CLI" specs --rerun-mode resume --task-file "$DIR/v1.json" 2>&1)"
echo "$RESUME" | grep -q "进度" && check "断点续跑提醒需要进度标记" 0 || check "应提醒进度标记" 1
"$CLI" specs --rerun-mode nonsense >/dev/null 2>&1
[ $? -eq 64 ] && check "未知语义被拒绝（退出码 64）" 0 || check "未知语义应被拒" 1

echo ""
if [ "$fail" -eq 0 ]; then
    echo "通过：保存自动记版本且重复保存不记 / diff 字段级且无差异返回非零 /"
    echo "      回滚以新版本留痕且历史只追加 / 重跑语义显式选并与任务写入模式对齐"
    echo "（**边界**：界面里的历史列表与回滚按钮仍需人工点；本脚本验的是历史与语义）"
else
    echo "有失败项，见上"
fi
exit "$fail"
