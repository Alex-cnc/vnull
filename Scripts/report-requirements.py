#!/usr/bin/env python3
"""从《需求规范书》派生"还有什么没完成"的盘点报告。

为什么要有这个脚本，而不是手抄一遍：
    需求的状态列是**单一事实来源**（本工程的一条硬约定：能力状态不手工维护、
    一律由 SRS 派生）。手抄盘点会和状态列漂移，而且没人会发现。
    所以盘点也机械生成。

输出四段：
    1. 总量与状态分布（FR / NFR / AC 分开）
    2. 分域完成度
    3. ⬜ 未开始清单（带需求摘要）
    4. 🟡 部分完成 / 待验收清单（并标出**阻塞条件**里能识别的关键词）
    5. 未完成的任务项（§10.7 与 §10.7.1 里未勾选的 T-*）

用法：
    python3 Scripts/report-requirements.py            # 全部
    python3 Scripts/report-requirements.py --open     # 只看 ⬜ 与 🟡
"""

from __future__ import annotations

import pathlib
import re
import sys

SRS = pathlib.Path("Docs/需求规范书.md")

PENDING = "⬜"
PARTIAL = "🟡"
DONE = "✅"

# 能识别出的"被外部条件卡住"的关键词 —— 用来把"没做"和"做不了"分开
BLOCKER_HINTS = [
    "阻塞条件", "需可达实例", "需模型端点", "待实测", "待真机", "待验证",
    "需要实例", "无实例", "需实例", "需提供", "待后续", "依赖选型",
    "未执行", "无模型端点",
]


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
    text = re.sub(r"\s+", " ", text)
    return text.strip()


def load() -> tuple[dict[str, dict], dict[str, dict], list[tuple[str, list[str]]]]:
    lines = SRS.read_text(encoding="utf-8").splitlines()
    index: dict[str, dict] = {}
    definitions: dict[str, dict] = {}
    open_tasks: list[tuple[str, list[str]]] = []

    for line in lines:
        if line.startswith("- [ ]"):
            open_tasks.append((clean(line[5:]), []))
            continue
        if line.startswith("  - [ ]") and open_tasks:
            open_tasks[-1][1].append(clean(line[7:]))
            continue
        if not line.startswith("|"):
            continue
        row = cells(line)
        if not row or not re.match(r"^(FR|NFR|AC|DR|R|T)-[A-Z0-9]", row[0]):
            continue
        identifier = row[0]
        if len(row) == 4 and re.match(r"^\d+(\.\d+)?", row[1]):
            index[identifier] = {"domain": row[1], "layer": row[2], "status": row[3]}
        elif len(row) >= 5 and identifier not in definitions:
            # FR: 编号 | 需求 | 层次 | 优先级 | 状态 | 验收要点
            # NFR: 编号 | 需求 | 层次 | 状态 | 验证方式
            status_cell = row[4] if len(row) >= 6 else row[3]
            definitions[identifier] = {
                "text": clean(row[1]),
                "status": status_cell,
                "notes": clean(row[-1])[:400],
            }
    return index, definitions, open_tasks


MARKERS = ("✅", "🟡", "⬜", "➖")


def normalize_status(cell: str) -> str:
    """把「✅ 89/89（2026-09-21）」「🟡（待验证）」这类**带后缀**的状态格归一成标记本身。

    为什么需要：状态格里常常跟着证据（"✅ 28/28"）或限定（"🟡（待验证）"），
    而按整格相等去比对就会把绝大多数条目判成"识别不出" —— 那等于盘点结果不可信。
    """
    text = (cell or "").strip()
    for marker in MARKERS:
        if text.startswith(marker):
            return marker
    return text[:8] if text else "?"


def status_of(identifier: str, index: dict, definitions: dict) -> str:
    if identifier in index:
        return normalize_status(index[identifier]["status"])
    for symbol in (DONE, PARTIAL, PENDING):
        if identifier in definitions and definitions[identifier]["status"].startswith(symbol):
            return symbol
    entry = definitions.get(identifier, {})
    return normalize_status(entry.get("status", ""))


def blocker_note(identifier: str, definitions: dict) -> str:
    notes = definitions.get(identifier, {}).get("notes", "")
    for hint in BLOCKER_HINTS:
        if hint in notes:
            position = notes.find(hint)
            return notes[max(0, position - 30):position + 60].strip()
    return ""


def main() -> int:
    open_only = "--open" in sys.argv
    index, definitions, open_tasks = load()

    identifiers = sorted(index.keys())
    groups: dict[str, list[str]] = {"FR": [], "NFR": [], "AC": []}
    for identifier in identifiers:
        for prefix in groups:
            if identifier.startswith(prefix + "-"):
                groups[prefix].append(identifier)
                break

    print("=" * 78)
    print("需求完成度盘点（数据来源：Docs/需求规范书.md，机械派生）")
    print("=" * 78)
    for prefix in ("FR", "NFR", "AC"):
        members = groups[prefix]
        if not members:
            continue
        counts = {symbol: 0 for symbol in (DONE, PARTIAL, PENDING)}
        unknown = 0
        for identifier in members:
            status = status_of(identifier, index, definitions)
            if status in counts:
                counts[status] += 1
            else:
                unknown += 1
        total = len(members)
        print(
            f"{prefix:<4} 共 {total:>3} 条："
            f"{DONE} {counts[DONE]:>3}   {PARTIAL} {counts[PARTIAL]:>3}   {PENDING} {counts[PENDING]:>3}"
            + (f"   （状态无法识别 {unknown}）" if unknown else "")
        )

    fr_total = len(groups["FR"])
    fr_done = sum(1 for i in groups["FR"] if status_of(i, index, definitions) == DONE)
    if fr_total:
        print(f"\n功能需求完成率：{fr_done}/{fr_total} = {fr_done / fr_total * 100:.0f}%")

    # 分域
    domains: dict[str, dict[str, int]] = {}
    for identifier in groups["FR"]:
        domain = index.get(identifier, {}).get("domain", "?")
        bucket = domains.setdefault(domain, {DONE: 0, PARTIAL: 0, PENDING: 0, "total": 0})
        bucket["total"] += 1
        bucket[status_of(identifier, index, definitions)] = bucket.get(
            status_of(identifier, index, definitions), 0
        ) + 1

    print("\n" + "-" * 78)
    print(f"{'功能域':<28}{'总':>4}{'✅':>5}{'🟡':>5}{'⬜':>5}")
    print("-" * 78)
    for domain in sorted(domains, key=lambda d: -domains[d][PENDING]):
        bucket = domains[domain]
        print(f"{domain:<28}{bucket['total']:>4}{bucket[DONE]:>5}{bucket[PARTIAL]:>5}{bucket[PENDING]:>5}")

    def listing(title: str, symbol: str) -> None:
        members = [i for i in groups["FR"] + groups["NFR"] if status_of(i, index, definitions) == symbol]
        print("\n" + "=" * 78)
        print(f"{title}（{len(members)} 条）")
        print("=" * 78)
        for identifier in members:
            domain = index.get(identifier, {}).get("domain", "")
            text = definitions.get(identifier, {}).get("text", "")
            print(f"\n{identifier}  [{domain}]")
            print(f"  {text[:150]}")
            note = blocker_note(identifier, definitions)
            if symbol == PARTIAL and note:
                print(f"  ⛔ 阻塞/待验：…{note}…")

    if not open_only:
        listing("未开始（⬜）", PENDING)
    listing("部分完成 / 待验收（🟡）", PARTIAL)

    if open_tasks:
        print("\n" + "=" * 78)
        print(f"未完成的任务（{len(open_tasks)} 个，括号内为未勾选子项数）")
        print("=" * 78)
        for task, subtasks in open_tasks:
            print(f"  [{len(subtasks):>2}] {task[:120]}")
            if not open_only:
                for subtask in subtasks:
                    print(f"        · {subtask[:140]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
