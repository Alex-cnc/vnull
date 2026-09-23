#!/usr/bin/env python3
"""命令面板接线校验（FR-EDIT-25）。

存在的理由：
    2026-09-23 的收尾自查里发现 —— `AppState.performPaletteCommand` 给 10 条命令里的
    **9 条设了 `@Published` 标志位，而没有任何视图读它们**。用户在 ⌘K 里选「会话 / 锁 /
    浏览数据 / 表结构 / 切换连接 / 智能体 / 合成数据 / 帮助」，界面**完全没反应**；
    剩下那条（智能体）是**设错了标志位**（设 `isAgentSQLCommandPresented`，界面绑的是
    `isAgentSQLPresented`）。

    这个缺陷对当时已有的 8 项门禁**全部不可见**：编译过、单测过、文档表格过、令牌过、
    平台矩阵过、打包过 —— 因为"命令清单里有这一条"和"这条命令真的能打开东西"之间
    没有任何检查。于是补上这一项。

检查内容（任一不过即失败）：
    1. 命令清单里的每个 id 都要在分派器里被处理 —— 否则那是一条**点了没反应**的命令；
    2. 分派器里的每个 id 都要在命令清单里 —— 否则是漂移（用户看不到，代码里却还在）；
    3. 分派器设的每个标志位都要**至少被一个视图读**（App/ 下除 AppState.swift 之外）
       —— 这就是上面那个缺陷的判据；
    4. 每条命令的关键词不得为空（否则面板里搜不到它，等于没有这条命令）；
    5. **解析不到东西就报错**：如果正则没匹配到命令（清单结构变了），必须失败而不是
       空转通过 —— "门禁自己失效"比"门禁发现不了"更危险。

用法：
    python3 Scripts/check-palette-wiring.py             # 校验（闸门）
    python3 Scripts/check-palette-wiring.py --explain   # 打印解析到的清单与标志位
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
STATE = ROOT / "App" / "AppState.swift"
CATALOG = ROOT / "App" / "AppCommandCatalog.swift"
APP = ROOT / "App"

ITEM = re.compile(r'item\(\s*"([^"]+)"\s*,\s*\.(\w+)\s*,\s*"([^"]*)"')
CASE = re.compile(r'case\s+"([^"]+)"\s*:')
FLAG_SET = re.compile(r'\b(is[A-Za-z]+)\s*=\s*true\b')


def command_ids() -> list[tuple[str, str, str]]:
    """命令清单：id / 本地化键 / 关键词。"""
    text = CATALOG.read_text(encoding="utf-8")
    return [(i, key, words) for i, key, words in ITEM.findall(text)]


def dispatcher() -> tuple[list[str], list[str]]:
    """分派器处理了哪些 id、设了哪些标志位。"""
    text = STATE.read_text(encoding="utf-8")
    start = text.index("func performPaletteCommand")
    # 到下一个 `func ` 或 `@Published` 声明为止 —— 函数体边界（用花括号配平更稳，见下）
    depth = 0
    began = False
    end = start
    for offset, character in enumerate(text[start:], start=start):
        if character == "{":
            depth += 1
            began = True
        elif character == "}":
            depth -= 1
            if began and depth == 0:
                end = offset
                break
    body = text[start:end]
    return CASE.findall(body), FLAG_SET.findall(body)


def flag_bindings(flag: str) -> list[str]:
    """哪些视图读了它（AppState 自己不算）。"""
    users = []
    for path in APP.rglob("*.swift"):
        if path.name == "AppState.swift":
            continue
        if flag in path.read_text(encoding="utf-8"):
            users.append(str(path.relative_to(ROOT)))
    return sorted(users)


def main() -> int:
    explain = "--explain" in sys.argv
    catalog = command_ids()
    handled, flags = dispatcher()
    problems: list[str] = []

    # 5) 先保证门禁自己没瞎：解析不到就是结构变了，必须报出来
    if not catalog:
        problems.append(f"{CATALOG.relative_to(ROOT)}: 解析不到任何命令 —— 清单结构变了，请同步本脚本")
    if not handled:
        problems.append(f"{STATE.relative_to(ROOT)}: 解析不到分派器里的任何 case —— 结构变了，请同步本脚本")

    catalog_ids = [c[0] for c in catalog]
    if len(set(catalog_ids)) != len(catalog_ids):
        duplicated = sorted({i for i in catalog_ids if catalog_ids.count(i) > 1})
        problems.append(f"命令清单有重复 id：{duplicated}")

    # 1) 清单里的每条命令都要真的被处理
    for ident, _, _ in catalog:
        if ident not in handled:
            problems.append(f"命令「{ident}」在清单里，但 performPaletteCommand 没有处理它 —— 点了没反应")

    # 2) 处理了，但用户看不到（漂移）
    for ident in handled:
        if ident not in catalog_ids:
            problems.append(f"performPaletteCommand 处理了「{ident}」，但它不在命令清单里（用户看不到这条命令）")

    # 4) 关键词不得为空
    for ident, _, words in catalog:
        if not words.strip():
            problems.append(f"命令「{ident}」没有关键词 —— 在面板里搜不到它")

    # 3) 设了标志位就必须有人读（本次缺陷的判据）
    for flag in sorted(set(flags)):
        users = flag_bindings(flag)
        if not users:
            problems.append(
                f"标志位 {flag} 在分派器里被设为 true，但**没有任何视图读它** —— 这条命令点了没反应"
            )
        elif explain:
            print(f"  {flag:<34} ← {', '.join(users)}")

    if explain:
        print(f"\n命令清单 {len(catalog)} 条 / 分派器处理 {len(handled)} 条 / 标志位 {len(set(flags))} 个")
        for ident, key, words in catalog:
            mark = "✅" if ident in handled else "❌"
            print(f"  {mark} {ident:<18} {key:<28} {words[:40]}")

    if problems:
        print(f"❌ 命令面板接线校验失败（{len(problems)} 处）：")
        for problem in problems:
            print(f"   {problem}")
        print("\n提示：命令清单只管「列出来」，能不能打开东西由分派器与视图绑定决定 —— 两边都要对。")
        return 1

    print(f"✅ 命令面板接线校验通过（{len(catalog)} 条命令全部有处理、{len(set(flags))} 个标志位都有视图读）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
