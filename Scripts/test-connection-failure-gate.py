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
    "Core/Localization.swift",
    "Core/PostgresService.swift",
    "Core/MySQLService.swift",
    "Scripts/test-connection-errors.sh",
    "Tests/HostResolutionTests.swift",
    "Tests/ConnectionFailureNonConnectionTests.swift",
    "App/Utilities/ErrorPresenter.swift",
    "App/Views/ConnectionFormView.swift",
    "CLI/main.swift",
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
            "        default:\n",
            "        case .nothingMatchesThis:\n", 1))

    expect("没有 default → 报红", drop_default, "兜底")

    print("\n== E'') 兜底又开始给方向结论（R-60 的老毛病）")

    def default_claims_connection(tree: Path) -> None:
        edit(tree, "Core/ConnectionFailure.swift", lambda text: text.replace(
            "        default:\n", "        default:\n            return ConnectionFailure.Description(summary: \"连接数据库失败\")\n", 1))

    expect("兜底不是 return nil → 报红并点名 R-60", default_claims_connection, "把猜测当结论")

    print("\n== E''') 那一族不再让路（表在，但没接上）")

    def no_bypass(tree: Path) -> None:
        edit(tree, "Core/ConnectionFailure.swift", lambda text: text.replace(
            "if nonConnectionKeys[psqlError.code.description] != nil { return nil }", "", 1))

    expect("describe 里不再按表让路 → 报红", no_bypass, "让路")

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

    print("\n== I) 中性归因：登记了却不写话（表里没这个码）")

    def drop_neutral_note(tree: Path) -> None:
        edit(tree, "Core/ConnectionFailure.swift", lambda text: text.replace(
            '        "queryCancelled": (.nonConnectionCancelled, .nonConnectionCancelledAdvice),\n', "", 1))

    expect("中性归因的码不在 nonConnectionKeys 里 → 报红", drop_neutral_note, "却不写话")

    print("\n== J) 中性归因：台账指的那句话在语言表里不存在（键名写错 / 被删）")

    def drop_neutral_key(tree: Path) -> None:
        # 把语言表里的那一行改名（不是删枚举 case —— 那是编译错误，不是这道门禁该管的事）
        edit(tree, "Core/Localization.swift", lambda text: text.replace(
            "        .nonConnectionCancelled: [", "        .nonConnectionCancelledRenamed: [", 1))

    expect("neutralKey 在语言表里找不到 → 报红", drop_neutral_key, "台账在撒谎")

    print("\n== K) 中性归因的出口断了（CLI 里不再接这一档）")

    def drop_cli_exit(tree: Path) -> None:
        edit(tree, "CLI/main.swift", lambda text: text.replace(
            "ConnectionFailure.describeNonConnection(error)", "", 1))

    expect("CLI 不接中性归因 → 报红（用户只剩英文调试串）", drop_cli_exit, "中性归因出口")

    print("\n== M) 中性归因出口被全部删掉（两条路都不接了）")

    def drop_all_cli_exits(tree: Path) -> None:
        edit(tree, "CLI/main.swift", lambda text: text.replace(
            "ConnectionFailure.describeNonConnection(error)", ""))

    expect("CLI 两处出口都不在 → 报红", drop_all_cli_exits, "中性归因出口")

    print("\n== N) 台账没写「至少几处」（只登记「有这个调用」）")

    def ledger_drops_min_sites(tree: Path) -> None:
        data = ledger_of(tree)
        for entry in data["neutralFallback"]:
            entry.pop("minCallSites", None)
        write_ledger(tree, data)

    expect("台账没写 minCallSites → 报红（不许只登记「有这个调用」）", ledger_drops_min_sites, "中性归因出口")

    print("\n== O) 台账把处数写大了（数字好看，代码里没有）")

    def ledger_overstates_sites(tree: Path) -> None:
        data = ledger_of(tree)
        for entry in data["neutralFallback"]:
            if entry["file"] == "CLI/main.swift":
                entry["minCallSites"] = 3
        write_ledger(tree, data)

    expect("台账写 3 处而代码只有 2 处 → 报红", ledger_overstates_sites, "中性归因出口")

    print("\n== K'') 语言表整个读不到（那句话没地方放）")

    def drop_language_table(tree: Path) -> None:
        (tree / "Core/Localization.swift").unlink()

    expect("语言表不存在 → 报红", drop_language_table, "语言表读不到")

    print("\n== L) 查询被取消那一档（57014）不再被接住 / 名单没人读")

    def drop_sqlstate(tree: Path) -> None:
        edit(tree, "Core/ConnectionFailure.swift", lambda text: text.replace(
            'public static let nonConnectionSQLStates: [String] = ["57014"]',
            'public static let nonConnectionSQLStates: [String] = []', 1))

    expect("57014 不在名单里 → 报红（这一档会退回英文调试串）", drop_sqlstate, "名单里没有它")

    def unread_sqlstate_list(tree: Path) -> None:
        edit(tree, "Core/ConnectionFailure.swift", lambda text: text.replace(
            "guard nonConnectionSQLStates.contains(state) else { return nil }",
            "guard state == \"57014\" else { return nil }", 1))

    expect("名单在但没人读 → 报红（登记等于没生效）", unread_sqlstate_list, "没读它")

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
