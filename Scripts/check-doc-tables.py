#!/usr/bin/env python3
"""校验 Docs/ 下所有 Markdown 表格的列数一致性。

背景：本工程的文档表格由脚本增量修改，历史上出现过「两行被合并成一行」
（`| ... || ... |`）导致表格错位的问题。本脚本作为文档维护约定的一部分，
每次修改文档后运行，确保：

1. 每张表的表头、分隔行、数据行列数一致；
2. 表格内没有 `||`（列之间缺少空格 / 行被拼接）的痕迹。

用法：
    python3 Scripts/check-doc-tables.py [Docs/需求规范书.md ...]
"""

from __future__ import annotations

import pathlib
import sys

DEFAULT_TARGETS = [
    "Docs/需求规范书.md",
    "Docs/README.md",
    "Docs/兼容性矩阵.md",
    "Docs/GBase-技术验证.md",
    "Docs/测试用例.md",
    "Docs/概要设计.md",
    "Docs/发布方案.md",
]


def split_row(line: str) -> list[str]:
    """按未转义的 `|` 切分单元格（Markdown 里的 `\\|` 是字面竖线）。"""
    text = line.strip()
    if text.startswith("|"):
        text = text[1:]
    if text.endswith("|") and not text.endswith("\\|"):
        text = text[:-1]

    cells: list[str] = []
    current: list[str] = []
    escaped = False
    for character in text:
        if escaped:
            current.append(character)
            escaped = False
            continue
        if character == "\\":
            escaped = True
            current.append(character)
            continue
        if character == "|":
            cells.append("".join(current))
            current = []
            continue
        current.append(character)
    cells.append("".join(current))
    return cells


def check(path: pathlib.Path) -> list[str]:
    problems: list[str] = []
    lines = path.read_text().splitlines()

    index = 0
    while index < len(lines):
        line = lines[index]
        if not line.strip().startswith("|"):
            index += 1
            continue

        # 一张表：连续的 | 开头行
        start = index
        block: list[str] = []
        while index < len(lines) and lines[index].strip().startswith("|"):
            block.append(lines[index])
            index += 1

        if len(block) < 2:
            continue

        expected = len(split_row(block[0]))
        for offset, row in enumerate(block):
            cells = split_row(row)
            if len(cells) != expected:
                problems.append(
                    f"{path}:{start + offset + 1}: 列数 {len(cells)} != 表头 {expected} -> {row.strip()[:80]}"
                )
            if "||" in row.replace("\\|", ""):
                problems.append(
                    f"{path}:{start + offset + 1}: 出现 '||'（疑似两行被合并）-> {row.strip()[:80]}"
                )

    return problems


def main() -> int:
    targets = sys.argv[1:] or DEFAULT_TARGETS
    problems: list[str] = []

    for target in targets:
        path = pathlib.Path(target)
        if not path.exists():
            problems.append(f"{target}: 文件不存在")
            continue
        problems.extend(check(path))

    if problems:
        print(f"❌ 表格校验失败（{len(problems)} 处）：")
        for problem in problems:
            print("   " + problem)
        return 1

    print(f"✅ 表格校验通过（{len(targets)} 个文件）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
