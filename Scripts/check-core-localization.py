#!/usr/bin/env python3
"""Core 展示文本本地化的**棘轮**（R-45 / FR-DATA-04）。

存在的理由：
    Core 里有一批**直接给用户看**的中文字面量（`LocalizedError` 的描述、拒绝理由、
    单元格摘要…）。它们不经过任何语言表，于是英文界面上会混出中文。R-45 与 FR-DATA-04
    各记了一处，但真正的问题是它**会继续长** —— 每加一个 `LocalizedError` 就多一串。

口径（与其它棘轮一致：**只挡变差，不要求一次还清**）：
    · 统计 `Core/**/*.swift`（排除 `Localization.swift` —— 那里是语言表本身）里
      "字符串字面量含汉字"的行数，按「文件数」与「行数」两个口径记账；
    · 比基线更差即失败；想增加就必须**同时**在基线里显式加数字（一次有意识的决定）；
    · 已修的地方要**降基线**（`--update-baseline`），否则棘轮只挡增长、不记进步。

用法：
    python3 Scripts/check-core-localization.py               # 校验（闸门）
    python3 Scripts/check-core-localization.py --report      # 按文件列出命中
    python3 Scripts/check-core-localization.py --update-baseline
"""

from __future__ import annotations

import json
import pathlib
import re
import sys

CORE = pathlib.Path("Core")
BASELINE = pathlib.Path("Scripts/core-localization-baseline.json")
EXEMPT = {"Localization.swift"}
HAN = re.compile(r"[\u4e00-\u9fff]")
STRING_LITERAL = re.compile(r'"([^"\\]*(?:\\.[^"\\]*)*)"')


def scan() -> tuple[dict[str, int], dict[str, list[int]]]:
    """返回 (每个文件的命中行数, 每个文件的行号列表)。"""
    counts: dict[str, int] = {}
    lines_by_file: dict[str, list[int]] = {}
    for path in sorted(CORE.rglob("*.swift")):
        if path.name in EXEMPT:
            continue
        hits: list[int] = []
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            stripped = line.strip()
            if stripped.startswith("//"):
                continue
            for literal in STRING_LITERAL.findall(line):
                if HAN.search(literal):
                    hits.append(number)
                    break
        if hits:
            counts[path.name] = len(hits)
            lines_by_file[path.name] = hits
    return counts, lines_by_file


def main() -> int:
    counts, lines_by_file = scan()
    current = {"files": len(counts), "lines": sum(counts.values())}

    if "--update-baseline" in sys.argv:
        BASELINE.write_text(
            json.dumps(
                {
                    "comment": "Core 展示文本本地化棘轮基线：Core 里「字符串字面量含汉字」的"
                               "文件数与行数只能降不能升。修掉一批后用 --update-baseline 降基线。",
                    "baseline": current,
                },
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )
        print(f"✅ 基线已更新：{current['files']} 个文件 / {current['lines']} 行")
        return 0

    if "--report" in sys.argv:
        for name, count in sorted(counts.items(), key=lambda item: -item[1]):
            print(f"{count:>4}  {name}  行号 {lines_by_file[name][:6]}{' …' if count > 6 else ''}")
        print(f"合计：{current['files']} 个文件 / {current['lines']} 行")
        return 0

    baseline = json.loads(BASELINE.read_text(encoding="utf-8"))["baseline"] if BASELINE.exists() else {"files": 0, "lines": 0}
    problems = []
    if current["files"] > baseline["files"]:
        problems.append(f"文件数 {baseline['files']} → {current['files']}")
    if current["lines"] > baseline["lines"]:
        problems.append(f"行数 {baseline['lines']} → {current['lines']}")

    if problems:
        print(f"❌ Core 展示文本本地化棘轮失败（{len(problems)} 项比基线更差）：")
        for problem in problems:
            print("   " + problem)
        print("   提示：新写的用户可见文案请走 `LocalizedStrings.text(_:language:)`（Core 的语言表），")
        print("         把语言作为参数传进来（默认中文，界面传当前语言）；确有必要保留字面量时，")
        print("         请先在 `Scripts/core-localization-baseline.json` 里显式加数字并说明原因。")
        return 1

    print(
        f"✅ Core 展示文本本地化棘轮通过（{current['files']} 个文件 / {current['lines']} 行；"
        f"基线 {baseline['files']} / {baseline['lines']}）"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
