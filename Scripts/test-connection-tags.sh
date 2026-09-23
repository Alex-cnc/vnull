#!/bin/bash
# 验证：连接环境标签与颜色（FR-CONN-16）。
#
# 界面着色没法脚本化，但**"标签真的存下来、读得回来、安全联动生效"**可以：
# 用配置文件 + CLI 出口把这三件事都验一遍，安全联动由 12 项单测覆盖。
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"
DIR="$(mktemp -d -t doyah-connections)"

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }
cleanup() { rm -rf "$DIR"; }
trap cleanup EXIT

echo "== 1) 老配置（没有标签字段）必须照常读出来 =="
cat > "$DIR/connections.json" <<'JSON'
[{"id":"D264B21B-1880-4E73-A2D0-59A3F8E4D7EC","name":"老配置","host":"192.168.5.217",
  "database":"zxvmax","username":"zxvmax","schemaVersion":1}]
JSON
OUT="$("$CLI" connections --dir "$DIR" 2>&1)"
echo "$OUT" | sed 's/^/  /'
echo "$OUT" | grep -q "环境=—" && check "老配置读出为「未标记」（不是报错、也不是瞎猜成生产）" 0 || check "老配置读取" 1
# 关键：纯新增的可选字段**不该**让文件被当成"来自更新版本"或触发迁移
python3 - "$DIR/connections.json" <<'PY'
import json, sys, pathlib
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert data[0].get("schemaVersion") == 1, data[0].get("schemaVersion")
assert "environment" not in data[0], "没有标签就不该凭读写凭空写进去"
PY
[ $? -eq 0 ] && check "老文件未被改写（schemaVersion 仍是 1、没有凭空加字段）" 0 || check "老文件不该被改写" 1

echo ""
echo "== 2) 带标签的配置：读得回来，且名字 / 地址都在 =="
cat > "$DIR/connections.json" <<'JSON'
[
 {"id":"11111111-1111-1111-1111-111111111111","name":"生产订单库","host":"10.0.0.5","port":5432,
  "database":"orders","username":"app","schemaVersion":1,"environment":"production","colorTag":"magenta"},
 {"id":"22222222-2222-2222-2222-222222222222","name":"预发","host":"10.0.0.6","port":5432,
  "database":"orders","username":"app","schemaVersion":1,"environment":"staging"},
 {"id":"33333333-3333-3333-3333-333333333333","name":"本地","host":"127.0.0.1","port":5432,
  "database":"dev","username":"dev","schemaVersion":1,"colorTag":"teal"}
]
JSON
OUT2="$("$CLI" connections --dir "$DIR" 2>&1)"
echo "$OUT2" | sed 's/^/  /'
echo "$OUT2" | grep -q "生产订单库.*环境=production.*颜色=magenta" && check "生产标签与自选色都读回来了" 0 \
    || check "生产标签读取" 1
echo "$OUT2" | grep -q "预发.*环境=staging" && check "预发标签读回来（颜色留空 = 跟随环境色）" 0 || check "预发标签" 1
echo "$OUT2" | grep -q "本地.*环境=—.*颜色=teal" && check "只设了颜色、没设环境也能存" 0 || check "仅颜色" 1

echo ""
echo "== 3) JSON 出口可用于外部核对（字段名稳定）=="
JSON_OUT="$("$CLI" connections --dir "$DIR" --json 2>&1)"
echo "$JSON_OUT" | grep -q '"environment" : "production"' && check "JSON 里 environment 字段名与取值稳定" 0 \
    || { check "JSON 字段" 1; echo "$JSON_OUT" | head -8; }
echo "$JSON_OUT" | grep -q '"colorTag" : "magenta"' && check "JSON 里 colorTag 按名字存（不是色值）" 0 || check "JSON 颜色字段" 1

echo ""
echo "== 4) 真实应用配置目录仍然读得出来（改动没有破坏现状）=="
REAL="$("$CLI" connections 2>&1)"
REAL_CODE=$?
echo "$REAL" | head -3 | sed 's/^/  /'
[ "$REAL_CODE" -eq 0 ] && check "应用数据目录的连接配置可读（退出码 0）" 0 || { check "真实目录读取" 1; echo "$REAL" | tail -3; }

echo ""
echo "== 5) 安全联动（单测覆盖，这里只做存在性核对）=="
grep -q "forcesConfirmationForHighRisk" Core/ExecutionSafety.swift \
    && check "ExecutionSafetyPolicy 有生产强制确认位" 0 || check "强制确认位" 1
grep -q "ExecutionSafetyPolicy.policy(" App/AppState.swift \
    && check "AppState 的执行策略确实按连接外观推导（不是只加了字段没人用）" 0 || check "策略未接线" 1

echo ""
if [ "$fail" -eq 0 ]; then
    echo "通过：标签与颜色持久化正确、老配置不受影响、JSON 出口稳定、安全联动已接线"
    echo "（界面着色与徽标是否到处一致，需人工看一眼 —— 已写进需求行的待人工项）"
else
    echo "有失败项，见上"
fi
exit "$fail"
