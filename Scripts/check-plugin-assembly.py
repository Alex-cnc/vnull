#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""**插件装配链的机械门禁**（FR-PLUG-01 / 02 / 03 / 06 + ADR-35）。

为什么要有它：`FR-PLUG-01~07` 的状态是 ✅，但"当时手动核过一遍"不是证据 ——
新加一个入口、新加一个能力位、把 `private(set)` 拆掉，都能让这些 ✅ 悄悄失效而没人发现。
所以把每条口径写成**可复跑的判据**，接进 `verify-all.sh` 第 10 项，每轮门禁都跑一遍。

守什么（逐条对应需求号）：

  · **FR-PLUG-01 同进程内模块**：全仓无 IPC（`NSXPC` / `xpc_` / `import XPC`）；
    笔记源文件随宿主目标一起编译（不存在"笔记插件"这种独立 target / product）。
  · **FR-PLUG-02 活动栏与可见性**：活动栏有 `case notes`；**判可见性的只有一处**
    （`LicensePresentation.activityItems`，视图层不许自己 `allCases` 过滤）；
    `notes` 只在能力位允许时出现（不是灰掉）。
  · **FR-PLUG-03 单向上下文 / 只传文本与标识**：`AICapture` 的笔记侧入口只收标题 / 正文 / SQL / 连接名；
    **行数据入笔记必须显式 `withRowData()`**，且那个开关全仓只有一处能打开（无法绕过、无法撤回）。
  · **FR-PLUG-06 一套许可三能力位**：`LicenseCapabilities.all` 恰好是三个能力位；
    没有"插件单独授权 / 单独开关"这种东西；档位由能力位推导。
  · **ADR-35 单一判据 + 单一写入口**：`selectedActivityItem` 是 `private(set)`；
    全仓赋值只发生在 `AppState.swift`，且每个赋值点所在函数都过了
    `LicensePresentation.resolveSelection`（"未授权区不可达"因此是结构性的）。

退出码：0 = 全过；1 = 有判据不成立（打印文件 / 行号 / 原因）。
"""

from __future__ import annotations

import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent

NOTE_SOURCES = [
    "Core/Note.swift",
    "Core/NoteBody.swift",
    "Core/License.swift",
    "Core/AICapture.swift",
    "Core/AICaptureUltra.swift",
]

IPC_PATTERNS = [
    (r"\bimport\s+XPC\b", "import XPC"),
    (r"\bNSXPCConnection\b", "NSXPCConnection"),
    (r"\bxpc_connection\b", "xpc_connection"),
    (r"\bxpc_main\b", "xpc_main"),
]

problems: list[str] = []
passed: list[str] = []


def read(relative: str) -> str:
    return (REPO / relative).read_text(encoding="utf-8")


def code_lines(relative: str) -> list[tuple[int, str]]:
    """返回 (行号, 内容)，跳过整行注释 —— 注释里提到类型名不算引用。"""
    out: list[tuple[int, str]] = []
    for number, line in enumerate(read(relative).splitlines(), 1):
        if line.strip().startswith("//"):
            continue
        out.append((number, line))
    return out


def record(name: str, found: list[str]) -> None:
    if found:
        problems.extend(f"[{name}] {item}" for item in found)
    else:
        passed.append(name)


# ---------------------------------------------------------------- FR-PLUG-01

def check_01_single_process() -> list[str]:
    found: list[str] = []
    for directory in ("Core", "App", "CLI"):
        for path in sorted((REPO / directory).rglob("*.swift")):
            relative = str(path.relative_to(REPO))
            for number, line in code_lines(relative):
                for pattern, label in IPC_PATTERNS:
                    if re.search(pattern, line):
                        found.append(f"{relative}:{number}: 出现 {label}（同进程装配，不许有 IPC）")
    for relative in NOTE_SOURCES + ["App/Views/NotesPanel.swift"]:
        if not (REPO / relative).exists():
            found.append(f"{relative}: 笔记源文件不存在（装配链断了？）")
    # 不存在"笔记插件"这种独立 target / product —— 走 Package.swift 的 target 声明星。
    manifest = read("Package.swift")
    for match in re.finditer(r"\.(?:test)?[Tt]arget\(\s*\n?\s*name:\s*\"([^\"]+)\"", manifest):
        name = match.group(1)
        if re.search(r"note|plugin|notebook", name, re.I):
            found.append(f"Package.swift: target \"{name}\" 看起来是独立插件 target（FR-PLUG-01 要求同进程内模块）")
    return found


# ---------------------------------------------------------------- FR-PLUG-02

def check_02_visibility() -> list[str]:
    found: list[str] = []
    bar = read("Core/ActivityBar.swift")
    if not re.search(r"^\s*case notes\b", bar, re.M):
        found.append("Core/ActivityBar.swift: 活动栏没有 `case notes`")

    # 判可见性的只有 LicensePresentation 一处：全仓 `ActivityBarItem.allCases` 只许在 Core 里出现。
    for directory in ("App", "CLI"):
        for path in sorted((REPO / directory).rglob("*.swift")):
            relative = str(path.relative_to(REPO))
            for number, line in code_lines(relative):
                if "ActivityBarItem.allCases" in line:
                    found.append(
                        f"{relative}:{number}: 视图层自己过滤 allCases 决定可见性 —— "
                        f"可见性判据必须只有 LicensePresentation.activityItems 一处"
                    )
    # 唯一判据：能力位 -> 是否显示笔记（不是灰掉、不是另写一个条件）
    presentation = read("Core/LicensePresentation.swift")
    if not re.search(r"case \.notes:\s*return capabilities\.contains\(\.notes\)", presentation):
        found.append("Core/LicensePresentation.swift: 笔记项的可见性不再是 capabilities.contains(.notes)")
    if len(re.findall(r"ActivityBarItem\.allCases\.filter", presentation)) != 1:
        found.append("Core/LicensePresentation.swift: 能力位过滤 allCases 的地方不再是恰好一处")

    # App 侧的"该显示哪几项"只有一条来源。
    app_state = read("App/AppState.swift")
    if "LicensePresentation.activityItems(for: licenseCapabilities)" not in app_state:
        found.append("App/AppState.swift: visibleActivityItems 不再走 LicensePresentation.activityItems")
    if len(re.findall(r"var visibleActivityItems\b", app_state)) != 1:
        found.append("App/AppState.swift: visibleActivityItems 定义不唯一")
    return found


# ---------------------------------------------------------------- FR-PLUG-03

def check_03_one_way_context() -> list[str]:
    found: list[str] = []
    capture = read("Core/AICapture.swift")

    # 笔记侧入口只收文本与标识（类型白名单：String / [String] 及其可选）。
    allowed_types = {"String", "String?", "[String]", "[String]?"}
    for signature_name in ("skillNote", "sqlNote"):
        match = re.search(rf"public static func {signature_name}\((.*?)\)\s*->", capture, re.S)
        if not match:
            found.append(f"Core/AICapture.swift: 找不到 {signature_name} 的签名（改名了？）")
            continue
        for parameter in match.group(1).split(","):
            if ":" not in parameter:
                continue
            type_name = " ".join(parameter.split(":", 1)[1].split("=", 1)[0].split())
            if type_name not in allowed_types:
                found.append(
                    f"Core/AICapture.swift: {signature_name} 的参数类型 {type_name} 不在白名单 "
                    f"{sorted(allowed_types)}（只许文本与标识）"
                )

    # 行数据开关：全仓只有一处能打开，且没有"撤回"入口。
    whole_repo = "\n".join(
        path.read_text(encoding="utf-8")
        for path in sorted((REPO / "Core").glob("*.swift"))
    )
    open_switches = re.findall(r"rowDataConfirmed\s*=\s*true", whole_repo)
    if len(open_switches) != 1:
        found.append(f"Core/: 打开\"含行数据\"的地方有 {len(open_switches)} 处（必须恰好 1 处：NoteDraft.withRowData）")
    if re.search(r"func\s+(withoutRowData|clearRowData|unsetRowData)", whole_repo):
        found.append("Core/: 出现了撤回\"含行数据\"标痕的入口（留痕必须不可撤回）")

    # 来源只记连接名：不存口令 / 连接串 / 主机字段。
    source_block = re.search(r"public struct NoteSource\b.*?\n}\n", read("Core/Note.swift"), re.S)
    if not source_block:
        found.append("Core/Note.swift: 找不到 NoteSource 定义")
    else:
        for banned in ("password", "connectionString", "dsn", "uri"):
            if re.search(rf"\b{banned}\b", source_block.group(0), re.I):
                found.append(f"Core/Note.swift: NoteSource 里出现 {banned}（来源只许连接名字）")

    # 笔记侧文件不引用结果行类型。
    for relative in NOTE_SOURCES:
        for number, line in code_lines(relative):
            for banned in ("ResultRow", "QueryResult", "EffectRow"):
                if re.search(rf"\b{banned}\b", line):
                    found.append(f"{relative}:{number}: 引用了结果行类型 {banned}")
    return found


# ---------------------------------------------------------------- FR-PLUG-06

def check_06_one_license() -> list[str]:
    found: list[str] = []
    license_source = read("Core/License.swift")
    if not re.search(
        r"static let all:\s*LicenseCapabilities\s*=\s*\[\.workspaces,\s*\.database,\s*\.notes\]",
        license_source,
    ):
        found.append("Core/License.swift: `LicenseCapabilities.all` 不再是三个能力位")
    bits = re.findall(r"static let (workspaces|database|notes)\s*=\s*LicenseCapabilities\(rawValue:\s*1\s*<<\s*(\d+)\)", license_source)
    if sorted(int(bit) for _, bit in bits) != [0, 1, 2]:
        found.append(f"Core/License.swift: 能力位不是恰好三位 {bits}")
    # 没有"插件单独授权"这种东西。
    for pattern in (r"static let\s+(notes|plugin)\w*License", r"var\s+isPluginEnabled", r"LicenseEdition\.\w*plugin"):
        if re.search(pattern, license_source, re.I):
            found.append(f"Core/License.swift: 出现插件独立授权痕迹（{pattern}）—— 一套许可三能力位，不做独立开关")
    if not re.search(r"case \.pro:\s*return \[\.workspaces,\s*\.database\]", license_source):
        found.append("Core/License.swift: Pro 档不再等于「工作区 + 数据库」（档位必须由能力位推导）")
    if not re.search(r"case \.standard:\s*return \.notesOnly", license_source):
        found.append("Core/License.swift: Standard 档不再等于「只有笔记」")
    return found


# ---------------------------------------------------------------- ADR-35

def _functions_with_assignments(path: pathlib.Path, needle: str) -> tuple[list[tuple[int, str]], list[str]]:
    """返回 (赋值点列表, 每个赋值点所在函数体里**没**出现 resolveSelection 的说明)。"""
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    assignment = re.compile(rf"(?<![\w.]){needle}\s*=(?!=)")
    declaration = re.compile(rf"\bvar\s+{needle}\b")
    assignments: list[tuple[int, str]] = []
    missing_guard: list[str] = []
    for index, line in enumerate(lines, 1):
        if line.strip().startswith("//"):
            continue
        if declaration.search(line) or not assignment.search(line):
            continue
        assignments.append((index, line.strip()))
        # 往上找最近的 `func`，往下按花括号深度取到函数结束。
        start = index - 1
        while start >= 0 and not re.search(r"\bfunc\s+\w+", lines[start]):
            start -= 1
        depth = 0
        end = index - 1
        for cursor in range(start, len(lines)):
            depth += lines[cursor].count("{") - lines[cursor].count("}")
            if cursor > start and depth <= 0:
                end = cursor
                break
        body = "\n".join(lines[start:end + 1])
        function_name = "<未知>"
        if start >= 0:
            function_match = re.search(r"\bfunc\s+(\w+)", lines[start])
            if function_match:
                function_name = function_match.group(1)
        if "LicensePresentation.resolveSelection" not in body:
            missing_guard.append(
                f"{path.name}:{index}: 函数 {function_name}() 直接改了 {needle} 而没过 resolveSelection"
            )
    return assignments, missing_guard


def check_adr35_single_write_entry() -> list[str]:
    found: list[str] = []
    app_state = REPO / "App/AppState.swift"
    if not re.search(
        r"@Published\s+private\(set\)\s+var\s+selectedActivityItem", app_state.read_text(encoding="utf-8")
    ):
        found.append("App/AppState.swift: selectedActivityItem 不再是 private(set)（写入口会多起来）")

    assignments, missing_guard = _functions_with_assignments(app_state, "selectedActivityItem")
    found.extend(missing_guard)
    if not assignments:
        found.append("App/AppState.swift: 找不到任何 selectedActivityItem 赋值（改名了？）")

    for path in sorted((REPO / "App").rglob("*.swift")):
        if path.name == "AppState.swift":
            continue
        for number, line in code_lines(str(path.relative_to(REPO))):
            if re.search(r"selectedActivityItem\s*=(?!=)", line):
                found.append(
                    f"{path.relative_to(REPO)}:{number}: 在视图 / 命令层直接改了选中项 —— "
                    f"必须走 AppState.selectActivityItem"
                )
    return found


# ---------------------------------------------------------------- 指向别的门禁

def check_pointers() -> list[str]:
    """本轮不重复跑的两条：它们各有自己的脚本，这里只确认指针没断。"""
    found: list[str] = []
    for relative in ("Scripts/check-note-module-isolation.py", "Scripts/test-note-data-boundary.sh"):
        if not (REPO / relative).exists():
            found.append(f"{relative}: 被引用的证据脚本不存在（FR-PLUG-04 / 07 的指针断了）")
    return found


def main() -> int:
    record("FR-PLUG-01 同进程内模块（无 IPC / 无独立插件 target）", check_01_single_process())
    record("FR-PLUG-02 可见性单一判据（未授权不出现）", check_02_visibility())
    record("FR-PLUG-03 单向上下文（只传文本与标识 / 行数据显式留痕）", check_03_one_way_context())
    record("FR-PLUG-06 一套许可三能力位（无插件独立授权）", check_06_one_license())
    record("ADR-35 单一判据 + 单一写入口", check_adr35_single_write_entry())
    record("证据脚本指针（FR-PLUG-04 / 07）", check_pointers())

    if problems:
        print(f"❌ 插件装配链门禁失败（{len(problems)} 条）：")
        for item in problems:
            print("   " + item)
        return 1
    for name in passed:
        print(f"✅ {name}")
    print(f"✅ 插件装配链门禁通过（{len(passed)} 组判据）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
