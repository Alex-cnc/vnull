#!/usr/bin/env python3
"""校验 §10.1 索引表的状态列与正文定义行的状态列一致。

为什么需要这个门禁：`Scripts/report-requirements.py` 的盘点**读的是索引表**，
而每轮开发改的是**正文定义行**。两边一旦漂移，盘点就会给出错误结论 ——
本轮就发生过：定义行已改成 ✅，索引行还写着 🟡，于是"完成度"看起来没动。
手抄状态必然漂移，所以这里用脚本钉住。
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SPEC = ROOT / "Docs" / "需求规范书.md"
STATUSES = "✅🟡⬜➖"


def section(lines: list[str], start_marker: str, end_marker: str) -> list[str]:
    start = next(i for i, l in enumerate(lines) if l.startswith(start_marker))
    end = next(i for i, l in enumerate(lines) if i > start and l.startswith(end_marker))
    return lines[start:end]


def main() -> int:
    lines = SPEC.read_text(encoding="utf-8").split("\n")

    # ── §10.1 索引表：| ID | 域 | 优先级 | 状态 |
    index: dict[str, tuple[str, int]] = {}
    for offset, line in enumerate(section(lines, "### 10.1", "### 10.2")):
        fields = [f.strip() for f in line.strip().strip("|").split("|")]
        if len(fields) != 4 or not re.fullmatch(r"(FR|NFR|AC)-[A-Z]+-\d+", fields[0]):
            continue
        # 与正文一致：状态按**首字符**判定，允许 `🟡（待验证）` 这类带括号的写法。
        if not fields[3] or fields[3][0] not in STATUSES:
            continue
        index[fields[0]] = (fields[3][0], offset)

    # ── 正文定义行
    #    FR 行 6 列：| ID | 描述 | 优先级 | 复杂度 | 状态 | 证据 |
    #    NFR 行 5 列：| ID | 描述 | 优先级 | 状态 | 证据 |   （NFR 没有"复杂度"）
    #    因此状态位置不固定：从第 4 列起找**第一个以状态符号开头**的列。
    defined: dict[str, tuple[str, int]] = {}
    for number, line in enumerate(lines, start=1):
        fields = [f.strip() for f in line.strip().strip("|").split("|")]
        if len(fields) < 5 or not re.fullmatch(r"(FR|NFR)-[A-Z]+-\d+", fields[0]):
            continue
        status = next((f for f in fields[3:6] if f and f[0] in STATUSES), None)
        if status is None:
            continue
        defined[fields[0]] = (status[0], number)

    problems: list[str] = []
    for ident, (status, line_number) in sorted(defined.items()):
        if ident not in index:
            problems.append(f"定义行 {ident}（第 {line_number} 行）在 §10.1 索引表里找不到")
            continue
        index_status = index[ident][0]
        # 允许索引记"主状态"、定义行带括号补充：🟡（UI 已接，待人工验证）算 🟡。
        if index_status != status[0]:
            problems.append(
                f"{ident}: 定义行（第 {line_number} 行）为 {status}，"
                f"而 §10.1 索引表为 {index_status}"
            )

    # AC（验收标准）的正文在 §5，用的是另一种表格式，不在这里比对；
    # 只对 FR / NFR 要求"索引表里每一条都能找到定义行"。
    missing = [
        ident for ident in index
        if ident not in defined and ident.split("-")[0] in ("FR", "NFR")
    ]
    if missing:
        problems.append(f"索引表里有 {len(missing)} 条 FR/NFR 在正文找不到定义行：{', '.join(sorted(missing)[:5])}…")

    if problems:
        print(f"❌ 状态一致性校验失败（{len(problems)} 处）：")
        for item in problems:
            print(f"   {item}")
        print("\n提示：改需求状态时要**同时**改正文定义行与 §10.1 索引表（盘点读的是索引表）。")
        return 1

    print(f"✅ 状态一致性校验通过（索引表 {len(index)} 条 / 正文定义行 {len(defined)} 条，状态一致）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
