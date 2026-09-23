#!/usr/bin/env python3
"""按"片段补丁"修改带中文的文档 / 源码。

存在的理由（踩过两次的坑）：
    在 bash heredoc 里内联带中文的 Python，会被非 UTF-8 的 locale 解码成乱码，
    结果是**命令静默失败、文件一个字节都没改** —— 而且看上去像成功了。
    所以把补丁内容放进 UTF-8 文件（片段），本脚本自身保持纯 ASCII。

片段格式（同一文件里可以放多组，按出现顺序应用）：

    <<<FILE>>>Docs/需求规范书.md
    <<<ANCHOR>>>要被替换的原文（可以多行）
    <<<REPLACE>>>替换后的文本（可以多行）
    <<<END>>>

规则：
    · 锚点必须在目标文件里**恰好出现一次**；0 次或多次都跳过并报出来，
      不允许"猜一个位置"改文档。
    · 只替换第一处命中，且不回头扫描自己写进去的内容（避免自嵌套）。

用法：
    python3 Scripts/apply-patch-fragment.py 片段文件
"""

from __future__ import annotations

import pathlib
import sys


def parse(patch_text: str) -> list[tuple[str, str, str]]:
    pairs: list[tuple[str, str, str]] = []
    path = anchor = replacement = None
    for line in patch_text.split("\n"):
        if line == "<<<END>>>":
            if path is not None and anchor is not None and replacement is not None:
                pairs.append((path, anchor, replacement))
            path = anchor = replacement = None
        elif line.startswith("<<<FILE>>>"):
            path = line[len("<<<FILE>>>"):].strip()
        elif line.startswith("<<<ANCHOR>>>"):
            anchor = line[len("<<<ANCHOR>>>"):]
        elif line.startswith("<<<REPLACE>>>"):
            replacement = line[len("<<<REPLACE>>>"):]
        elif anchor is not None and replacement is None:
            anchor += "\n" + line
        elif replacement is not None:
            replacement += "\n" + line
    return pairs


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2

    pairs = parse(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
    if not pairs:
        print("片段里没有有效的 <<<FILE>>>/<<<ANCHOR>>>/<<<REPLACE>>> 组")
        return 1

    applied = skipped = 0
    for path, anchor, replacement in pairs:
        target = pathlib.Path(path)
        if not target.exists():
            print(f"跳过：文件不存在 {path}")
            skipped += 1
            continue
        text = target.read_text(encoding="utf-8")
        count = text.count(anchor)
        if count != 1:
            print(f"跳过：锚点在 {path} 里出现 {count} 次（必须恰好 1 次）→ {anchor.strip()[:60]!r}")
            skipped += 1
            continue
        target.write_text(text.replace(anchor, replacement, 1), encoding="utf-8")
        applied += 1

    print(f"应用 {applied} 组，跳过 {skipped} 组（共 {len(pairs)} 组）")
    return 0 if skipped == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
