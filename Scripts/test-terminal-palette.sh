#!/bin/bash
# 终端配色的可复跑证据（FR-EDIT-29）。
#
# 验三件事：
#   ① 两套色板（深 / 浅）都在，且**每个当正文用的槽位对底色 ≥ 4.5**（WCAG AA）；
#      这一条由脚本**独立于单测重算一遍** —— 单测用 Swift 算、脚本用 CLI 的 JSON 输出算，
#      两份实现都要给出同一结论，才算"这条门槛真的成立"。
#   ② 前景对底色 ≥ 7、选中底上的字 ≥ 7、光标对底色 ≥ 3。
#   ③ 单测门槛（色差可区分性、属性语义）全过。
#
# 用法：./Scripts/test-terminal-palette.sh
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }

echo "== 0) 构建 CLI =="
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
if swift build --disable-sandbox --cache-path "$PWD/.build-cache" --scratch-path "$PWD/.build" \
    --manifest-cache local -Xswiftc -disable-sandbox --product DoyahCLI > /tmp/terminal-palette-build.log 2>&1; then
    check "CLI 构建成功" 0
else
    check "CLI 构建成功" 1
    tail -5 /tmp/terminal-palette-build.log
    exit 1
fi

echo ""
echo "== 1) 色板本身（深 / 浅两套）=="
"$CLI" terminal-palette > /tmp/terminal-palette.txt 2>&1
check "terminal-palette 输出了色板" $?
grep -q "深海·夜" /tmp/terminal-palette.txt && check "深色色板在输出里" 0 || check "深色色板在输出里" 1
grep -q "深海·昼" /tmp/terminal-palette.txt && check "浅色色板在输出里" 0 || check "浅色色板在输出里" 1

echo ""
echo "== 2) 独立复算门槛（读 CLI 的 JSON，不看单测结论）=="
"$CLI" terminal-palette --json > /tmp/terminal-palette.json 2>&1
check "terminal-palette --json 可用" $?

python3 - <<'PY' > /tmp/terminal-palette-check.txt 2>&1
import json
data = json.load(open('/tmp/terminal-palette.json'))
problems = []
for palette in data:
    name = palette['name']
    if palette['foregroundContrast'] < 7.0:
        problems.append(f"{name}: 前景对底色只有 {palette['foregroundContrast']}")
    for slot in palette['ansi']:
        if slot['backgroundSlot']:
            continue
        if slot['contrast'] < 4.5:
            problems.append(f"{name}: 槽位 {slot['index']}（{slot['name']}）对底色只有 {slot['contrast']}")
print("OK" if not problems else "FAIL")
for problem in problems:
    print("  " + problem)
PY
if grep -q "^OK$" /tmp/terminal-palette-check.txt; then
    check "两套色板的正文槽位全部 ≥ 4.5、前景 ≥ 7" 0
else
    check "两套色板的正文槽位全部 ≥ 4.5、前景 ≥ 7" 1
    cat /tmp/terminal-palette-check.txt
fi

echo ""
echo "== 3) 自动化门槛（单测）=="
if swift test --disable-sandbox --cache-path "$PWD/.build-cache" --scratch-path "$PWD/.build" \
    --manifest-cache local -Xswiftc -disable-sandbox \
    --filter 'TerminalPaletteTests|TerminalDimAttributeTests' > /tmp/terminal-palette-tests.log 2>&1; then
    check "TerminalPaletteTests / TerminalDimAttributeTests 全过" 0
    grep -E "Executed [0-9]+ tests, with 0 failures" /tmp/terminal-palette-tests.log | tail -1 | sed 's/^/     /'
else
    check "TerminalPaletteTests / TerminalDimAttributeTests 全过" 1
    grep -E "error:|failed" /tmp/terminal-palette-tests.log | head -5
fi

echo ""
echo "== 4) 色板一览（文档与代码同源：这份输出来自 Core/TerminalPalette）=="
cat /tmp/terminal-palette.txt

if [ "$fail" -eq 0 ]; then
    echo "全部通过：两套色板的结构 / 对比度门槛 / 属性语义 都成立"
else
    echo "有失败项，见上"
fi
exit "$fail"
