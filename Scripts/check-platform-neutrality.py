#!/usr/bin/env python3
"""平台中立性校验（两档棘轮）：需求正文不得绑平台，实现记录允许绑。

存在的理由：
    产品要在 macOS 与 Linux 上保持一致（平台与语言不同），但**本文件最初是一份 macOS
    实现记录** —— 它的"状态 / 证据"列里塞满了框架类型名、文件路径与平台 API。若不管，
    Linux 侧会把实现细节当需求照抄，两平台也就谈不上一致。

    第一版按"行"一刀切，把 190 处变更记录与 43 处证据列也算成负债（实测 246 处），
    既没法收敛到 0，也逼着人删实现记录。**第二版按"这句话会不会被当需求照抄"分档**：

      严格档（配额 0，超出即失败）
        · 需求条目的「需求」列（FR / NFR / DR 行）
        · §1.2 产品目标、§1.3 范围的正文
      报告档（只统计不拦截）
        · 「状态 / 证据 / 验收要点」列、其他表格（现状 / 模块 / 里程碑）、§9 风险记录、
          §10 各附录（追溯 / 环境 / 变更 / 任务 / 对标 / 差异 / 矩阵）—— 这些地方本来就
          在记 macOS 基线做了什么

    需要显式豁免时，在该行行尾加 `<!-- platform-ok: 理由 -->`。
    设计文档（概要设计 / 能力规划）整体只报告：它们本来就要写平台实现
    （见概要设计 §3 的【macOS】标注）。

用法：
    python3 Scripts/check-platform-neutrality.py              # 校验（闸门）
    python3 Scripts/check-platform-neutrality.py --report     # 看两档分布与命中样例
    python3 Scripts/check-platform-neutrality.py --update-baseline
"""

from __future__ import annotations

import json
import pathlib
import re
import sys

SRS = "Docs/需求规范书.md"
TARGETS = [SRS, "Docs/概要设计.md", "Docs/产品能力规划说明书.md"]
BASELINE = pathlib.Path("Scripts/platform-neutrality-baseline.json")

TERMS = {
    "Swift/Apple 语言与框架": r"\b(Swift|SwiftUI|AppKit|CoreGraphics|XCTest|Foundation|Combine)\b",
    "Objective-C / Cocoa 类型": r"\bNS[A-Z][A-Za-z]+\b|\bWKWebView\b|\bCF[A-Z][A-Za-z]+\b",
    "Apple 平台机制": r"(Keychain|钥匙串|entitlements?|App Sandbox|Info\.plist|XcodeGen|xcodebuild|ad-hoc|公证|Developer ID)",
    "macOS 专属 API/概念": r"(security-scoped|withSecurityScope|forkpty|TIOCSWINSZ|NSOpenPanel|NSTableView|NSTextView|\.icns)",
    "Swift 生态依赖": r"\b(PostgresNIO|MySQLNIO|SwiftNIO|swift-tools|SwiftPM|Package\.swift|Vendor/)\b",
}

EXEMPT_MARK = "platform-ok"

# 需求条目行：第一列是编号，第二列是需求正文（严格档），其余列是实现证据（报告档）
REQUIREMENT_ROW = re.compile(r"^(FR|NFR|DR|IR|AC)-")

# 严格档里的中立正文小节
NEUTRAL_PROSE = ("### 1.2 ", "### 1.3 ")

# 报告档区域
RISK_SECTION = ("## 9. ",)
APPENDIX_SECTIONS = ("### 10.",)

# 桶 → (显示名, 是否严格)
BUCKETS = {
    "requirement-cell": ("需求条目的「需求」列（FR / NFR / DR）", True),
    "neutral-prose": ("§1.2 产品目标 / §1.3 范围正文", True),
    "evidence-cell": ("「状态 / 证据 / 验收要点」列", False),
    "table-record": ("其他表格（现状 / 模块 / 里程碑 / 用例）", False),
    "risk": ("§9 风险记录", False),
    "appendix": ("§10 附录（追溯 / 环境 / 变更 / 任务 / 差异 / 矩阵）", False),
    "other-prose": ("其他正文与说明（§0 约定 / §7 验收摘要 / §8 计划等）", False),
}
STRICT_BUCKETS = tuple(name for name, (_, strict) in BUCKETS.items() if strict)


def section_lines(lines: list[str], prefixes: tuple[str, ...]) -> set[int]:
    """返回以给定标题开头的所有小节覆盖的行号（到下一个同级或更高级标题为止）。"""
    covered: set[int] = set()
    active_level: int | None = None
    for index, line in enumerate(lines):
        heading = re.match(r"^(#{2,4}) ", line)
        if heading:
            if any(line.startswith(prefix) for prefix in prefixes):
                active_level = len(heading.group(1))
                continue
            if active_level is not None and len(heading.group(1)) <= active_level:
                active_level = None
                continue
        if active_level is not None:
            covered.add(index)
    return covered


def classify(lines: list[str]) -> list[tuple[int, str, str]]:
    """把每一行归到一个桶；跳过显式豁免行与注释行。"""
    risk = section_lines(lines, RISK_SECTION)
    appendix = section_lines(lines, APPENDIX_SECTIONS)
    neutral = section_lines(lines, NEUTRAL_PROSE)

    verdict: list[tuple[int, str, str]] = []
    for index, line in enumerate(lines):
        if EXEMPT_MARK in line or line.strip().startswith("<!--"):
            continue
        if index in risk:
            bucket = "risk"
        elif index in appendix:
            bucket = "appendix"
        elif line.startswith("|"):
            cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
            bucket = "requirement-cell" if len(cells) >= 3 and REQUIREMENT_ROW.match(cells[0]) else "table-record"
        elif index in neutral:
            bucket = "neutral-prose"
        else:
            bucket = "other-prose"
        verdict.append((index, bucket, line))
    return verdict


def scan(path: pathlib.Path) -> tuple[dict[str, dict[str, int]], list[tuple[int, int, str, str]]]:
    """返回 (按桶的族计数, 严格档命中样例)。"""
    lines = path.read_text(encoding="utf-8").splitlines()
    counts: dict[str, dict[str, int]] = {}
    samples: list[tuple[int, int, str, str]] = []

    for index, bucket, line in classify(lines):
        strict = bucket in STRICT_BUCKETS
        if bucket == "requirement-cell":
            cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
            text = cells[1]                       # 只查「需求」列，证据列不拦
        else:
            text = line
        for label, pattern in TERMS.items():
            for match in re.finditer(pattern, text):
                counts.setdefault(bucket, {})
                counts[bucket][label] = counts[bucket].get(label, 0) + 1
                if strict and len(samples) < 20:
                    samples.append((index + 1, len(samples), label, match.group(0)))
    return counts, samples


def totals(counts: dict[str, dict[str, int]], strict: bool) -> dict[str, int]:
    merged: dict[str, int] = {}
    for bucket, labels in counts.items():
        if (bucket in STRICT_BUCKETS) != strict:
            continue
        for label, count in labels.items():
            merged[label] = merged.get(label, 0) + count
    return merged


def main() -> int:
    arguments = set(sys.argv[1:])
    results = {}
    for target in TARGETS:
        path = pathlib.Path(target)
        if not path.exists():
            print(f"跳过：{target} 不存在")
            continue
        results[target] = scan(path)

    if "--report" in arguments:
        for target, (counts, samples) in results.items():
            strict = sum(totals(counts, True).values())
            loose = sum(totals(counts, False).values())
            print(f"{target}：严格档 {strict} 处 / 报告档 {loose} 处")
            for bucket in BUCKETS:
                labels = counts.get(bucket)
                if not labels:
                    continue
                name, is_strict = BUCKETS[bucket]
                print(f"   [{'严格' if is_strict else '报告'}] {name}：{sum(labels.values())}")
                for label, count in sorted(labels.items(), key=lambda item: -item[1]):
                    print(f"          {count:>4}  {label}")
            for line, _, label, text in samples[:8]:
                print(f"        :{line}  {label} → {text}")
        return 0

    strict_counts = results.get(SRS, ({}, []))[0]
    strict = totals(strict_counts, True)
    loose = totals(strict_counts, False)

    if "--update-baseline" in arguments:
        BASELINE.write_text(
            json.dumps(
                {
                    "comment": "平台中立性棘轮基线：需求规范书**严格档**（需求列 + §1.2/§1.3 正文）"
                               "的平台专属词数量只能降不能升，目标 0。报告档（证据列 / 其他表格 / §9 / "
                               "§10 附录）只统计不拦截，不在此处记账。",
                    "totals": strict,
                },
                ensure_ascii=False, indent=2, sort_keys=True,
            ) + "\n",
            encoding="utf-8",
        )
        print(f"✅ 基线已更新：严格档 {sum(strict.values())} 处（报告档 {sum(loose.values())} 处，不拦截）")
        return 0

    baseline = json.loads(BASELINE.read_text(encoding="utf-8")) if BASELINE.exists() else {"totals": {}}
    allowed = baseline.get("totals", {})
    problems = [
        f"{label}: {allowed.get(label, 0)} → {count}"
        for label, count in strict.items()
        if count > allowed.get(label, 0)
    ]

    for target, (counts, _) in results.items():
        if target != SRS:
            print(f"  {target}：报告档 {sum(totals(counts, False).values())} 处（仅报告）")
            continue
        print(f"  {target}：严格档 {sum(strict.values())} 处（配额 0），报告档 {sum(loose.values())} 处（允许）")
        for bucket in BUCKETS:
            labels = counts.get(bucket)
            if labels and bucket not in STRICT_BUCKETS:
                print(f"     · {BUCKETS[bucket][0]} {sum(labels.values())} 处")

    if problems:
        print(f"❌ 平台中立性校验失败（严格档比基线更差，{len(problems)} 类）：")
        for problem in problems:
            print("   " + problem)
        print("   提示：需求正文只写产品行为；实现细节写进「状态/证据」列，或挪到 §10.9；")
        print("         确有必要保留时在行尾加 <!-- platform-ok: 理由 -->。")
        return 1

    print(f"✅ 平台中立性校验通过（严格档 {sum(strict.values())} 处 / 报告档 {sum(loose.values())} 处）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
