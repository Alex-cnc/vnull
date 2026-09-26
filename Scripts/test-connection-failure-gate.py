#!/usr/bin/env python3
"""负例：`Scripts/check-connection-failure-coverage.py`（闭环第 14 项）**红得出来吗**。

**为什么单开一个脚本**：门禁绿着只能说明"现在没违规"，**不能**说明它看得见违规 ——
本工程已经栽过两次（L-04 的"失败只记进没人读的变量"、L-05 的"断言被删也照绿"），
所以每条新门禁都配一组负例：**写坏 → 必须报红 → 点名哪一处**。

**做法与其它负例不同的一点**：不改真仓库的文件，而是把**必要的几个文件**拷进临时目录，
在副本上写坏、把门禁指过去（`--root`）。理由是这一组负例要删 `default:` / 挪函数位置，
一旦中途失败就会把真仓库留在半坏状态 —— 副本上折腾没有这个代价。

用法：`python3 Scripts/test-connection-failure-gate.py`
"""

import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GATE_NAME = "check-connection-failure-coverage.py"
LEDGER_REL = "Scripts/connection-failure-dispositions.json"

# 门禁要看的文件（相对路径 → 临时树里的同一位置）
FILES = [
    "Vendor/postgres-nio/Sources/PostgresNIO/New/PSQLError.swift",
    "Core/ConnectionFailure.swift",
    "Core/PostgresService.swift",
    "Core/MySQLService.swift",
    "Scripts/test-connection-errors.sh",
    "Tests/HostResolutionTests.swift",
]

passed: list[str] = []
failed: list[str] = []


def record(ok: bool, label: str, detail: str = "") -> None:
    (passed if ok else failed).append(label)
    print(f"  {'✅' if ok else '❌'} {label}" + (f"  —— {detail}" if detail and not ok else ""))


def make_tree() -> Path:
    tree = Path(tempfile.mkdtemp(prefix="doyah-conn-gate-"))
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
    print("== 0) 前提：真仓库上这条门禁现在是绿的")
    proc = subprocess.run([sys.executable, str(ROOT / "Scripts" / GATE_NAME), "--json"], capture_output=True, text=True)
    if proc.returncode != 0:
        record(False, "真仓库上应该是绿的", proc.stdout[:200] + proc.stderr[:200])
        return 1
    record(True, "真仓库上应该是绿的（负例才有意义）")

    print("\n== A) 驱动升版：多了一个码，台账没登记")

    def add_driver_code(tree: Path) -> None:
        edit(tree, FILES[0], lambda text: text.replace(
            "            case poolClosed\n", "            case poolClosed\n            case brandNewCode\n", 1))

    expect("驱动新增码未登记 → 报红并点名", add_driver_code, "台账里没有的码")

    print("\n== B) 台账陈了：登记了驱动里已经没有的码")

    def stale_ledger(tree: Path) -> None:
        data = ledger_of(tree)
        data["dispositions"]["ghostCode"] = {"kind": "不翻译", "why": "这个码在驱动里已经不存在了，条目该删"}
        write_ledger(tree, data)

    expect("陈旧条目 → 报红并点名", stale_ledger, "已经不在的码")

    print("\n== C) 台账撒谎：说翻译了，映射文件里其实没有")

    def remove_case(tree: Path) -> None:
        edit(tree, "Core/ConnectionFailure.swift", lambda text: text.replace("case .connectionError, ", "", 1))

    expect("caseRef 不在映射文件里 → 报红", remove_case, "台账在撒谎")

    print("\n== D) 登记了却不给理由")

    def short_why(tree: Path) -> None:
        data = ledger_of(tree)
        data["dispositions"]["queryCancelled"]["why"] = "不重要"
        write_ledger(tree, data)

    expect("理由太短 → 报红", short_why, "没有写明处置理由")

    print("\n== E) 兜底分支没了（驱动新增码时会直接崩）")

    def drop_default(tree: Path) -> None:
        edit(tree, "Core/ConnectionFailure.swift", lambda text: text.replace(
            "        default:\n            return Description(",
            "        case .nothingMatchesThis:\n            return Description(", 1))

    expect("没有 default → 报红", drop_default, "兜底")

    print("\n== E') 整个 switch 被拆掉（对账对象消失）")

    def drop_switch(tree: Path) -> None:
        edit(tree, "Core/ConnectionFailure.swift", lambda text: text.replace(
            "switch psqlError.code {", "switch psqlError.code.description {", 1))

    expect("switch 被改名 → 报红并点名", drop_switch, "对账对象")

    print("\n== F) 解析前置检查：被删掉 / 被挪到建连之后")

    def drop_preflight(tree: Path) -> None:
        edit(tree, "Core/PostgresService.swift", lambda text: text.replace(
            "        try ConnectionFailure.requireResolvableHost(config.host, port: config.port)\n", "", 1))

    expect("前置检查被删 → 报红并点名", drop_preflight, "里找不到")

    def move_preflight_after_connect(tree: Path) -> None:
        edit(tree, "Core/PostgresService.swift", lambda text: text.replace(
            "        try ConnectionFailure.requireResolvableHost(config.host, port: config.port)\n", "", 1).replace(
            "        self.connection = newConnection\n",
            "        try ConnectionFailure.requireResolvableHost(config.host, port: config.port)\n"
            "        self.connection = newConnection\n", 1))

    expect("前置检查挪到建连之后 → 报红并点名「之后」", move_preflight_after_connect, "之后")

    print("\n== G) 证据：反向断言被删（只说好话的断言会放过「两句并存」）")

    def drop_negative_assertion(tree: Path) -> None:
        edit(tree, "Scripts/test-connection-errors.sh", lambda text: text.replace("不再说成", "第一版断言"))

    expect("反向断言不在位 → 报红", drop_negative_assertion, "找不到")

    print("\n== H) 驱动换了写法（读不出错误码枚举）")

    def obscure_driver(tree: Path) -> None:
        edit(tree, FILES[0], lambda text: text.replace("enum Base", "enum RenamedBase", 1))

    expect("读不到枚举 → 报红（提醒门禁该更新）", obscure_driver, "读不到")

    print()
    print(f"结果：{len(passed)} 项达到预期，{len(failed)} 项不符")
    if failed:
        for label in failed:
            print(f"  · {label}")
        return 1
    print("✅ 门禁该红的地方都红了，且每次都说清了是哪一处。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
