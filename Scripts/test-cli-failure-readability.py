#!/usr/bin/env python3
"""负例：`Scripts/check-cli-failure-readability.py`（闭环第 15 项）**红得出来吗**。

**为什么单开一个脚本**：门禁绿着只能说明「现在没违规」，**不能**说明它看得见违规 ——
本工程已经栽过三次（L-04「失败只记进没人读的变量」、L-05「断言被删也照绿」、第 14 项
「删掉两处出口里的一处仍能顶数」），所以每条新门禁都配一组负例：**写坏 → 必须报红 → 点名哪一处**。

**做法**：不改真仓库的文件，而是把**必要的几个文件**拷进临时目录，在副本上写坏、
把门禁指过去（`--root`）。本轮这组负例要删调用、改兜底、写大处数 —— 一旦中途失败，
真仓库会被留在半坏状态；副本上折腾没有这个代价（跑完断言真仓库一个字节没动）。

用法：`python3 Scripts/test-cli-failure-readability.py`
"""

import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GATE_NAME = "check-cli-failure-readability.py"
LEDGER_REL = "Scripts/cli-failure-readability.json"

FILES = [
    "CLI/main.swift",
    "CLI/CLIFailureText.swift",
    "Scripts/test-cli-failure-readability.sh",
]

passed: list[str] = []
failed: list[str] = []


def record(ok: bool, label: str, detail: str = "") -> None:
    (passed if ok else failed).append(label)
    print(f"  {'✅' if ok else '❌'} {label}" + (f"  —— {detail}" if detail and not ok else ""))


def make_tree() -> Path:
    tree = Path(tempfile.mkdtemp(prefix="doyah-cli-readability-"))
    (tree / "Scripts").mkdir(parents=True, exist_ok=True)
    for rel in FILES:
        destination = tree / rel
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / rel, destination)
    shutil.copy2(ROOT / "Scripts" / GATE_NAME, tree / "Scripts" / GATE_NAME)
    shutil.copy2(ROOT / LEDGER_REL, tree / LEDGER_REL)
    return tree


def run_gate(tree: Path) -> tuple[int, str]:
    proc = subprocess.run(
        [sys.executable, str(tree / "Scripts" / GATE_NAME), "--root", str(tree), "--json"],
        capture_output=True, text=True,
    )
    try:
        data = json.loads(proc.stdout)
        return proc.returncode, "；".join(data.get("problems", []))
    except json.JSONDecodeError:
        return proc.returncode, proc.stdout + proc.stderr


def edit(tree: Path, rel: str, transform) -> None:
    path = tree / rel
    path.write_text(transform(path.read_text(encoding="utf-8")), encoding="utf-8")


def ledger_of(tree: Path) -> dict:
    return json.loads((tree / LEDGER_REL).read_text(encoding="utf-8"))


def write_ledger(tree: Path, data: dict) -> None:
    (tree / LEDGER_REL).write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")


def expect(label: str, mutate, needle: str) -> None:
    """拷一棵新树 → 写坏 → 门禁必须报红且点名 needle。"""
    tree = make_tree()
    try:
        mutate(tree)
        code, problems = run_gate(tree)
        if code == 0:
            record(False, label, "门禁没报红（写坏了它还是绿的）")
        elif needle not in problems:
            record(False, label, f"报红了但没提到「{needle}」：{problems[:220]}")
        else:
            record(True, label)
    finally:
        shutil.rmtree(tree, ignore_errors=True)


def main() -> int:
    before = {rel: hashlib.sha256((ROOT / rel).read_bytes()).hexdigest() for rel in FILES}
    print("== 0) 前提：真仓库上这条门禁现在是绿的（负例才有意义）")
    proc = subprocess.run([sys.executable, str(ROOT / "Scripts" / GATE_NAME), "--json"],
                          capture_output=True, text=True)
    if proc.returncode != 0:
        record(False, "真仓库上应该是绿的", proc.stdout[:200] + proc.stderr[:200])
        return 1
    record(True, "真仓库上应该是绿的（负例才有意义）")

    print("\n== A) 新增一处裸的英文失败输出（有人照着老写法加了一条 catch）")

    def add_bare_site(tree: Path) -> None:
        edit(tree, "CLI/main.swift", lambda text: text.replace(
            "    static func main() async {",
            "    static func main() async {\n"
            "        do { try JSONSerialization.jsonObject(with: Data()) }\n"
            "        catch { print(\"新功能失败：\\(error.localizedDescription)\") }\n",
            1))

    expect("裸英文失败输出 → 报红并点名行号与标签", add_bare_site, "裸的英文失败输出")

    print("\n== B) 老写法回来了：把某一处改回直接打原始串")

    def revert_one(tree: Path) -> None:
        edit(tree, "CLI/main.swift", lambda text: text.replace(
            'print("列出表失败：\\(CLIFailureText.oneLine(error))")',
            'print("列出表失败：\\(error.localizedDescription)")', 1))

    expect("改回直接打原始串 → 报红并点名「列出表失败」", revert_one, "列出表失败")

    print("\n== C) 只留一个不接线的入口（helper 在、调用全删）")

    def unwire(tree: Path) -> None:
        edit(tree, "CLI/main.swift", lambda text: text.replace("CLIFailureText.oneLine(error)", "error.localizedDescription"))

    expect("入口没人用 → 报红（反向棘轮）", unwire, "只剩")

    print("\n== D) 口径被改：入口里不再走中性归因那一档")

    def drop_neutral(tree: Path) -> None:
        edit(tree, "CLI/CLIFailureText.swift", lambda text: text.replace(
            "ConnectionFailure.describeNonConnection(error)", "nil", 1))

    expect("中性归因那一档被删 → 报红", drop_neutral, "describeNonConnection")

    print("\n== E) 口径被改：认不出时套一句「连接失败」（R-60 的老毛病）")

    def claim_connection(tree: Path) -> None:
        edit(tree, "CLI/CLIFailureText.swift", lambda text: text.replace(
            "        // 认不出：**原样**返回，不猜测、不套方向结论（口径第 2 条）。\n        return raw",
            "        return \"连接数据库失败：\" + raw", 1))

    expect("认不出却给方向结论 → 报红", claim_connection, "在")

    print("\n== F) 原始串的另一半被删：调试转储没了")

    def drop_dump(tree: Path) -> None:
        edit(tree, "CLI/main.swift", lambda text: text.replace("print(String(reflecting: error))", ""))

    expect("调试转储被删 → 报红", drop_dump, "调试转储")

    print("\n== G) 台账撒谎：入口处数写大")

    def inflate(tree: Path) -> None:
        data = ledger_of(tree)
        data["entryPoint"]["minCallSites"] = 999
        write_ledger(tree, data)

    expect("处数写大 → 报红", inflate, "台账要求至少")

    print("\n== H) 台账陈了：例外条目指向已经不存在的东西")

    def stale_exemption(tree: Path) -> None:
        data = ledger_of(tree)
        data["exemptions"][0]["anchor"] = "print(\"早就没有这行了\\(error.localizedDescription)\")"
        write_ledger(tree, data)

    expect("陈旧例外条目 → 报红", stale_exemption, "陈旧条目要删")

    print("\n== I) 渠道字段的处数对不上（代码变了，台账没跟）")

    def drift_plumbing(tree: Path) -> None:
        data = ledger_of(tree)
        for item in data["plumbing"]:
            if item["anchor"].startswith("return (error.localizedDescription"):
                item["count"] = 7
                break
        write_ledger(tree, data)

    expect("渠道字段处数对不上 → 报红", drift_plumbing, "处数对不上")

    print("\n== J) 证据断言被删（脚本还在、判据没了）")

    def drop_assertion(tree: Path) -> None:
        edit(tree, "Scripts/test-cli-failure-readability.sh", lambda text: text.replace(
            "服务端把这次查询取消了", "（断言被删）"))

    expect("证据脚本缺关键断言 → 报红", drop_assertion, "断言不在位")

    print("\n== K) 真仓库一个字节没动（负例都在副本上做）")
    changed = [rel for rel, digest in before.items() if hashlib.sha256((ROOT / rel).read_bytes()).hexdigest() != digest]
    record(not changed, "负例没有把真仓库写坏（副本上折腾）", "被改： " + "、".join(changed))

    print()
    print(f"通过 {len(passed)} 项，失败 {len(failed)} 项")
    if failed:
        for label in failed:
            print(f"  ❌ {label}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
