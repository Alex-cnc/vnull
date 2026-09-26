#!/usr/bin/env python3
"""生成《需求规范书》§10.10 的「平台等价矩阵」。

为什么要机械生成（而不是手写两张表）：
    手写的双平台状态表**必然漂移** —— 一边改了另一边忘了改，而且没人会发现。
    本工程已经有这条纪律（"能力状态不手工维护、一律由状态列派生"），这里把它推到双平台：
    · macOS 状态：取自 §10.1 需求索引（单一事实来源，不由本脚本维护）；
    · Linux 状态：取自 Docs/平台实现状态.json（Linux 侧唯一的维护点，默认 ⬜）；
    · 表格由本脚本重写，位置由 §10.10 里的 BEGIN/END 标记夹住。

用法：
    python3 Scripts/gen-platform-parity.py            # 重写表格
    python3 Scripts/gen-platform-parity.py --check    # 只检查是否与现状一致（CI/闸门用）
"""

from __future__ import annotations

import json
import pathlib
import re
import sys

SRS = pathlib.Path("Docs/需求规范书.md")
STATUS = pathlib.Path("Docs/平台实现状态.json")
BEGIN = "<!-- BEGIN platform-parity -->"
END = "<!-- END platform-parity -->"

DOMAIN_LABEL = {
    "FR-CONN": "连接与凭据",
    "FR-EDIT": "SQL 编辑与执行",
    "FR-EXEC": "执行与事务",
    "FR-META": "对象浏览与元数据",
    "FR-RES": "结果集与导出",
    "FR-DATA": "数据编辑与写回",
    "FR-DDL": "表结构与 DDL",
    "FR-DIAG": "性能与诊断",
    "FR-SESS": "会话与服务器管理",
    "FR-IO": "导入导出与备份",
    "FR-DRV": "驱动与方言兼容",
    "FR-BLD": "构建与工具链",
    "FR-CLI": "命令行",
    "FR-AI": "AI 智能体",
    "FR-PLUG": "插件装配（宿主侧）",
}


def cells(line: str) -> list[str]:
    text = line.strip()
    if text.startswith("|"):
        text = text[1:]
    if text.endswith("|"):
        text = text[:-1]
    return [part.strip() for part in text.split("|")]


def clean(text: str) -> str:
    text = re.sub(r"\*\*(.+?)\*\*", r"\1", text)
    text = text.replace("`", "")
    return re.sub(r"\s+", " ", text).strip()


def load() -> tuple[list[tuple[str, str, str, str]], dict[str, str], str]:
    """返回 [(编号, 域, macOS 状态, 需求摘要)], Linux 状态表, 默认状态。"""
    lines = SRS.read_text(encoding="utf-8").splitlines()

    # **只读指定的两个区段**：索引取 §10.1，摘要取 §3/§4（正文）。
    # 必须限定范围 —— 否则本脚本会把自己刚写进 §10.10 的表（同样是 4 列）当成索引行，
    # 于是"生成 → 校验"不一致（自吞自己的输出）。第一次就是这么错的。
    def slice_between(start_marker: str, end_marker: str) -> list[str]:
        try:
            start = next(i for i, line in enumerate(lines) if line.startswith(start_marker))
            end = next(i for i, line in enumerate(lines) if i > start and line.startswith(end_marker))
        except StopIteration:
            return []
        return lines[start:end]

    index_lines = slice_between("### 10.1", "### 10.2")
    body_lines = lines[: next((i for i, line in enumerate(lines) if line.startswith("## 10.")), len(lines))]

    index: dict[str, str] = {}
    summaries: dict[str, str] = {}
    for line in index_lines:
        if not line.startswith("|"):
            continue
        row = cells(line)
        if len(row) == 4 and re.match(r"^FR-", row[0]):
            index[row[0]] = row[3]
    for line in body_lines:
        if not line.startswith("|"):
            continue
        row = cells(line)
        if len(row) >= 6 and re.match(r"^FR-", row[0]) and row[0] not in summaries:
            summaries[row[0]] = clean(row[1])

    payload = json.loads(STATUS.read_text(encoding="utf-8"))
    default = payload.get("default", "⬜")
    overrides = payload.get("linux", {})
    rows = [(key, index[key], summaries.get(key, "")) for key in sorted(index)]
    return rows, overrides, default


def render(rows: list[tuple[str, str, str]], overrides: dict[str, str], default: str) -> str:
    def group_of(identifier: str) -> str:
        parts = identifier.split("-")
        return "-".join(parts[:2])

    # 分域统计（让人一眼看出 Linux 侧进度集中在哪）
    order: list[str] = []
    for identifier, _, _ in rows:
        group = group_of(identifier)
        if group not in order:
            order.append(group)

    out: list[str] = []
    out.append(f"> 共 {len(rows)} 条功能需求。**macOS** 状态取自 §10.1；**Linux** 状态取自 `Docs/平台实现状态.json`。")
    out.append("")
    for group in order:
        members = [(i, mac, text) for i, mac, text in rows if group_of(i) == group]
        done = sum(1 for i, _, _ in members if overrides.get(i, default) == "✅")
        same = sum(1 for i, mac, _ in members if overrides.get(i, default) == mac)
        out.append(f"**{DOMAIN_LABEL.get(group, group)}**（{len(members)} 条，Linux 已对齐 {same} 条）")
        out.append("")
        out.append("| 编号 | 需求摘要 | macOS | Linux |")
        out.append("|---|---|---|---|")
        for identifier, mac, text in members:
            linux = overrides.get(identifier, default)
            flag = "" if linux == mac else " ⚠️"
            summary = text[:52] + ("…" if len(text) > 52 else "")
            out.append(f"| {identifier} | {summary} | {mac} | {linux}{flag} |")
        out.append("")
    return "\n".join(out).rstrip() + "\n"


def main() -> int:
    check_only = "--check" in sys.argv
    rows, overrides, default = load()
    table = render(rows, overrides, default)

    text = SRS.read_text(encoding="utf-8")
    if BEGIN not in text or END not in text:
        print(f"❌ {SRS} 里找不到 {BEGIN} / {END} 标记")
        return 1
    head, rest = text.split(BEGIN, 1)
    _, tail = rest.split(END, 1)
    updated = f"{head}{BEGIN}\n{table}{END}{tail}"

    if check_only:
        if updated == text:
            print(f"✅ 平台等价矩阵与现状一致（{len(rows)} 条）")
            return 0
        print("❌ 平台等价矩阵与现状不一致，请运行 python3 Scripts/gen-platform-parity.py")
        return 1

    SRS.write_text(updated, encoding="utf-8")
    print(f"✅ 已重写 §10.10 平台等价矩阵（{len(rows)} 条；Linux 侧显式状态 {len(overrides)} 条）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
