#!/usr/bin/env python3
"""设计令牌防回潮校验（棘轮式 / ratchet）。

背景：外观改造前 App/ 里量出来这些——显式字号只有 3 个、padding 里 `2` 出现 139 次
并混着 1 / 3 / 6 / 10 / 12 / 20 / 150、颜色是零散的系统色加裸 `Color.orange/.red/.blue`。
这类"看着不精致"的来源不是一次写坏的，而是**一处处加出来的**；
所以约束也必须是逐处生效的，不能只靠一次性的美术活。

做法：**棘轮**（只能变好，不能变坏）。
    1. 本脚本扫描 App/ 下所有 .swift，按规则统计违规数；
    2. 与基线 `Scripts/design-token-baseline.json` 比较：
       任何文件任何规则的违规数**不得高于**基线，总数也不得升高；
    3. 迁移过程中违规自然减少，用 `--update-baseline` 把基线往下拧一格（只允许调低，
       需要放宽时必须显式 `--force`，好让"放宽"这件事在 code review 里看得见）。

规则：
    bare-color    裸颜色（Color.orange / NSColor.systemRed / NSColor.labelColor / .separatorColor…）
    bare-font     裸字号（.font(.system(size: 14)) / NSFont.systemFont(ofSize: 14)…）
    bare-spacing  裸间距（.padding(6) / VStack(spacing: 3)…）
    bare-radius   裸圆角（cornerRadius: 5）
    bare-hairline 裸发丝线（写死 0.5 / 1.0 的线宽）—— 目前只警告不计入基线

豁免：行尾加 `// token-ok` 注释即可跳过该行（必须在注释里写明理由）。

用法：
    python3 Scripts/check-design-tokens.py                # 校验（CI / 提交前）
    python3 Scripts/check-design-tokens.py --report       # 只看统计
    python3 Scripts/check-design-tokens.py --update-baseline
"""

from __future__ import annotations

import json
import pathlib
import re
import sys

ROOT = pathlib.Path("App")
BASELINE = pathlib.Path("Scripts/design-token-baseline.json")

SPACING_SCALE = {0, 1, 2, 4, 8, 12, 16, 24, 32}
FONT_SCALE = {11, 12, 13, 15, 17}
RADIUS_SCALE = {1, 4, 6, 8, 10}

BARE_COLOR = re.compile(
    # 具体色名（橙 / 红 / 蓝…）
    r"\b(?:Color|NSColor)\.(?:orange|red|blue|yellow|green|purple|pink|gray|grey|brown|cyan|indigo|mint|teal)\b"
    r"|\bNSColor\.system(?:Red|Orange|Yellow|Green|Blue|Purple|Pink|Gray|Brown|Teal|Indigo|Mint|Cyan)\b"
    r"|\bNSColor\(calibratedRed:|\bNSColor\(deviceRed:"
    # 系统的**语义色**也算裸色：设计令牌里有对应的 TextTone / Surface / StatusTone，
    # 混用系统的 labelColor / separatorColor 会让某一块与相邻面板"差一点点"，
    # 而"差一点点"正是这次外观改造要消灭的东西（结果网格原先就漏在这条规则外）。
    r"|\bNSColor\.(?:labelColor|secondaryLabelColor|tertiaryLabelColor|quaternaryLabelColor)\b"
    r"|\bNSColor\.(?:separatorColor|gridColor|controlBackgroundColor|windowBackgroundColor|textBackgroundColor)\b"
    r"|\.(?:secondaryLabelColor|tertiaryLabelColor|separatorColor)\b"
)
FONT_SIZE = re.compile(
    r"\.system\(size:\s*([0-9.]+)|systemFont\(ofSize:\s*([0-9.]+)|monospacedSystemFont\(ofSize:\s*([0-9.]+)"
    r"|monospacedDigitSystemFont\(ofSize:\s*([0-9.]+)"
)
PADDING = re.compile(r"\.padding\(\s*(?:\.\w+\s*,\s*)?([0-9.]+)\s*\)")
STACK_SPACING = re.compile(r"\b(?:VStack|HStack|LazyVStack|LazyHStack|Grid)\([^)]*spacing:\s*([0-9.]+)")
FRAME_SPACING = re.compile(r"\.padding\(\s*\.\w+\s*,\s*([0-9.]+)\s*\)|\.offset\([^)]*[xy]:\s*([0-9.]+)")
CORNER = re.compile(r"cornerRadius:\s*([0-9.]+)|RoundedRectangle\(cornerRadius:\s*([0-9.]+)")
HAIRLINE = re.compile(r"lineWidth:\s*([0-9.]+)|\.frame\(height:\s*0?\.5\b")


def numbers(match: re.Match | None) -> list[float]:
    if match is None:
        return []
    return [float(group) for group in match.groups() if group is not None]


def scan_file(path: pathlib.Path) -> dict[str, int]:
    counts: dict[str, int] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if line.startswith("//") or line.startswith("///") or line.startswith("*"):
            continue
        if "token-ok" in raw:
            continue

        def bump(rule: str) -> None:
            counts[rule] = counts.get(rule, 0) + 1

        if BARE_COLOR.search(raw) and "Color.clear" not in raw:
            bump("bare-color")

        if any(value not in FONT_SCALE for value in numbers(FONT_SIZE.search(raw)) if value):
            bump("bare-font")

        spacing_hits = numbers(PADDING.search(raw)) + numbers(STACK_SPACING.search(raw))
        if any(value not in SPACING_SCALE for value in spacing_hits):
            bump("bare-spacing")

        if any(value not in RADIUS_SCALE for value in numbers(CORNER.search(raw))):
            bump("bare-radius")

    return counts


EXEMPT_MARKER = "token-ok-file:"


def exempt_reason(path: pathlib.Path) -> str | None:
    """整文件豁免：文件头 5 行内写 `// token-ok-file: 理由`。

    逃逸口必须**可见**：豁免文件会在 --report 里单独列出，
    免得"加一行注释就悄悄无视规矩"变成常规操作。
    """
    head = path.read_text(encoding="utf-8").splitlines()[:5]
    for line in head:
        if EXEMPT_MARKER in line:
            return line.split(EXEMPT_MARKER, 1)[1].strip()
    return None


def scan() -> tuple[dict[str, dict[str, int]], dict[str, str]]:
    result: dict[str, dict[str, int]] = {}
    exempt: dict[str, str] = {}
    for path in sorted(ROOT.rglob("*.swift")):
        reason = exempt_reason(path)
        if reason is not None:
            exempt[str(path)] = reason
            continue
        counts = scan_file(path)
        if counts:
            result[str(path)] = counts
    return result, exempt


def totals(scan_result: dict[str, dict[str, int]]) -> dict[str, int]:
    total: dict[str, int] = {}
    for counts in scan_result.values():
        for rule, value in counts.items():
            total[rule] = total.get(rule, 0) + value
    return total


def load_baseline() -> dict:
    if not BASELINE.exists():
        return {"files": {}, "totals": {}}
    return json.loads(BASELINE.read_text(encoding="utf-8"))


def main() -> int:
    arguments = set(sys.argv[1:])
    current, exempt = scan()
    current_totals = totals(current)
    baseline = load_baseline()

    if "--report" in arguments:
        print("当前违规统计（App/）：")
        for rule in sorted(current_totals):
            print(f"  {rule:<14} {current_totals[rule]:>5}")
        worst = sorted(current.items(), key=lambda item: -sum(item[1].values()))[:8]
        if exempt:
            print("整文件豁免（终端语义一类，不属于界面令牌）：")
            for path, reason in exempt.items():
                print(f"       {path} — {reason}")
        print("最集中的文件：")
        for path, counts in worst:
            print(f"  {sum(counts.values()):>4}  {path}  {counts}")
        return 0

    if "--update-baseline" in arguments:
        # 首次建立基线：允许直接写入（此后只能往下拧）
        if not BASELINE.exists():
            BASELINE.write_text(
                json.dumps(
                    {"comment": "设计令牌棘轮基线：违规数只能降不能升（--update-baseline 下调）",
                     "files": current, "totals": current_totals},
                    ensure_ascii=False, indent=2, sort_keys=True,
                ) + "\n",
                encoding="utf-8",
            )
            print(f"✅ 首次建立基线：{sum(current_totals.values())} 处待迁移 {current_totals}")
            return 0
        old_totals = baseline.get("totals", {})
        relaxed = {
            rule: value for rule, value in current_totals.items()
            if value > old_totals.get(rule, 0)
        }
        if relaxed and "--force" not in arguments:
            print("❌ 这些规则比基线更差了，拒绝写入（如确要放宽请加 --force，让它在 review 里可见）：")
            for rule, value in relaxed.items():
                print(f"   {rule}: {old_totals.get(rule, 0)} → {value}")
            return 1
        BASELINE.write_text(
            json.dumps(
                {"comment": "设计令牌棘轮基线：违规数只能降不能升（--update-baseline 下调）",
                 "files": current, "totals": current_totals},
                ensure_ascii=False, indent=2, sort_keys=True,
            ) + "\n",
            encoding="utf-8",
        )
        print(f"✅ 基线已更新：{sum(current_totals.values())} 处待迁移")
        return 0

    # 校验
    problems: list[str] = []
    for path, counts in current.items():
        allowed = baseline.get("files", {}).get(path, {})
        for rule, value in counts.items():
            if value > allowed.get(rule, 0):
                problems.append(f"{path}: {rule} {allowed.get(rule, 0)} → {value}")
    for rule, value in current_totals.items():
        allowed = baseline.get("totals", {}).get(rule, 0)
        if value > allowed:
            problems.append(f"合计 {rule} {allowed} → {value}")

    if problems:
        print(f"❌ 设计令牌校验失败（{len(problems)} 处比基线更差）：")
        for problem in problems:
            print("   " + problem)
        print("   提示：能改就用令牌；确实要保留原样时在行尾加 `// token-ok` 并写明理由。")
        return 1

    remaining = sum(current_totals.values())
    exempt_note = f"，另有 {len(exempt)} 个豁免文件" if exempt else ""
    print(f"✅ 令牌校验通过（未比基线更差；仍有 {remaining} 处待迁移：{current_totals}{exempt_note}）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
