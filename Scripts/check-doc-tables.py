#!/usr/bin/env python3
"""校验 Docs/ 下所有 Markdown 表格的列数一致性，以及需求计数的一致性。

背景：本工程的文档表格由脚本增量修改，历史上出现过两类漂移：

1. 「两行被合并成一行」（`| ... || ... |`）导致表格错位；
2. **需求计数没有跟着条目走** —— §10.1 表头长期停在 v3.2 生成时的 `207`，
   而索引实际已经 213 行；《产品能力规划说明书》的能力地图也落后一条
   （FR-EDIT-31 归档未计入）。两者都是"手工维护的数字"，必然漂移。

因此本脚本每次修改文档后运行，确保：

1. 每张表的表头、分隔行、数据行列数一致；
2. 表格内没有 `||`（列之间缺少空格 / 行被拼接）的痕迹；
3. **§10.1 的计数 = 索引实际行数**，且 FR / NFR / AC 的构成也对得上；
4. **《产品能力规划说明书》的派生数字**（总数与三条状态、第 3 节 ⬜ 项数、
   第 2 节逐域计数）与由 SRS 索引派生出来的值一致。

用法：
    python3 Scripts/check-doc-tables.py [Docs/需求规范书.md ...]
"""

from __future__ import annotations

import pathlib
import re
import sys
from collections import Counter

DEFAULT_TARGETS = [
    "Docs/产品能力规划说明书.md",
    "Docs/功能清单（一页纸）.md",
    "Docs/功能清单（管理视图）.md",
    "Docs/需求规范书.md",
    "Docs/README.md",
    "Docs/兼容性矩阵.md",
    "Docs/GBase-技术验证.md",
    "Docs/测试用例.md",
    "Docs/概要设计.md",
    "Docs/发布方案.md",
    "Docs/手工验收运行手册.md",
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


def check_requirement_counts() -> list[str]:
    """校验需求计数与索引实际行数一致（防止"手工维护的数字"再次漂移）。"""
    srs = pathlib.Path("Docs/需求规范书.md")
    capability = pathlib.Path("Docs/产品能力规划说明书.md")
    if not srs.exists():
        return [f"{srs}: 文件不存在"]

    problems: list[str] = []
    lines = srs.read_text().splitlines()

    # 1) §10.1 的计数行
    declared = None
    count_line = 0
    pattern = re.compile(r"^共 \*\*(\d+)\*\* 条（FR (\d+) · NFR (\d+) · AC (\d+)）")
    for index, line in enumerate(lines):
        match = pattern.match(line)
        if match:
            declared = tuple(int(value) for value in match.groups())
            count_line = index + 1
            break
    if declared is None:
        problems.append(f"{srs}: 未找到 §10.1 计数行（形如「共 **N** 条（FR a · NFR b · AC c）」）")
        return problems

    # 2) 索引表本体
    header = "| 编号 | 所属域 / 章节 | 层次 | 状态 |"
    if header not in lines:
        problems.append(f"{srs}: 未找到 §10.1 索引表头")
        return problems

    rows: list[list[str]] = []
    index = lines.index(header) + 2
    while index < len(lines) and lines[index].startswith("|"):
        rows.append([cell.strip() for cell in lines[index].strip("|").split("|")])
        index += 1

    identifiers = [row[0] for row in rows]
    if len(set(identifiers)) != len(identifiers):
        duplicated = [key for key, count in Counter(identifiers).items() if count > 1]
        problems.append(f"{srs}: §10.1 索引有重复编号 {duplicated}")

    fr = [row for row in rows if row[0].startswith("FR-")]
    nfr = [row for row in rows if row[0].startswith("NFR-")]
    ac = [row for row in rows if row[0].startswith("AC-")]
    actual_parts = (len(rows), len(fr), len(nfr), len(ac))
    if declared != actual_parts:
        problems.append(
            f"{srs}:{count_line}: 计数写 共 {declared[0]} 条（FR {declared[1]} · NFR {declared[2]} · AC {declared[3]}），"
            f"索引实际 共 {actual_parts[0]} 行（FR {actual_parts[1]} · NFR {actual_parts[2]} · AC {actual_parts[3]}）"
        )

    # 3) 由索引派生出的 FR 状态分布 —— 能力规划说明书必须与它一致
    statuses = Counter(row[3] for row in fr)
    derived = (len(fr), statuses.get("✅", 0), statuses.get("🟡", 0), statuses.get("⬜", 0))

    if not capability.exists():
        return problems
    text = capability.read_text()

    match = re.search(r"\*\*(\d+) 条需求：(\d+) ✅ / (\d+) 🟡 / (\d+) ⬜\*\*", text)
    if match is None:
        problems.append(f"{capability}: 未找到能力地图的派生计数（形如「**N 条需求：a ✅ / b 🟡 / c ⬜**」）")
    else:
        declared_capability = tuple(int(value) for value in match.groups())
        if declared_capability != derived:
            problems.append(
                f"{capability}: 能力地图写 {declared_capability}（总 / ✅ / 🟡 / ⬜），"
                f"由 SRS 索引派生应为 {derived}"
            )

    match = re.search(r"差距的主题聚类（⬜ (\d+) 项", text)
    if match is not None and int(match.group(1)) != derived[3]:
        problems.append(f"{capability}: 第 3 节写 ⬜ {match.group(1)} 项，由 SRS 派生应为 ⬜ {derived[3]} 项")

    # 4) 第 2 节逐域计数（总数与三条状态都要对上，不只是总数）
    domain_status = Counter(
        (identifier.rsplit("-", 1)[0], row[3]) for identifier, row in zip(identifiers, rows) if identifier.startswith("FR-")
    )
    per_domain = Counter(identifier.rsplit("-", 1)[0] for identifier in identifiers if identifier.startswith("FR-"))
    row_pattern = re.compile(
        r"^\| \*\*(FR-[A-Z]+)\*\*[^|]*\|[^|]*\| (\d+) \| (\d+) \| (\d+) \| (\d+) \|",
        re.MULTILINE,
    )
    for domain, total, done, partial, todo in row_pattern.findall(text):
        expected = (
            per_domain.get(domain, 0),
            domain_status.get((domain, "✅"), 0),
            domain_status.get((domain, "🟡"), 0),
            domain_status.get((domain, "⬜"), 0),
        )
        declared_row = (int(total), int(done), int(partial), int(todo))
        if declared_row != expected:
            problems.append(
                f"{capability}: 第 2 节 {domain} 写 {declared_row}（总 / ✅ / 🟡 / ⬜），"
                f"由 SRS 索引数出 {expected}"
            )
        per_domain.pop(domain, None)
    if per_domain:
        problems.append(f"{capability}: 第 2 节缺少这些功能域的行 {sorted(per_domain)}")

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

    problems.extend(check_requirement_counts())

    if problems:
        print(f"❌ 表格校验失败（{len(problems)} 处）：")
        for problem in problems:
            print("   " + problem)
        return 1

    print(f"✅ 表格校验通过（{len(targets)} 个文件）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
