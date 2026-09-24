#!/usr/bin/env python3
"""终端配色三方一致性校验（FR-EDIT-29 的跨平台交接物）。

为什么需要这个门禁：
    Linux 侧要按同一套配色实现自己的终端，它读到的是仓库里的两份东西 ——
      · `Docs/design/terminal-palette.json`（机器可读，给代码用）
      · `Docs/design/终端配色方案.md`（人读，给设计与评审用）
    这两份都是**从 `Core/TerminalPalette` 派生**的。历史上本仓已经吃过"文档落后于代码"
    的亏（状态列、能力地图、表格计数都漂过），所以这里把三者钉在一起：

        代码（Core，权威）  ==  JSON（机械导出）  ⊆  文档（人工写，但 hex 必须逐个出现）

    三者任一漂移即失败。JSON 由 CLI 导出而不是人手写：
        ./.build/debug/DoyahCLI terminal-palette --json > Docs/design/terminal-palette.json

用法：
    python3 Scripts/check-terminal-palette.py            # 校验（闸门）
    python3 Scripts/check-terminal-palette.py --write    # 用当前代码重新导出 JSON
"""

from __future__ import annotations

import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
JSON_PATH = ROOT / "Docs" / "design" / "terminal-palette.json"
DOC_PATH = ROOT / "Docs" / "design" / "终端配色方案.md"
CLI = ROOT / ".build" / "debug" / "DoyahCLI"

# 门槛：正文槽位对底色 ≥ 4.5（WCAG AA）、前景对底色 ≥ 7（AAA）。
# 与 `Tests/TerminalPaletteTests.swift` 是**两份独立实现**（这里是 Python）。
MIN_TEXT_SLOT = 4.5
MIN_FOREGROUND = 7.0


def _number(value) -> float | None:
    """JSON 里的对比度是两位小数字符串；解析不出来返回 None（由调用方报问题，不崩）。"""
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _channel(value: int) -> float:
    c = value / 255
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def contrast_ratio(hex_a: str, hex_b: str) -> float:
    """WCAG 对比度 —— 这里是**独立于 Swift 的第二份实现**。

    为什么要再写一遍：单测用 Swift 算、这里用 Python 算，两边都给出"达标"才算门槛成立。
    只读 JSON 里现成的对比度等于自己给自己判卷。
    """

    def luminance(hex_value: str) -> float:
        text = hex_value.lstrip("#")
        r, g, b = int(text[0:2], 16), int(text[2:4], 16), int(text[4:6], 16)
        return 0.2126 * _channel(r) + 0.7152 * _channel(g) + 0.0722 * _channel(b)

    la, lb = luminance(hex_a), luminance(hex_b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


# 期望的两套色板（缺了就是"少交付一套配色"，不是小事）
EXPECTED_PALETTES = ["深海·夜", "深海·昼"]
EXPECTED_SLOTS = 16


def export() -> list[dict]:
    """用 CLI 导出当前色板（与 App 用的是同一份 Core 代码）。"""
    if not CLI.exists():
        raise SystemExit(
            f"❌ 找不到 {CLI.relative_to(ROOT)} —— 先构建 CLI（./Scripts/verify-core.sh 或 swift build）"
        )
    result = subprocess.run(
        [str(CLI), "terminal-palette", "--json"],
        capture_output=True,
        text=True,
        cwd=ROOT,
    )
    if result.returncode != 0:
        raise SystemExit(f"❌ terminal-palette --json 退出码 {result.returncode}：{result.stderr.strip()[:200]}")
    return json.loads(result.stdout)


def palettes(entries: list[dict]) -> list[dict]:
    return [entry for entry in entries if entry.get("kind") == "palette"]


def main() -> int:
    arguments = set(sys.argv[1:])

    if "--write" in arguments:
        JSON_PATH.write_text(
            subprocess.run(
                [str(CLI), "terminal-palette", "--json"],
                capture_output=True,
                text=True,
                cwd=ROOT,
                check=True,
            ).stdout,
            encoding="utf-8",
        )
        print(f"✅ 已用当前代码重写 {JSON_PATH.relative_to(ROOT)}")
        return 0

    problems: list[str] = []

    if not JSON_PATH.exists():
        print(f"❌ 缺少 {JSON_PATH.relative_to(ROOT)}（用本脚本 --write 生成）")
        return 1

    committed = json.loads(JSON_PATH.read_text(encoding="utf-8"))
    fresh = export()

    committed_palettes = palettes(committed)
    fresh_palettes = palettes(fresh)

    # ① 结构：两套色板、每套 16 槽
    if [item.get("name") for item in fresh_palettes] != EXPECTED_PALETTES:
        problems.append(f"Core 里的色板不再是 {EXPECTED_PALETTES}：{[item.get('name') for item in fresh_palettes]}")
    for item in fresh_palettes:
        if len(item.get("ansi", [])) != EXPECTED_SLOTS:
            problems.append(f"{item.get('name')}：槽位数是 {len(item.get('ansi', []))}，应为 {EXPECTED_SLOTS}")

    # ② JSON ↔ 代码：**hex 必须逐位一致**（hex 是权威，对比度是派生出来的说明）
    if [item.get("name") for item in committed_palettes] != [item.get("name") for item in fresh_palettes]:
        problems.append("committed JSON 的色板名与代码不一致")
    else:
        for committed_palette, fresh_palette in zip(committed_palettes, fresh_palettes):
            name = fresh_palette["name"]
            for key in ("background", "foreground", "cursor", "selection"):
                if committed_palette.get(key) != fresh_palette[key]:
                    problems.append(
                        f"{name} 的 {key}：JSON 写 {committed_palette.get(key)}，代码是 {fresh_palette[key]}"
                    )
            committed_slots = [slot.get("hex") for slot in committed_palette.get("ansi", [])]
            fresh_slots = [slot["hex"] for slot in fresh_palette.get("ansi", [])]
            if committed_slots != fresh_slots:
                for index, (a, b) in enumerate(zip(committed_slots, fresh_slots)):
                    if a != b:
                        problems.append(f"{name} 槽位 {index}：JSON 写 {a}，代码是 {b}")

    # ③ 文档 ⊆ 代码：每个 hex 都必须在人读文档里出现（文档可以多写解释，不能少写色值）
    if not DOC_PATH.exists():
        problems.append(f"缺少 {DOC_PATH.relative_to(ROOT)}")
    else:
        document = DOC_PATH.read_text(encoding="utf-8").upper()
        for item in fresh_palettes:
            name = item["name"]
            for key in ("background", "foreground", "cursor", "selection"):
                hex_value = item[key].upper()
                if hex_value not in document:
                    problems.append(f"文档里找不到 {name} 的 {key} 色值 {hex_value}")
            for slot in item.get("ansi", []):
                hex_value = slot["hex"].upper()
                if hex_value not in document:
                    problems.append(f"文档里找不到 {name} 槽位 {slot['index']}（{slot['name']}）的色值 {hex_value}")

    # ④ 对比度**独立复算**：不读 JSON 里现成的数字当结论，而是用 Python 从 hex 重算，
    #    再做两件事 —— ① 与 JSON 里写的数字对齐（防"色值改了、对比度说明没改"的僵尸字段）；
    #    ② 判门槛。与 Swift 单测构成两份独立实现。
    # 用 **committed JSON** 的数字（第 ② 步已经证明它的 hex 与代码一致，所以这份就是现状）
    for item in committed_palettes:
        name = item.get("name")
        background = item.get("background", "#000000")
        computed = contrast_ratio(item.get("foreground", "#000000"), background)
        declared = _number(item.get("foregroundContrast"))
        if declared is None:
            problems.append(f"{name}：前景对比度不是数字（{item.get('foregroundContrast')!r}）")
        elif abs(computed - declared) > 0.01:
            problems.append(f"{name}：JSON 写前景对比度 {declared:.2f}，独立复算是 {computed:.2f}")
        if computed < MIN_FOREGROUND:
            problems.append(f"{name}：前景对底色只有 {computed:.2f}（要求 ≥ {MIN_FOREGROUND}）")

        for slot in item.get("ansi", []):
            computed_slot = contrast_ratio(slot.get("hex", "#000000"), background)
            declared_slot = _number(slot.get("contrast"))
            if declared_slot is None:
                problems.append(f"{name} 槽位 {slot.get('index')}：对比度不是数字（{slot.get('contrast')!r}）")
            elif abs(computed_slot - declared_slot) > 0.01:
                problems.append(
                    f"{name} 槽位 {slot.get('index')}：JSON 写对比度 {declared_slot:.2f}，独立复算是 {computed_slot:.2f}"
                )
            if slot.get("backgroundSlot"):
                continue
            if computed_slot < MIN_TEXT_SLOT:
                problems.append(
                    f"{name} 槽位 {slot.get('index')}（{slot.get('name')}）：对底色只有 {computed_slot:.2f}"
                    f"（要求 ≥ {MIN_TEXT_SLOT}）"
                )

    if problems:
        print(f"❌ 终端配色三方一致性校验失败（{len(problems)} 处）：")
        for problem in problems[:12]:
            print(f"   {problem}")
        print("   提示：代码改了色板就重新导出 `python3 Scripts/check-terminal-palette.py --write`，")
        print("        并把新色值同步进 Docs/design/终端配色方案.md。")
        return 1

    total = sum(len(item.get("ansi", [])) for item in fresh_palettes)
    print(
        f"✅ 终端配色一致（{len(fresh_palettes)} 套 × {EXPECTED_SLOTS} 槽 = {total} 个色值）："
        "JSON 与代码逐位相同，文档里都能找到"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
