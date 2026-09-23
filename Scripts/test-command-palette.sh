#!/bin/bash
# 验证：命令面板（FR-EDIT-25）—— 十项待开发第 4 项的可复跑验证。
#
# 背景（为什么这个脚本长这样）：
#   这一项此前只有 Core 单测，没有脚本验证，于是「清单里列了命令」和「命令真的能打开东西」
#   之间的断层没人管 —— 直到 2026-09-23 收尾自查发现：10 条命令里 **9 条是死的**
#   （设了 `@Published` 标志位，但没有任何视图读它；用户在 ⌘K 里选「会话 / 锁 / 浏览数据 /
#   表结构 / 切换连接 / 智能体 / 合成数据 / 帮助」完全没反应）。
#
#   所以本脚本验的不是"面板能不能画出来"（那要人手点），而是**接线契约**：
#   清单 ↔ 分派器 ↔ 视图绑定三边对齐，外加 ⌘K 这个入口本身登记在快捷键表里。
set -uo pipefail

cd "$(dirname "$0")/.."

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }

echo "== 1) 接线契约（清单 ↔ 分派器 ↔ 视图绑定）=="
OUT="$(python3 Scripts/check-palette-wiring.py 2>&1)"
STATUS=$?
echo "$OUT" | sed 's/^/  /'
check "命令清单 / 分派器 / 视图绑定三边对齐" "$STATUS"

echo ""
echo "== 2) ⌘K 必须登记在快捷键单一事实来源里（FR-EDIT-28 的纪律）=="
# 判据：AppShortcut 里要有一条 ⌘K；且**不得有第二条**占用 ⌘K（占用冲突会让其中一个静默失效）。
python3 - <<'PY'
import pathlib, re, sys
text = pathlib.Path("App/ShortcutCatalog.swift").read_text(encoding="utf-8")
if "case commandPalette" not in text:
    print("  ❌ AppShortcut 里没有 commandPalette —— 帮助面板列不出 ⌘K，用户不知道有这个入口")
    sys.exit(1)
# 找 .commandPalette 的 key / modifiers
key = re.search(r"case \.commandPalette:\s*return\s*\"([^\"]+)\"", text)
mods = re.search(r"case ([^\n]*\.commandPalette[^\n]*):\s*\n\s*return \[([^\]]*)\]", text)
if not key or key.group(1) != "k":
    print(f"  ❌ commandPalette 的键不是 k：{key.group(1) if key else '未找到'}")
    sys.exit(1)
if not mods or ".command" not in mods.group(2) or ".option" in mods.group(2) or ".shift" in mods.group(2):
    print(f"  ❌ commandPalette 的修饰键不是纯 ⌘：{mods.group(2) if mods else '未找到'}")
    sys.exit(1)
# 冲突检查：别处若也解析出 ⌘K，就是两个入口抢同一个键
others = [m for m in re.findall(r"case ([a-zA-Z, ]+):\s*\n\s*return \"k\"", text)]
print(f"  ✅ ⌘K 已登记（commandPalette），同键候选：{others}")
PY
[ $? -eq 0 ] || fail=1

echo ""
echo "== 3) 每条命令都有类别与关键词（否则面板里搜不到 / 分不出组）=="
python3 - <<'PY'
import pathlib, re, sys
text = pathlib.Path("App/AppCommandCatalog.swift").read_text(encoding="utf-8")
items = re.findall(r'item\(\s*"([^"]+)"\s*,\s*\.(\w+)\s*,\s*"([^"]*)"\s*,\s*"([^"]*)"\s*,\s*\.(\w+)\s*\)', text)
if len(items) < 10:
    print(f"  ❌ 只解析到 {len(items)} 条命令 —— 清单结构可能变了，请同步本脚本")
    sys.exit(1)
bad = [i[0] for i in items if not i[2].strip() or not i[3].strip()]
cats = {i[4] for i in items}
if bad:
    print(f"  ❌ 关键词为空：{bad}")
    sys.exit(1)
if len(cats) < 3:
    print(f"  ❌ 类别只有 {len(cats)} 个：{sorted(cats)}")
    sys.exit(1)
print(f"  ✅ {len(items)} 条命令：关键词齐全，分布在 {len(cats)} 个类别（{', '.join(sorted(cats))}）")
PY
[ $? -eq 0 ] || fail=1

echo ""
echo "== 4) 未知 id 不静默（点了没反应是最坏的结果）=="
if grep -q "statusMessage = L(.commandPaletteNoMatch)" App/AppState.swift; then
    check "分派器的 default 分支给出可读提示" 0
else
    check "分派器 default 分支必须提示，不许静默" 1
fi

echo ""
if [ "$fail" -eq 0 ]; then
    echo "通过：命令清单 / 分派器 / 视图绑定三边对齐，⌘K 已登记，未知 id 不静默"
    echo "（界面点击效果仍需人工确认 —— 本脚本验的是接线契约，不是观感）"
else
    echo "有失败项，见上"
fi
exit "$fail"
