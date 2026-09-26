#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""**「当前语言」只有一个来源**的机械门禁（队列 L-13）。

守的是什么：界面语言有两条路 ——
  ① 全局函数 `L(...)`（走 `LocalizationManager.text`）；
  ② **显式把语言传下去**（Core 那些 `summary(language:)` / `title(language:)` /
     `describe(…, language:)` / `groupedByType(…, language:)`）。

第 13 轮读图抓到的真缺陷就出在第 ② 条：**行详情侧栏在中文界面上写着 `Text · 12 characters`** ——
`RowDetailPanel` 传的是 `LocalizationManager.shared.language`（**用户选择**），而当时渲染用的是
**宿主语言**（中文），两条路各说各话，一张图里就混了两种语言。

修法是把「当前该用哪种语言」收成一个口子：`LocalizationManager.effectiveLanguage`
（宿主语境优先，其次用户选择）。本门禁把"**不许**再按用户选择取语言"变成机械判据：

  · `App/` 下（除 `App/LocalizationManager.swift` —— 它就是形成这个值的那个文件）**不得**出现
    `LocalizationManager.shared.language` 或 `localization.language`；
  · 三个**合法例外**在 `ALLOWED` 里逐条写明理由（都是"问用户选的是哪种语言"或"进程级系统界面"，
    不是"当前渲染语言"）；**例外表也要反向对账**：某个文件里已经没有这种写法了 ⇒ 条目陈旧，红了才删。

为什么不是"看见就一律禁"：上面那三个例外**恰恰是必须**按用户选择走的（系统菜单是进程级的、
根视图的 `.id` 是用户改语言时用来重建视图树的、菜单勾选态问的就是用户选了什么）。

跑法：

    python3 Scripts/check-effective-language.py          # 接在 verify-all.sh 第 3 项里，每轮跑
    python3 Scripts/test-effective-language-gate.py      # 负例（在临时副本上写坏，不碰仓库）

退出码：0 = 全过；1 = 有判据不成立（打印文件 / 行号 / 原因）。
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent

# 扫哪儿：App/ 下所有 Swift 源文件，**除**语言来源自身的定义文件。
SCAN_ROOT = "App"
DEFINITION_FILE = "App/LocalizationManager.swift"

# 「按用户选择取语言」的写法（含环境对象那一份）。
FORBIDDEN = [
    (re.compile(r"\bLocalizationManager\.shared\.language\b"), "LocalizationManager.shared.language"),
    (re.compile(r"\blocalization\.language\b"), "localization.language"),
]

# 合法例外：文件 → 理由。每条都会**反向对账**（文件里没有这种写法了 ⇒ 条目陈旧 ⇒ 红）。
ALLOWED = {
    "App/MainMenuLocalizer.swift": "改的是 AppKit 系统菜单（进程级系统界面）：按用户选择 / 启动语言"
    "改写 NSMenuItem.title，不跟渲染语境（见 LocalizationManager 的注释）。",
    "App/DoyahStudioApp.swift": "根部 `.id(localization.language)`：用户改语言时用它整体重建视图树，"
    "不是拿它当\"当前渲染语言\"。",
    "App/DoyahStudioCommands.swift": "菜单勾选态：问的就是\"用户选的是哪种语言\"。",
}

# 这个口子必须存在（被改名/删掉时，本门禁要当场说清）。
REQUIRED_DECLARATION = "App/LocalizationManager.swift"
REQUIRED_PATTERN = re.compile(r"\bvar\s+effectiveLanguage\s*:\s*AppLanguage\b")


def code_lines(path: pathlib.Path):
    """产出 (行号, 去掉行尾注释的内容)；整行注释跳过。"""
    for index, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        stripped = raw.strip()
        if not stripped or stripped.startswith("//"):
            continue
        yield index, raw


def main() -> int:
    parser = argparse.ArgumentParser(description="「当前语言」只有一个来源（L-13）")
    parser.add_argument("--root", default=str(REPO), help="扫描哪个仓库根（负例验证用）")
    args = parser.parse_args()
    root = pathlib.Path(args.root)

    problems: list[str] = []
    hits: dict[str, list[str]] = {}

    app = root / SCAN_ROOT
    if not app.is_dir():
        print(f"❌ 找不到 {SCAN_ROOT}/（根目录：{root}）")
        return 2

    for path in sorted(app.rglob("*.swift")):
        relative = path.relative_to(root).as_posix()
        if relative == DEFINITION_FILE:
            continue
        for line_number, line in code_lines(path):
            for pattern, label in FORBIDDEN:
                if pattern.search(line):
                    hits.setdefault(relative, []).append(f"{line_number}:{label}")
                    if relative not in ALLOWED:
                        problems.append(
                            f"{relative}:{line_number} 用了 `{label}` 当作\"当前语言\" —— "
                            f"请改用 `LocalizationManager.shared.effectiveLanguage`（宿主语境优先）"
                        )

    # 例外表反向对账：条目还在，但那种写法已经不在了 ⇒ 陈旧
    for relative, reason in ALLOWED.items():
        if not (root / relative).exists():
            problems.append(f"例外表里的文件不存在：{relative}（理由：{reason}）")
        elif relative not in hits:
            problems.append(
                f"{relative}：例外条目陈旧 —— 这个文件里已经没有 `LocalizationManager.shared.language` / "
                f"`localization.language` 了，请从 ALLOWED 里删掉它"
            )

    # 口子本身必须在
    declaration = root / REQUIRED_DECLARATION
    if not declaration.exists() or not REQUIRED_PATTERN.search(declaration.read_text(encoding="utf-8")):
        problems.append(
            f"{REQUIRED_DECLARATION}：找不到 `var effectiveLanguage: AppLanguage` —— "
            f"本门禁守的那个口子被改名或删掉了"
        )

    print("🌐 语言来源：App/ 下按用户选择取语言的地方")
    for relative in sorted(hits):
        marks = "（合法例外）" if relative in ALLOWED else ""
        print(f"   · {relative}{marks}：{len(hits[relative])} 处 —— {'、'.join(hits[relative])}")

    if problems:
        print(f"\n❌ 语言来源门禁未通过（{len(problems)} 项）：")
        for problem in problems:
            print(f"   - {problem}")
        return 1

    print("✅ 语言来源门禁通过：除例外（系统菜单 / 根视图重建 / 菜单勾选态）外，一律走 effectiveLanguage")
    return 0


if __name__ == "__main__":
    sys.exit(main())
