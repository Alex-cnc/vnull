#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""门禁：笔记模块的**零网络出口**（FR-PLUG-05 验收要点②，开发循环 L-22，闭环第 10 项）。

**为什么有它**：`FR-PLUG-05` 的口径是「Linux 版笔记要有，但**数据不外发**（公司合规）」。
这类承诺最容易被写成一句口号 —— 「我记得笔记那边没联网」在几百个文件里迟早失守，
而且**失守了没有任何现有门禁看得见**：编译过、单测过、文档计数对，只是笔记模块里多了一行
`URLSession.shared`。所以把它变成一条**机械检查**（与解耦门禁 `check-note-module-isolation.py`
同套路、同一条纪律）。

判据分七组：

  ① **范围声明 ↔ 事实**：台账 `notes-offline-gate.json` 的 `scope` 里每个文件都必须存在
     （改名 / 删除后不更新台账 ⇒ 报红，而不是「扫了 0 个文件所以全绿」）。
  ② **漏登一个文件也不行**：按文件名扫 `Core/`（`Note*` / `AICapture*` / `License*`）与
     `App/`（`Note*`）下的实际文件，**必须**都在 `scope` 或 `outOfScope` 里 —— 新增笔记源文件
     而忘了登记 ⇒ 当场报红（否则「往范围外新写一个文件」就是绕过本门禁的暗道）。
  ③ **与解耦门禁对账**：`scope` 里的 Core 侧文件集合必须等于
     `check-note-module-isolation.py` 的 `NOTE_SOURCES + ULTRA_SIDE_SOURCES`（**两份清单不许各说各话**）。
  ④ **零网络出口**：范围内每个文件逐行扫令牌表，命中即红并点名 **文件:行号 + 令牌**。
     例外只能在 `exceptions` 里逐条登记（文件 + 锚点 + 理由），**锚点陈旧报红**（两端都要对账）。
  ⑤ **令牌表不许被掏空**：`requiredTokens` 里那几个关键令牌必须仍在表内（删掉令牌＝
     把门禁改成永远通过），每条令牌都必须写明理由（没理由的令牌将来没人敢删也没人敢留）。
  ⑥ **范围不是空集**：文件数 ≥ 下限、`core` 与 `app` 两层都要有、且**存储入口**（`NoteStore`
     的定义处）与**笔记面板**必须在范围内 —— 否则把范围缩成几个纯值类型文件就能骗过 ④。
  ⑦ **接线与证据**：`verify-all.sh` 里必须真的有本门禁的调用（门禁存在但没接进闭环 ＝
     第 10 项那类「红着、闭环绿着」的假绿），负例脚本必须在位，台账登记的证据锚点必须还在。

用法：
    python3 Scripts/check-notes-offline.py            # 人读结论，失败非零退出
    python3 Scripts/check-notes-offline.py --json     # 机器读
    python3 Scripts/check-notes-offline.py --root <树>  # 负例验证用（临时副本）
"""

from __future__ import annotations  # macOS 自带 python3 是 3.9，`X | None` 这类注解需要它

import argparse
import json
import re
import sys
from pathlib import Path

BASE = Path(__file__).resolve().parent.parent
LEDGER_DEFAULT = "Scripts/notes-offline-gate.json"

# 范围口径：这些名字开头的源文件属于笔记模块（漏登一个 = 那个文件偷偷不受约束）。
CORE_PREFIXES = ("Note", "AICapture", "License")
APP_PREFIXES = ("Note",)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _isolation_lists(root: Path) -> dict[str, list[str]]:
    """从解耦门禁源码里读它自己那两份清单（对账用，不复制粘贴）。"""
    path = root / "Scripts" / "check-note-module-isolation.py"
    if not path.exists():
        return {}
    text = read(path)
    result: dict[str, list[str]] = {}
    for name in ("NOTE_SOURCES", "ULTRA_SIDE_SOURCES"):
        match = re.search(rf"{name}\s*=\s*\[(.*?)\]", text, re.S)
        if not match:
            continue
        result[name] = re.findall(r'"([^"]+\.swift)"', match.group(1))
    return result


def check(root: Path, ledger_path: Path | None) -> tuple[list[str], list[str]]:
    problems: list[str] = []
    notes: list[str] = []

    ledger_file = ledger_path or (root / LEDGER_DEFAULT)
    if not ledger_file.exists():
        return [f"台账不存在：{ledger_file}"], notes
    ledger = json.loads(read(ledger_file))

    scope = ledger.get("scope") or []
    out_of_scope = ledger.get("outOfScope") or []
    banned = ledger.get("bannedTokens") or []
    exceptions = ledger.get("exceptions") or []
    floors = ledger.get("scopeFloors") or {}
    wiring = ledger.get("wiring") or {}

    # ---- ① 范围声明 ↔ 事实 ---------------------------------------------------
    scope_paths: list[str] = []
    for entry in scope:
        rel = (entry or {}).get("path", "")
        if not rel:
            problems.append("范围条目没有 path：台账写漏了")
            continue
        scope_paths.append(rel)
        if not (root / rel).exists():
            problems.append(f"范围里写着 `{rel}`，磁盘上却没有（改名 / 删除了？请同步台账）")
        if len(((entry or {}).get("role") or "").strip()) < 6:
            problems.append(f"范围条目 `{rel}` 没写 role —— 说不出它为什么在范围内")
    notes.append(f"范围：{len(scope_paths)} 个源文件（台账声明）")

    for entry in out_of_scope:
        rel = (entry or {}).get("path", "")
        if rel and not (root / rel).exists():
            problems.append(f"豁免名单里的 `{rel}` 不存在了（陈旧条目要删）")
        if len(((entry or {}).get("reason") or "").strip()) < 8:
            problems.append(f"豁免条目 `{rel or '(缺 path)'}` 没写明理由")

    # ---- ② 漏登一个文件也不行 ------------------------------------------------
    declared = set(scope_paths) | {(entry or {}).get("path") for entry in out_of_scope}
    on_disk: list[str] = []
    core_dir = root / "Core"
    if core_dir.is_dir():
        for path in sorted(core_dir.glob("*.swift")):
            if path.name.startswith(CORE_PREFIXES):
                on_disk.append(f"Core/{path.name}")
    app_dir = root / "App"
    if app_dir.is_dir():
        for path in sorted(app_dir.rglob("*.swift")):
            if path.name.startswith(APP_PREFIXES):
                on_disk.append(str(path.relative_to(root)))
    for rel in on_disk:
        if rel not in declared:
            problems.append(
                f"{rel}：新的笔记源文件既不在范围里也不在豁免名单里"
                "（笔记模块的零网络出口靠这份范围站住，漏登等于它偷偷不受约束）"
            )
    notes.append(f"按文件名扫出 {len(on_disk)} 个笔记相关源文件，逐个已登记")

    # ---- ③ 与解耦门禁对账 ----------------------------------------------------
    lists = _isolation_lists(root)
    reconcile_names = wiring.get("reconcileWithIsolationLists") or []
    # 超范围登记：范围内的 Core 文件不一定都在解耦门禁的笔记清单里（许可链按设计要给三端复用，
    # 但那份清单管的是「笔记侧能不能独立构建」，两件事的范围不重合），所以这些文件要逐条登记理由 ——
    # 没有这一条的话，**往范围里塞文件**就成了绕过「与解耦清单对账」的暗道。
    beyond: set[str] = set()
    for entry in ledger.get("scopeBeyondIsolation") or []:
        rel = (entry or {}).get("path", "")
        if not rel:
            problems.append("`scopeBeyondIsolation` 有条目没写 path")
            continue
        beyond.add(rel)
        if rel not in scope_paths:
            problems.append(f"`scopeBeyondIsolation` 里的 `{rel}` 不在范围里（要么加进 scope、要么删掉这条）")
        if len(((entry or {}).get("reason") or "").strip()) < 20:
            problems.append(f"`{rel}` 比解耦清单多出来的理由没写清（将来没人敢删也没人敢留）")
    if len(lists) < len(reconcile_names):
        problems.append(
            "读不到解耦门禁的清单（`check-note-module-isolation.py` 里 "
            f"{' / '.join(reconcile_names)} 没找到）—— 两份清单无法对账"
        )
    else:
        isolation_core = {item for name in reconcile_names for item in lists.get(name, [])}
        scope_core = {rel for rel in scope_paths if rel.startswith("Core/")}
        for rel in sorted(isolation_core - scope_core):
            problems.append(f"{rel}：解耦门禁把它算作笔记源文件，本台账却没登记（两份清单不许各说各话）")
        for rel in sorted(scope_core - isolation_core):
            if rel in beyond:
                continue
            problems.append(f"{rel}：本台账把它算作笔记源文件，解耦门禁的清单里却没有（要留就登记进 `scopeBeyondIsolation` 并写明理由）")
        for rel in sorted(beyond & isolation_core):
            problems.append(f"`scopeBeyondIsolation` 里的 `{rel}` 其实就在解耦清单里（这条超范围登记是陈旧的）")
        notes.append(
            f"与解耦门禁对账：Core 侧 {len(scope_core)} 个文件双方一致"
            f"（其中 {len(scope_core - isolation_core)} 个是登记过理由的超范围文件）"
        )

    # ---- ④ 零网络出口 --------------------------------------------------------
    tokens = [((entry or {}).get("token") or "") for entry in banned]
    hits = 0
    for rel in scope_paths:
        path = root / rel
        if not path.exists():
            continue
        for number, line in enumerate(read(path).splitlines(), start=1):
            for token in tokens:
                if token and token in line:
                    hits += 1
                    problems.append(
                        f"{rel}:{number}：命中网络 API `{token}` —— "
                        "笔记模块（FR-PLUG-05 ②）不许有出网能力；确有正当用途要在台账 exceptions 里登记理由"
                    )
    notes.append(f"零网络出口：范围 {len(scope_paths)} 个文件 × 令牌表 {len(tokens)} 项，命中 {hits} 处")

    # ---- 例外：两端都对账 ----------------------------------------------------
    for entry in exceptions:
        rel = (entry or {}).get("file", "")
        anchor = (entry or {}).get("anchor", "")
        if len(((entry or {}).get("reason") or "").strip()) < 8:
            problems.append(f"例外 `{rel}` 没写明理由（没理由的例外就是把招子留给下一个人）")
        path = root / rel if rel else None
        if not rel or not path or not path.exists():
            problems.append(f"例外指向的文件不存在：`{rel}`")
            continue
        if not anchor:
            problems.append(f"例外 `{rel}` 没给锚点（要能指出到底是哪一行）")
            continue
        count = read(path).count(anchor)
        if count == 0:
            problems.append(f"例外 `{rel}` 的锚点 `{anchor[:40]}` 已经找不到了 —— 陈旧例外要删")
        elif count > 1:
            problems.append(f"例外 `{rel}` 的锚点 `{anchor[:40]}` 出现 {count} 处，锚点不够具体")
    notes.append(f"例外：{len(exceptions)} 条（每条都要有文件 + 锚点 + 理由，锚点陈旧报红）")

    # ---- ⑤ 令牌表不许被掏空 --------------------------------------------------
    required = ledger.get("requiredTokens") or []
    for token in required:
        if token not in tokens:
            problems.append(
                f"关键令牌 `{token}` 从令牌表里消失了 —— 删令牌就能让门禁永远通过，"
                "关键项不许被拿掉"
            )
    for entry in banned:
        token = (entry or {}).get("token") or ""
        if len(((entry or {}).get("reason") or "").strip()) < 8:
            problems.append(f"令牌 `{token}` 没写明理由（为什么禁它要说得出）")
    notes.append(f"令牌表：{len(tokens)} 项（其中关键项 {len(required)} 项必须在位）")

    # ---- ⑥ 范围不是空集 ------------------------------------------------------
    minimum = floors.get("minFiles") or 0
    if len(scope_paths) < minimum:
        problems.append(f"范围只有 {len(scope_paths)} 个文件、台账下限是 {minimum} —— 范围被缩小了")
    layers = {entry.get("layer") for entry in scope}
    for layer in floors.get("requiredLayers") or []:
        if layer not in layers:
            problems.append(f"范围里没有 `{layer}` 层的文件 —— 零网络出口要覆盖笔记模块的每一层")
    for item in floors.get("requiredMarkers") or []:
        rel = item.get("file", "")
        marker = item.get("marker", "")
        path = root / rel
        if not path.exists() or marker not in read(path):
            problems.append(
                f"范围里的关键锚点不在位：`{rel}` 里找不到 `{marker}` —— {item.get('why', '')}"
            )
    notes.append(f"范围下限：{minimum} 个文件、层级 {'/'.join(floors.get('requiredLayers') or [])}、关键锚点 {len(floors.get('requiredMarkers') or [])} 个")

    # ---- ⑦ 接线与证据 --------------------------------------------------------
    verify_all = root / (wiring.get("verifyAll") or "")
    gate_call = wiring.get("gateCall") or ""
    if not verify_all.exists():
        problems.append(f"闭环脚本不存在：{wiring.get('verifyAll')}")
    elif gate_call and gate_call not in read(verify_all):
        problems.append(
            f"`{wiring.get('verifyAll')}` 里没有本门禁（`{gate_call}`）的调用 —— "
            "门禁存在但没接进闭环，等于红不起来（第 10 项那类假绿）"
        )
    negative = root / (wiring.get("negativeTest") or "")
    if not negative.exists():
        problems.append(f"负例脚本不存在：{wiring.get('negativeTest')}（绿着不等于看得见违规）")

    for marker in ledger.get("evidence") or []:
        path = root / (marker.get("file") or "")
        if not path.exists():
            problems.append(f"证据：{marker.get('file')} 不存在（台账说它该在）")
            continue
        if marker.get("contains") and marker["contains"] not in read(path):
            problems.append(
                f"证据：{marker.get('file')} 里找不到 `{marker['contains']}` —— 台账登记的锚点不在位"
            )

    gaps = ledger.get("knownGaps") or []
    for gap in gaps:
        if len((gap or "").strip()) < 12:
            problems.append(f"已知缺口条目太短、等于没登记：{gap!r}")
    notes.append(f"已登记缺口 {len(gaps)} 条（只减不增）")

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
    print(
        "\n✅ 笔记模块范围内一个网络 API 都没有（逐行扫令牌表）；范围声明与事实、与解耦门禁两边一致；"
        "关键令牌仍在表内；门禁已接进闭环。"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
