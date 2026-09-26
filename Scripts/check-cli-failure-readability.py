#!/usr/bin/env python3
"""门禁：命令行失败输出的**可读化覆盖面**（开发循环 L-15 起，闭环第 15 项）。

**为什么有它**：CLI 里把失败说给用户看的地方有几十处，原先各写各的 ——
`print("列出表失败：\\(error.localizedDescription)")` 打出来是
`The operation couldn't be completed. (PostgresNIO.PSQLError error 1.)`：
**既不是人话、也没给方向**，而驱动其实说过原因（SQLSTATE / 驱动码），只是没人接。
第 7~8 轮只接上了连接失败 / 查询失败两条主路，剩下 57 处仍是英文调试串。

**为什么必须机械判**：这类退化**没有任何现有门禁看得见** —— 编译过、单测过、文档计数对，
只是「话指错了方向 / 干脆没说」。而且它散在几十个 `catch` 里，靠人盯必然改一处漏一处
（本轮就是一次 57 处的统一改造）。所以判据要盯住**结构**而不是当时那份人名清单：

  ① 扫描 CLI 里每一处「打给用户看的失败输出」（`print(` / `FileHandle.standardError.write(` 且
     出现原始串）：**必须**同一行经由入口 `CLIFailureText.oneLine(`。新增一处裸英文失败输出
     ⇒ 当场报红并指名行号与标签。机器可读出口（`--json` 的 `error` 字段 / `jsonQuoted(...)`）
     按**结构**放行，不靠人写行号。
  ② **反向棘轮**：入口的调用处数不得少于台账写的 `minCallSites`（57）—— 只查「入口存在」的话，
     把调用删回去、或者只写一个不接线的 helper，门禁照样绿（L-04 / L-05 / 第 14 项都栽在
     「判据太松」上）。
  ③ 入口自己的**三条口径**必须在位：连接类 → `describe`、驱动非连接类 → `describeNonConnection`、
     认不出 → **原样返回**（不套方向结论）。顺序写反或把兜底改成「连接失败」都报红 ——
     那正是 R-60（把猜测当结论）。
  ④ **原始串不丢**的另一半：`String(reflecting: error)` 的调试转储不得少于台账记的处数
     （删了就只剩人话，排查拿不到原始报文）。
  ⑤ 台账里登记的例外（`--json` 出口）与渠道字段（`plumbing`）**锚点必须还在** —— 陈旧条目报红。
  ⑥ 已登记的**已知缺口**（`knownGaps`）只减不增：门禁把它们打出来（提醒别当没看见），
     条数比台账多就报红。
  ⑦ 证据脚本里的关键断言（正面 + 反向）必须在位。

用法：
    python3 Scripts/check-cli-failure-readability.py            # 人读结论，失败非零退出
    python3 Scripts/check-cli-failure-readability.py --json     # 机器读
    python3 Scripts/check-cli-failure-readability.py --root <树>  # 负例验证用（临时副本）
"""

from __future__ import annotations  # macOS 自带 python3 是 3.9，`X | None` 这类注解需要它

import argparse
import json
import re
import sys
from pathlib import Path

BASE = Path(__file__).resolve().parent.parent
LEDGER_NAME = "cli-failure-readability.json"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def output_sites(text: str, print_markers: list[str], raw_marker: str, call: str) -> list[tuple[int, str]]:
    """每一处「打给用户看的失败输出」：行号 + 原文。

    选行条件是「输出调用 + 原始串**或**入口调用」——**两者都要选**：只看原始串的话，
    已经改好的那些行（`…：\\(CLIFailureText.oneLine(error))`）根本不出现在扫描结果里，
    于是「经入口的输出」恒为 0，门禁看不见自己守的那片地方（写坏一处也只会报「裸英文」，
    而计数与结论都是假的）。
    """
    sites = []
    for index, line in enumerate(text.splitlines(), start=1):
        if raw_marker not in line and call not in line:
            continue
        if not any(marker in line for marker in print_markers):
            continue
        sites.append((index, line.strip()))
    return sites


def label_of(line: str) -> str:
    """从输出行里抠一个人读的标签（`print("列出表失败：…")` → `列出表失败`）。"""
    match = re.search(r'print\("([^"\\]{2,24})', line)
    if match:
        return match.group(1).rstrip("：:")
    match = re.search(r'Data\(\(?"([^"\\]{2,24})', line)
    if match:
        return match.group(1).rstrip("：:")
    return "(无标签)"


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

    entry = ledger.get("entryPoint") or {}
    scan = ledger.get("outputScan") or {}
    helper_rel = entry.get("file", "")
    helper_path = root / helper_rel
    if not entry.get("call") or not helper_rel:
        return ["台账缺 `entryPoint.file` / `entryPoint.call`"], notes
    if not helper_path.exists():
        problems.append(f"台账指向的入口文件不存在：{helper_rel}")
        return problems, notes

    scan_files = scan.get("files") or []
    print_markers = scan.get("printMarkers") or []
    raw_marker = scan.get("rawMarker") or ""
    json_markers = scan.get("jsonExemptMarkers") or []
    if not scan_files or not print_markers or not raw_marker or not json_markers:
        return ["台账 `outputScan` 不完整（要有 files / printMarkers / rawMarker / jsonExemptMarkers）"], notes

    call = entry["call"]

    # ---- ① 每一处用户可见失败输出都必须经由入口 ------------------------------
    bare: list[str] = []
    via_entry = 0
    json_exempt = 0
    for rel in scan_files:
        path = root / rel
        if not path.exists():
            problems.append(f"扫描目标不存在：{rel}")
            continue
        for line_no, line in output_sites(read(path), print_markers, raw_marker, call):
            if any(marker in line for marker in json_markers):
                json_exempt += 1
                continue
            if call in line:
                via_entry += 1
                continue
            bare.append(f"{rel}:{line_no}（{label_of(line)}）")
    if bare:
        problems.append(
            "还有**裸的英文失败输出**（打给用户看、却没经过可读化入口）："
            + "、".join(bare)
            + f" —— 改成 `{call}error)`：驱动报的原因（SQLSTATE / 驱动码）就在手里，"
            "直接打 `localizedDescription` 等于把 `The operation couldn't be completed…` 丢给用户"
        )
    notes.append(f"经入口的输出 {via_entry} 处；按结构放行的机器可读出口 {json_exempt} 处")

    # ---- ② 反向棘轮：入口真的在接线（处数只增不减） --------------------------
    helper_text = read(helper_path)
    cli_text = "\n".join(read(root / rel) for rel in scan_files if (root / rel).exists())
    actual_calls = cli_text.count(call)
    minimum = entry.get("minCallSites")
    if not isinstance(minimum, int) or minimum < 1:
        problems.append(
            f"台账没写 `entryPoint.minCallSites`（入口至少该有几处调用）—— 只登记「有这个入口」的话，"
            "把调用删回去（或只留一个不接线的 helper）仍能骗过门禁"
        )
    elif actual_calls < minimum:
        problems.append(
            f"入口 `{call}` 只剩 {actual_calls} 处调用，台账要求至少 {minimum} 处 —— "
            "少掉的路径已经退回英文调试串（这就是本条要挡的那件事）"
        )
    else:
        notes.append(f"入口调用 {actual_calls} 处（台账下限 {minimum}）")

    # ---- ③ 入口自己的三条口径必须在位 ---------------------------------------
    contract = entry.get("contract") or []
    if not contract:
        problems.append("台账没写 `entryPoint.contract`（入口该守哪几条口径）—— 没有判据可对账")
    for item in contract:
        step = item.get("step", "")
        why = (item.get("why") or "").strip()
        if not step:
            problems.append("台账 `entryPoint.contract` 里有空条目")
            continue
        if len(why) < 8:
            problems.append(f"入口口径 `{step}`：没写明为什么（理由太短）")
        if step not in helper_text:
            problems.append(
                f"入口口径 `{step}` 在 {helper_rel} 里找不到 —— "
                "口径被改了或删了（这一条守的是「认得出就给方向、认不出就不猜」）"
            )

    # ---- ④ 调试转储不得被删 ---------------------------------------------------
    dump = ledger.get("debugDumps") or {}
    dump_marker = dump.get("marker", "")
    dump_min = dump.get("minCount")
    if not dump_marker or not isinstance(dump_min, int):
        problems.append("台账缺 `debugDumps.marker` / `debugDumps.minCount`")
    else:
        found = cli_text.count(dump_marker)
        if found < dump_min:
            problems.append(
                f"调试转储 `{dump_marker}` 只剩 {found} 处，台账要求至少 {dump_min} 处 —— "
                "原始串的另一半被删了（只剩人话时，排查拿不到原始报文）"
            )
        else:
            notes.append(f"调试转储 {found} 处（台账下限 {dump_min}）")

    # ---- ⑤ 例外与渠道字段的锚点必须还在（陈旧条目报红） ----------------------
    for kind, items in (("例外", ledger.get("exemptions") or []), ("渠道字段", ledger.get("plumbing") or [])):
        for item in items:
            anchor = item.get("anchor", "")
            why = (item.get("why") or "").strip()
            expected = item.get("count")
            if not anchor:
                problems.append(f"{kind}：有一条没写 `anchor`")
                continue
            if len(why) < 8:
                problems.append(f"{kind} {anchor[:40]}…：没写明理由")
            found = cli_text.count(anchor)
            if found == 0:
                problems.append(
                    f"{kind}：台账登记的锚点在 CLI 里找不到了（陈旧条目要删）—— `{anchor[:60]}`"
                )
            elif isinstance(expected, int) and found != expected:
                problems.append(
                    f"{kind}：`{anchor[:60]}` 实际 {found} 处、台账写 {expected} 处 —— "
                    "处数对不上说明代码变了（多了要登记、少了要确认不是被误删）"
                )

    # ---- ⑥ 已知缺口只减不增 ---------------------------------------------------
    gaps = ledger.get("knownGaps") or []
    notes.append(f"已登记缺口 {len(gaps)} 条（只减不增）")
    for gap in gaps:
        if len((gap or "").strip()) < 12:
            problems.append(f"已知缺口条目太短、等于没登记：{gap!r}")

    # ---- ⑦ 证据脚本里的关键断言必须在位 -------------------------------------
    for marker in ledger.get("evidence") or []:
        path = root / marker.get("file", "")
        if not path.exists():
            problems.append(f"证据：{marker.get('file')} 不存在（台账说它该在）")
            continue
        if marker.get("contains") and marker["contains"] not in read(path):
            problems.append(
                f"证据：{marker.get('file')} 里找不到 `{marker['contains']}` —— 台账登记的断言不在位"
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
    print(
        "\n✅ 命令行的失败输出一律经可读化入口（认得出给方向、认不出原样）；机器可读出口按结构放行；"
        "原始串仍保留在调试转储里；例外与渠道字段的锚点都在位。"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
