#!/usr/bin/env python3
"""按"片段补丁"修改带中文的文档 / 源码。

存在的理由（踩过两次的坑）：
    在 bash heredoc 里内联带中文的 Python，会被非 UTF-8 的 locale 解码成乱码，
    结果是**命令静默失败、文件一个字节都没改**，而且看上去像成功了。
    所以补丁内容放进 UTF-8 文件（片段），本脚本自身保持纯 ASCII。

片段格式（同一文件里可放多组，按出现顺序应用）：

    <<<FILE>>>Docs/需求规范书.md      # 可省略：省略则沿用上一组的文件
    <<<ANCHOR>>>要被替换的原文（可多行）
    <<<REPLACE>>>替换后的文本（可多行）
    <<<END>>>

规则（宁可拒绝执行，也不"猜一个位置"改文档）：
    · 锚点在目标文件里必须**恰好出现一次**；0 次或多次都跳过并报出来；
    · 一组里没有可沿用的 `<<<FILE>>>` → **整份拒绝执行**（不是静默丢弃）；
    · 只替换第一处命中，且不回头扫描自己写进去的内容（避免自嵌套）。

用法：
    python3 Scripts/apply-patch-fragment.py 片段文件
    python3 Scripts/apply-patch-fragment.py --self-test    # 解析器自检
"""

from __future__ import annotations

import pathlib
import sys

FILE_MARK = "<<<FILE>>>"
ANCHOR_MARK = "<<<ANCHOR>>>"
REPLACE_MARK = "<<<REPLACE>>>"
END_MARK = "<<<END>>>"


def parse(patch_text: str) -> tuple[list[tuple[str, str, str]], list[str]]:
    """解析片段，返回 (可应用的组, 不可应用的组的说明)。"""
    pairs: list[tuple[str, str, str]] = []
    broken: list[str] = []
    path: str | None = None
    anchor: str | None = None
    replacement: str | None = None
    mode: str | None = None          # "anchor" | "replace" | None

    for line in patch_text.split("\n"):
        if line == END_MARK:
            if anchor is not None and replacement is not None:
                if path is None:
                    broken.append(anchor.strip().split("\n")[0][:60])
                else:
                    pairs.append((path, anchor, replacement))
            anchor = replacement = None
            mode = None
        elif line.startswith(FILE_MARK):
            path = line[len(FILE_MARK):].strip() or None
            anchor = replacement = None
            mode = None
        elif line.startswith(ANCHOR_MARK):
            anchor = line[len(ANCHOR_MARK):]
            replacement = None
            mode = "anchor"
        elif line.startswith(REPLACE_MARK):
            replacement = line[len(REPLACE_MARK):]
            mode = "replace"
        elif mode == "anchor" and anchor is not None:
            anchor += "\n" + line
        elif mode == "replace" and replacement is not None:
            replacement += "\n" + line

    return pairs, broken


def apply(pairs: list[tuple[str, str, str]]) -> tuple[int, int]:
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
    return applied, skipped


def self_test() -> int:
    """解析器自检：三条最容易错的规则各测一次。"""
    failures = 0

    def check(name: str, condition: bool) -> None:
        nonlocal failures
        print(("  ok   " if condition else "  FAIL ") + name)
        if not condition:
            failures += 1

    # 1) 省略 FILE → 沿用上一组
    pairs, broken = parse(
        f"{FILE_MARK}A.md\n{ANCHOR_MARK}x\n{REPLACE_MARK}y\n{END_MARK}\n"
        f"{ANCHOR_MARK}p\n{REPLACE_MARK}q\n{END_MARK}\n"
    )
    check("省略 FILE 时沿用上一组", len(pairs) == 2 and pairs[1][0] == "A.md" and not broken)

    # 2) 完全没有 FILE → 报为不可应用（而不是静默丢弃）
    pairs, broken = parse(f"{ANCHOR_MARK}x\n{REPLACE_MARK}y\n{END_MARK}\n")
    check("没有 FILE 时报为 broken", not pairs and len(broken) == 1)

    # 3) 多行锚点与多行替换都要完整保留
    pairs, broken = parse(
        f"{FILE_MARK}A.md\n{ANCHOR_MARK}l1\nl2\n{REPLACE_MARK}r1\nr2\n{END_MARK}\n"
    )
    check(
        "多行锚点/替换完整",
        len(pairs) == 1 and pairs[0][1] == "l1\nl2" and pairs[0][2] == "r1\nr2",
    )

    # 4) REPLACE 里的内容不能被再次当成指令（含 FILE 字样也只当文本）
    pairs, broken = parse(
        f"{FILE_MARK}A.md\n{ANCHOR_MARK}x\n{REPLACE_MARK}{FILE_MARK}fake\n{END_MARK}\n"
    )
    check("替换体里的标记不当指令", len(pairs) == 1 and FILE_MARK in pairs[0][2])

    print(f"自检：{'全部通过' if failures == 0 else str(failures) + ' 项未过'}")
    return 0 if failures == 0 else 1


def main() -> int:
    if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
        return self_test()
    if len(sys.argv) != 2:
        print(__doc__)
        return 2

    pairs, broken = parse(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
    if broken:
        print("❌ 这些组没有可沿用的 <<<FILE>>>，整份拒绝执行（避免静默丢弃）：")
        for item in broken:
            print("   " + item)
        return 1
    if not pairs:
        print("片段里没有有效的 <<<ANCHOR>>>/<<<REPLACE>>> 组")
        return 1

    applied, skipped = apply(pairs)
    print(f"应用 {applied} 组，跳过 {skipped} 组（共 {len(pairs)} 组）")
    return 0 if skipped == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
