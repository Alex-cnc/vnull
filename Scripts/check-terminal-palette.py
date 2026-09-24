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
