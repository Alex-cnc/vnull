#!/usr/bin/env python3
"""门禁：连接失败的**文案覆盖面**（开发循环 L-14 起，闭环第 14 项）。

**为什么有它**：驱动是随仓库带走的 Vendor（`Vendor/postgres-nio`），升一次版就可能多出
新的 `PSQLError.Code`。文案层的 `switch` 有 `default:` 兜底，于是新原因**不会报错、不会崩**，
只会被说成最泛的那句（「连接数据库失败」）—— 与 L-14 修掉的那件事同一族：
**代码没坏，话指错了方向**。这类退化没有任何现有门禁看得见（编译过、单测过、文档计数对）。

做法与第 13 项同源：**台账是声明**（`Scripts/connection-failure-dispositions.json`），
门禁拿五组判据跟事实对账：

  ① 驱动源码里的 `PSQLError.Code.Base` 枚举本身要读得出来（读不出来 → 驱动换了写法，该更新门禁）；
  ② 驱动有的码，台账必须有一条处置；台账有的码，驱动里必须还在（陈旧条目也算红）；
  ③ 标「翻译」的必须给出 `caseRef`，且那个 `case` **真的**出现在映射文件里（挡台账撒谎）；
     标「不翻译 / 按码说话」的必须写明为什么（空理由 = 等于没登记）；
  ④ 兜底分支必须仍在（驱动新增码时先落兜底、不至于崩，门禁的红只是提醒去登记）；
  ⑤ 解析前置检查与证据：台账登记的服务必须真的在**建连之前**调了那道检查；
     证据脚本里的正反断言与那条「驱动丢原因」的测试都必须在位。

用法：
    python3 Scripts/check-connection-failure-coverage.py            # 人读结论，失败非零退出
    python3 Scripts/check-connection-failure-coverage.py --json     # 机器读
"""

from __future__ import annotations  # macOS 自带 python3 是 3.9，`X | None` 这类注解需要它

import argparse
import json
import re
import sys
from pathlib import Path

# 可以整体指到别处（`--root`，负例验证用：拷一棵临时树，不碰真仓库）
BASE = Path(__file__).resolve().parent.parent
LEDGER_NAME = "connection-failure-dispositions.json"

MIN_WHY = 8  # 理由至少几个字：太短的不算登记


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def driver_codes(text: str) -> list[str]:
    """驱动 `PSQLError.Code.Base` 里的 case 名字（按出现顺序）。

    **锚点不能只找 `enum Base`**：同一个文件里 `PostgresDecodingError.Code` 也有一个
    `enum Base`（负例实测抓到的 —— 只找第一个的话，改坏 PSQLError 那个枚举时门禁会读成
    另一个枚举的码，报出一串莫名其妙的问题）。所以先定位 `public struct PSQLError`，
    在它的作用域里找 `struct Code:`，再找紧随其后的 `enum Base`。
    """
    anchor = text.find("public struct PSQLError")
    if anchor < 0:
        return []
    region = text[anchor:]
    code_decl = region.find("struct Code:")
    if code_decl < 0:
        return []
    start = region.find("enum Base", code_decl)
    if start < 0:
        return []
    names: list[str] = []
    for line in region[start:].splitlines()[1:]:
        stripped = line.strip()
        if stripped == "}" or stripped.startswith("public ") or stripped.startswith("var "):
            break
        match = re.match(r"case\s+([A-Za-z_][A-Za-z0-9_]*)", stripped)
        if match:
            names.append(match.group(1))
    return names


def driver_switch_body(mapping: str) -> str | None:
    """`describe(psqlError:)` 里那段 `switch psqlError.code` 的正文（到函数结束为止）。

    为什么不能只在整份文件里找 `default:`：这个文件里还有别的 `switch`（例如
    `requiresPassword` 的 `default: break`），随便一个都能让判据误绿 —— 负例实测抓到的。
    """
    switch = mapping.find("switch psqlError.code {")
    if switch < 0:
        return None
    tail = mapping[switch:]
    end = tail.find("\n    }")  # 函数体结束（4 空格缩进的收尾括号）
    return tail[:end] if end > 0 else tail


def check(root: Path, ledger_path: Path | None = None) -> tuple[list[str], list[str]]:
    problems: list[str] = []
    notes: list[str] = []

    ledger_file = ledger_path or (root / "Scripts" / LEDGER_NAME)
    if not ledger_file.exists():
        return [f"找不到台账：{ledger_file}"], notes
    try:
        ledger = json.loads(ledger_file.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        return [f"台账不是合法 JSON：{error}"], notes

    driver_path = root / ledger.get("driverCodeSource", "")
    mapping_path = root / ledger.get("mapping", "")
    for label, path in (("驱动源码", driver_path), ("映射文件", mapping_path)):
        if not path.exists():
            problems.append(f"台账指向的{label}不存在：{path.relative_to(root) if root in path.parents else path}")
    if problems:
        return problems, notes

    codes = driver_codes(read(driver_path))
    # 读不出来 / 读出来不对劲**都要报红**：同一个文件里 `PostgresDecodingError.Code` 也有
    # 一个 `enum Base`，只按"找得到就算数"会悄悄对错表（负例 H 实测抓到）。
    # 锚点用 `serverClosedConnection`：它是我们文案层**点名引用**的码，改名就是要人看一眼的事。
    if not codes or "serverClosedConnection" not in codes:
        problems.append(
            f"从 {ledger['driverCodeSource']} 里读不到 `PSQLError.Code.Base` 的码表"
            f"（读到的是：{'、'.join(codes) or '空'}）—— 驱动的写法变了（或路径变了），"
            "这道门禁需要跟着更新，别让它悄悄变成永远绿"
        )
        return problems, notes
    notes.append(f"驱动错误码 {len(codes)} 个（{ledger['driverCodeSource']}）")

    dispositions = ledger.get("dispositions") or {}
    mapping = read(mapping_path)

    # ② 驱动 ↔ 台账 双向对账
    missing = [code for code in codes if code not in dispositions]
    if missing:
        problems.append(
            "驱动里有、台账里没有的码：" + "、".join(missing)
            + "（新码会静默落到兜底文案 —— 去 Scripts/connection-failure-dispositions.json 登记它怎么处置）"
        )
    stale = [code for code in dispositions if code not in codes]
    if stale:
        problems.append("台账里有、驱动里已经不在的码：" + "、".join(stale) + "（陈旧条目要删）")

    # ③ 每条处置本身要成立
    translated = 0
    for code in codes:
        entry = dispositions.get(code)
        if not isinstance(entry, dict):
            continue
        kind = entry.get("kind")
        why = (entry.get("why") or "").strip()
        if kind not in ledger.get("kinds", {}):
            problems.append(f"{code}：kind={kind!r} 不在台账定义的处置种类里")
            continue
        if len(why) < MIN_WHY:
            problems.append(f"{code}：没有写明处置理由（why 至少 {MIN_WHY} 字）")
        if kind == "翻译":
            translated += 1
            case_ref = (entry.get("caseRef") or "").strip()
            if not case_ref:
                problems.append(f"{code}：标了「翻译」却没给 caseRef")
            elif case_ref not in mapping:
                problems.append(
                    f"{code}：台账说它被翻译（{case_ref}），但 {ledger['mapping']} 里找不到 {case_ref} —— 台账在撒谎"
                )
    notes.append(f"标「翻译」的 {translated} 个 / 「不翻译」与「按码说话」{len(codes) - translated} 个")

    # ④ 兜底分支仍在（驱动新增码时不至于崩，红只是提醒登记）——**必须在那段 switch 里**，
    #    文件里别处（`requiresPassword` 的 `default: break`）不算。
    switch_body = driver_switch_body(mapping)
    if switch_body is None:
        problems.append(
            f"{ledger['mapping']} 里找不到 `switch psqlError.code {{` —— 驱动码的分支被拆了或改名了，"
            "这道门禁的对账对象没了，该更新门禁"
        )
    elif not re.search(r"^\s*default:\s*$", switch_body, re.M):
        problems.append(
            f"{ledger['mapping']} 的驱动码分支里没有 `default:` 兜底 —— 驱动新增码时会直接崩在这里，"
            "而那时该做的是登记台账、不是崩溃"
        )

    # ⑤ 解析前置检查：登记的服务必须真的在**建连之前**调了那道检查
    for entry in ledger.get("resolutionPreflight", []):
        file = root / entry.get("file", "")
        if not file.exists():
            problems.append(f"解析前置检查：{entry.get('service')} 的文件不存在（{entry.get('file')}）")
            continue
        text = read(file)
        call = entry.get("call", "")
        if call not in text:
            problems.append(
                f"解析前置检查：{entry.get('service')}（{entry.get('file')}）里找不到 `{call}` —— "
                "台账登记了这道闸，代码里没有"
            )
            continue
        before = entry.get("before")
        if before:
            call_at = text.find(call)
            before_at = text.find(before)
            if before_at < 0:
                problems.append(f"解析前置检查：{entry.get('file')} 里找不到要对比的 `{before}`")
            elif call_at > before_at:
                problems.append(
                    f"解析前置检查：{entry.get('service')} 的 `{call}` 出现在 `{before}` **之后** —— "
                    "解析要在建连之前（之后就只能拿到驱动丢掉原因后的残渣）"
                )

    # ⑤′ 证据与前提测试
    for marker in ledger.get("evidenceMarkers", []):
        file = root / marker.get("file", "")
        if not file.exists():
            problems.append(f"证据：{marker.get('file')} 不存在（台账说它该在）")
            continue
        if marker.get("contains") and marker["contains"] not in read(file):
            problems.append(
                f"证据：{marker.get('file')} 里找不到 `{marker['contains']}` —— 台账登记的判据不在位"
            )

    return problems, notes


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--root", default=None, help="换一棵树（负例验证用）")
    parser.add_argument("--ledger", default=None, help="换一份台账（负例验证用）")
    args = parser.parse_args()

    root = Path(args.root).resolve() if args.root else BASE
    ledger = Path(args.ledger).resolve() if args.ledger else None
    problems, notes = check(root, ledger)

    if args.json:
        print(json.dumps({"ok": not problems, "problems": problems, "notes": notes}, ensure_ascii=False, indent=2))
        return 1 if problems else 0

    for note in notes:
        print(f"  · {note}")
    if problems:
        print(f"\n❌ {len(problems)} 处不合规：")
        for problem in problems:
            print(f"  · {problem}")
        return 1
    print("\n✅ 驱动错误码与文案台账逐条对得上；解析前置检查与证据都在位。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
