#!/bin/bash
# 终端输入编码与设备查询应答的可复跑证据（FR-EDIT-29）。
#
# 为什么单独验这一块：鼠标上报、DECCKM、DA1 / DSR / DECRQM / XTVERSION 全是**一串字节**的事 ——
# 界面上看不出对错，但错一位的后果很具体：
#   · 松开被读成"右键按下"（旧式编码的按钮码写错）
#   · vim / less 里方向键没反应（DECCKM 没跟着切 SS3）
#   · 程序一直等光标位置报告 → 看起来像"界面卡住"（DSR 6 不回话）
# 所以这里做三层：
#   ① CLI 的对照表（对着 xterm ctlseqs 逐条核）—— 一眼能看懂、能 grep；
#   ② `--feed` 把转义序列**喂进真实解析器**，看模式位与回给 PTY 的字节（验的是解析器，不只是纯函数）；
#   ③ 单测（字节形状 + 解析器行为，两层都钉住）。
#
# 用法：./Scripts/test-terminal-modes.sh
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }

echo "== 0) 构建 CLI =="
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
if swift build --disable-sandbox --cache-path "$PWD/.build-cache" --scratch-path "$PWD/.build" \
    --manifest-cache local -Xswiftc -disable-sandbox --product DoyahCLI > /tmp/terminal-modes-build.log 2>&1; then
    check "CLI 构建成功" 0
else
    check "CLI 构建成功" 1
    tail -5 /tmp/terminal-modes-build.log
    exit 1
fi

echo ""
echo "== 1) 对照表：鼠标 / 光标键 / 查询应答（对着 xterm ctlseqs 核）=="
"$CLI" terminal-modes > /tmp/terminal-modes.txt 2>&1
check "terminal-modes 输出了对照表" $?

grep -q '左键按下 (10,5)：旧式 ESC\[M \*% ｜ SGR ESC\[<0;10;5M' /tmp/terminal-modes.txt \
    && check "鼠标左键按下：旧式 32/列+32/行+32 与 SGR 两种编码都对" 0 \
    || check "鼠标左键按下：旧式 32/列+32/行+32 与 SGR 两种编码都对" 1
grep -q '左键松开 (10,5)：旧式 ESC\[M#\*% ｜ SGR ESC\[<0;10;5m' /tmp/terminal-modes.txt \
    && check "松开：旧式按钮码 3（#=35）而 SGR 用结尾 m 区分" 0 \
    || check "松开：旧式按钮码 3（#=35）而 SGR 用结尾 m 区分" 1
grep -q '拖动 (12,6)：旧式 ESC\[M@,& ｜ SGR ESC\[<32;12;6M' /tmp/terminal-modes.txt \
    && check "移动：按钮码 +32" 0 || check "移动：按钮码 +32" 1
grep -q 'DECRQM ?1000 已置位 → ESC\[?1000;1\$y' /tmp/terminal-modes.txt \
    && check "DECRQM 回 ?1000;1\$y" 0 || check "DECRQM 回 ?1000;1\$y" 1

grep -q 'up：普通 ESC\[A ｜ 应用模式 ESCOA' /tmp/terminal-modes.txt \
    && check "DECCKM：方向键普通走 CSI、应用模式走 SS3" 0 \
    || check "DECCKM：方向键普通走 CSI、应用模式走 SS3" 1
grep -q 'DA1（CSI c）        → ESC\[?1;2c' /tmp/terminal-modes.txt \
    && check "DA1 回 VT100 + AVO" 0 || check "DA1 回 VT100 + AVO" 1
grep -q 'DA2（CSI > c）      → ESC\[>0;0;0c' /tmp/terminal-modes.txt \
    && check "DA2 版本号写 0（不冒充 xterm 高版本）" 0 || check "DA2 版本号写 0（不冒充 xterm 高版本）" 1
grep -q 'XTVERSION（CSI > q）→ ESCP>|DoyahStudio' /tmp/terminal-modes.txt \
    && check "XTVERSION 报自己的名字（不冒充 xterm）" 0 || check "XTVERSION 报自己的名字（不冒充 xterm）" 1

echo ""
echo "== 2) 喂进真实解析器：模式位与回给 PTY 的字节 =="
OUT="$("$CLI" terminal-modes --feed "$(printf '\033[?1002h\033[?1006h\033[?1h\033[6n')" 2>&1)"
check "--feed 退出码 0" $?
echo "$OUT" | grep -q "DECCKM 开" && check "DECCKM 置位被解析到" 0 || check "DECCKM 置位被解析到" 1
echo "$OUT" | grep -q "鼠标 按住拖动（?1002）" && check "鼠标模式 ?1002 被解析到" 0 || check "鼠标模式 ?1002 被解析到" 1
echo "$OUT" | grep -q "SGR 编码 开" && check "SGR 编码 ?1006 被解析到" 0 || check "SGR 编码 ?1006 被解析到" 1
echo "$OUT" | grep -q "回给 PTY：ESC\[1;1R" && check "DSR 6 回了光标位置（不回话程序会一直等）" 0 || check "DSR 6 回了光标位置（不回话程序会一直等）" 1

JSON="$("$CLI" terminal-modes --feed "$(printf '\033[?1000h\033[?1006h\033[?1000$p\033[?9999$p')" --json 2>&1)"
echo "$JSON" | grep -q '"mouseTracking":1000' && check "--json 里鼠标模式是 1000" 0 || check "--json 里鼠标模式是 1000" 1
echo "$JSON" | grep -q 'ESC\[?1000;1\$yESC\[?9999;0\$y' \
    && check "已置位回 1、不认识回 0（不谎报能力）" 0 \
    || check "已置位回 1、不认识回 0（不谎报能力）" 1

echo ""
echo "== 3) 负例：互斥模式、无查询不乱回话、全复位 =="
MUTEX="$("$CLI" terminal-modes --feed "$(printf '\033[?1002h\033[?1003l')" 2>&1)"
echo "$MUTEX" | grep -q "鼠标 按住拖动（?1002）" \
    && check "关掉 ?1003 不影响 ?1002（模式互斥但不误伤）" 0 \
    || check "关掉 ?1003 不影响 ?1002（模式互斥但不误伤）" 1

QUIET="$("$CLI" terminal-modes --feed "echo hi" 2>&1)"
echo "$QUIET" | grep -q "回给 PTY：（无）" \
    && check "没有查询时不回任何字节（免得往 shell 里灌东西）" 0 \
    || check "没有查询时不回任何字节（免得往 shell 里灌东西）" 1

RESET="$("$CLI" terminal-modes --feed "$(printf '\033[?1002h\033[?1006h\033[?1h\033c')" 2>&1)"
echo "$RESET" | grep -q "DECCKM 关" && echo "$RESET" | grep -q "鼠标 关闭" && echo "$RESET" | grep -q "SGR 编码 关" \
    && check "RIS（ESC c）把模式位全部复位" 0 \
    || check "RIS（ESC c）把模式位全部复位" 1

ALT="$("$CLI" terminal-modes --feed "$(printf '\033[?1h\033[?1002h\033[?1049h\033[?1l\033[?1002l\033[?1049l')" 2>&1)"
echo "$ALT" | grep -q "DECCKM 开" && echo "$ALT" | grep -q "鼠标 按住拖动（?1002）" \
    && check "退出备用屏（?1049l）恢复了 TUI 改过的模式位" 0 \
    || check "退出备用屏（?1049l）恢复了 TUI 改过的模式位" 1

echo ""
echo "== 3.5) 光标形状 / 颜色查询应答 / 弯下划线 / 清回滚区（FR-EDIT-29 本轮补充）=="
DECSCUSR="$("$CLI" terminal-modes --feed "$(printf '\033[5 q')" 2>&1)"
echo "$DECSCUSR" | grep -q "光标形状：竖线（闪烁）" && check "DECSCUSR（CSI 5 SP q）→ 竖线闪烁" 0 \
    || { check "DECSCUSR 没生效" 1; echo "$DECSCUSR" | tail -3; }
UNDER="$("$CLI" terminal-modes --feed "$(printf '\033[4 q')" 2>&1)"
echo "$UNDER" | grep -q "光标形状：下划线（稳定）" && check "DECSCUSR（CSI 4 SP q）→ 下划线稳定" 0 \
    || check "DECSCUSR 下划线没生效" 1
KEEP="$("$CLI" terminal-modes --feed "$(printf '\033[2 q\033[9 q')" 2>&1)"
echo "$KEEP" | grep -q "光标形状：块状（稳定）" && check "认不出的参数保持原状（不猜、不清空）" 0 \
    || check "认不出的参数应当保持原状" 1

OSC11="$("$CLI" terminal-modes --feed "$(printf '\033]11;?\007')" 2>&1)"
echo "$OSC11" | grep -q "回给 PTY：ESC]11;rgb:" && check "OSC 11 查询被应答（背景色）" 0 \
    || { check "OSC 11 没应答" 1; echo "$OSC11" | tail -3; }
OSC10="$("$CLI" terminal-modes --feed "$(printf '\033]10;?\033\\')" 2>&1)"
echo "$OSC10" | grep -q "回给 PTY：ESC]10;rgb:" && check "OSC 10 查询被应答（前景色，ST 结尾）" 0 \
    || check "OSC 10 没应答" 1
TITLE="$("$CLI" terminal-modes --feed "$(printf '\033]0;title\007')" 2>&1)"
echo "$TITLE" | grep -q "回给 PTY：（无）" && check "其它 OSC（窗口标题）照旧忽略" 0 \
    || check "其它 OSC 不该被当成颜色查询" 1

grep -q "Ps=3 → 下划线（闪烁）" /tmp/terminal-modes.txt && check "对照表列出 DECSCUSR 六个取值" 0 \
    || check "对照表应列出 DECSCUSR" 1
grep -q "OSC 12;? → OSC 12;rgb:" /tmp/terminal-modes.txt && check "对照表列出颜色查询应答格式" 0 \
    || check "对照表应列出颜色查询" 1

echo ""
echo "== 4) 单测（字节形状 + 解析器行为）=="
if swift test --disable-sandbox --cache-path "$PWD/.build-cache" --scratch-path "$PWD/.build" \
    --manifest-cache local -Xswiftc -disable-sandbox \
    --filter 'TerminalInputTests|TerminalModeTests|TerminalCursorTests' > /tmp/terminal-modes-tests.log 2>&1; then
    check "TerminalInputTests + TerminalModeTests 全过" 0
else
    check "TerminalInputTests + TerminalModeTests 全过" 1
    grep -E "error:|failed" /tmp/terminal-modes-tests.log | head -5
fi

echo ""
if [ "$fail" -eq 0 ]; then
    echo "全部通过：鼠标上报 / DECCKM / 设备应答的字节与解析器行为都对。"
    echo "（**边界**：这里验的是我们**发出去**的字节；真机上的接收方（vim / tmux / less 的鼠标模式）"
    echo "  仍需人工点一次 —— 见 Docs/design/剩余任务清单.md 的人工清单。）"
else
    echo "有失败项，见上"
fi
exit "$fail"
