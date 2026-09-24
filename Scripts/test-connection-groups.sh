#!/bin/bash
# 验证：连接分组 / 文件夹（FR-CONN-15）。
#
# 需求原文点名的验收点只有两条，都能脚本化：
#   · `ConnectionConfig` 新增可选分组字段，**旧 connections.json 仍可解码**
#   · 侧边栏按组组织 —— 分组顺序与组内顺序由 Core 定，这里断言那个顺序
# 界面折叠是人工项（写进需求行的待人工）。
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"
DIR="$(mktemp -d -t doyah-groups)"

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }
cleanup() { rm -rf "$DIR"; }
trap cleanup EXIT

cat > "$DIR/connections.json" <<'JSON'
[
 {"id":"11111111-1111-1111-1111-111111111111","name":"订单库","host":"10.0.0.5","database":"orders",
  "username":"app","schemaVersion":1,"group":"生产环境"},
 {"id":"22222222-2222-2222-2222-222222222222","name":"报表库","host":"10.0.0.6","database":"report",
  "username":"app","schemaVersion":1,"group":"生产环境"},
 {"id":"33333333-3333-3333-3333-333333333333","name":"沙箱","host":"10.0.0.7","database":"sandbox",
  "username":"dev","schemaVersion":1,"group":"开发"},
 {"id":"44444444-4444-4444-4444-444444444444","name":"临时连的","host":"10.0.0.8","database":"tmp",
  "username":"dev","schemaVersion":1,"group":"   "},
 {"id":"55555555-5555-5555-5555-555555555555","name":"老配置","host":"10.0.0.9","database":"legacy",
  "username":"old","schemaVersion":1}
]
JSON

echo "== 1) 旧配置（无 group 字段）照常解码为未分组，且文件不被改写 =="
OUT="$("$CLI" connections --dir "$DIR" 2>&1)"
echo "$OUT" | sed 's/^/  /'
echo "$OUT" | grep -q "老配置.*组=—" && check "老配置读出为未分组（不是报错、也不是瞎猜一个组）" 0 || check "老配置应读出为未分组" 1
echo "$OUT" | grep -q "临时连的.*组=—" && check "只有空白的组名归一为未分组" 0 || check "空白组名应为未分组" 1
python3 - "$DIR/connections.json" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
legacy = [item for item in data if item["name"] == "老配置"][0]
assert legacy.get("schemaVersion") == 1
assert "group" not in legacy, legacy
print("  ✅ 老配置条目原样保留（没有凭空写入 group 字段）")
PY
[ $? -eq 0 ] || fail=1

echo ""
echo "== 2) 分组视图：按组归并，未分组永远最后 =="
BY="$("$CLI" connections --dir "$DIR" --by-group 2>&1)"
echo "$BY" | sed 's/^/  /'
echo "$BY" | grep -q "分组：3 组 / 5 条连接" && check "3 个命名组 + 未分组（共 5 条连接）" 0 || check "分组数应为 3" 1
echo "$BY" | grep -q "生产环境（2）" && check "同组的两条连接归到一组" 0 || check "生产环境应含 2 条" 1
# 未分组必须在最后一行块：取最后一行的组标题
LAST_TITLE="$("$CLI" connections --dir "$DIR" --by-group 2>/dev/null | grep -v "分组：" | grep -v "^    " | tail -1)"
echo "$LAST_TITLE" | grep -q "未分组" && check "未分组排在最后（不是夹在中间）" 0 || { check "未分组应在最后（实际 $LAST_TITLE）" 1; }

echo ""
echo "== 3) 组内顺序保持传入顺序（不按名字重排）=="
ORDER="$("$CLI" connections --dir "$DIR" --by-group 2>/dev/null | grep -A2 "生产环境（2）" | grep "^    " | sed 's/^ *//' | cut -f1)"
FIRST="$(echo "$ORDER" | head -1)"
[ "$FIRST" = "订单库" ] && check "组内保持文件里的先后（订单库在报表库之前）" 0 || { check "组内顺序应保持传入顺序（首个=$FIRST）" 1; }

echo ""
echo "== 4) 确定性：同一目录两次分组输出逐字一致 =="
A="$("$CLI" connections --dir "$DIR" --by-group 2>&1)"
B="$("$CLI" connections --dir "$DIR" --by-group 2>&1)"
[ "$A" = "$B" ] && check "两次输出完全一致" 0 || check "输出应确定" 1

echo ""
if [ "$fail" -eq 0 ]; then
    echo "通过：老配置（无 group）解码为未分组且文件不改写 / 空白组名归一 / 分组归并与未分组最后 /"
    echo "      组内保持传入顺序 / 输出确定"
    echo "（**边界**：侧边栏的折叠交互仍需人工点；本脚本验的是分组聚合与配置兼容）"
else
    echo "有失败项，见上"
fi
exit "$fail"
