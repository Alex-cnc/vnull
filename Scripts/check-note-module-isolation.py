#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""笔记模块的**解耦门禁**（FR-PLUG-07 / FR-NOTE-23 / 版本矩阵的硬约束）。

为什么要有它：`Doyah Notes`（Windows / 移动）是**独立应用**，不能背着数据库代码；
而"约定别依赖"这种纪律在几百个文件里迟早失守。所以把它变成一条**机械检查**。

口径（刻意保守，只查真正该干净的那一层）：
  · 扫描范围 = **Core 里直接属于笔记的源文件**（`Note` / `NoteBody` / `License` / `AICapture`）；
  · 禁止 import 平台模块（只允许 Foundation）；
  · 禁止引用**数据库侧类型名**（DatabaseService / PostgresService / MySQLDialect / ConnectionConfig …）；
  · 禁止引用 **Ultra 侧类型名**（DiagnosisContext / MaintenancePlanReview / MaintenanceTask …）
    —— 这些类型只有"数据库 + 工作区 + 笔记"全量的构建里才有，笔记侧文件引用它们就等于绑死在宿主上；
  · 发现违规 → 退出码 1，并列出文件、行号、命中的名字。

**当前未覆盖（写在这里，不让它悄悄通过）**：
  · **App 层**：`AppState` 同时认识笔记与数据库 —— 那是"只装配笔记那一块"改造前的事实。
    插件装配的其它约束（同进程 / 单一判据 / 单向上下文）由 `check-plugin-assembly.py` 守。

**历史（L-04，2026-09-26）**：这条门禁原先只ban数据库类型，而 `AICapture.swift` 里留着两个
helper，**参数就是 Ultra 侧类型**（`fingerprint(of:report:)` / `stateText(_:)`）。它们当时
既不在禁用名单里，也没被本脚本看见 —— 于是门禁绿着，而"笔记侧文件可独立构建"这句话不成立。
修法：两个 helper 搬进 `AICaptureUltra.swift`，Ultra 侧类型名进禁用名单（本脚本现在真能拦住）。

**自维护**：`NOTE_SOURCES` 靠人维护，漏加一个文件＝那个文件偷偷不受约束。所以本脚本每次
都拿 `Core/` 里的实际文件名与清单对账（见 `check_source_list_is_complete`）。
"""

from __future__ import annotations

import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
# 只扫"Core 里直接属于笔记"的文件；新增笔记源文件时把它加进来（漏加会被下面的自维护检查抓到）。
NOTE_SOURCES = [
    "Core/Note.swift",
    "Core/NoteBody.swift",
    "Core/License.swift",
    # 拆分后 `AICapture` 只剩"笔记侧"的映射（诊断 / 维护那两个已移到 AICaptureUltra）
    "Core/AICapture.swift",
]

# 刻意**不在**清单里的笔记相关文件：它们按设计就引用 Ultra 侧类型，属于宿主侧适配层。
# 在这里显式列出（而不是靠"忘了加"），自维护检查才不会误报。
ULTRA_SIDE_SOURCES = [
    "Core/AICaptureUltra.swift",
]

BANNED_IMPORTS = re.compile(r"^\s*import\s+(?!Foundation\b)(\w+)", re.M)
BANNED_TYPES = [
    # 数据库侧（Doyah Notes 不能背数据库代码）
    "DatabaseService", "NotImplementedDatabaseService", "PostgresService", "MySQLService",
    "GBaseService", "SQLDialect", "PostgresDialect", "MySQLDialect", "GBaseDialect",
    "DatabaseServiceFactory", "SQLDialectFactory", "MetadataService", "StatementSplitter",
    "ConnectionConfig", "ConnectionStore", "DatabaseType",
    # Ultra 侧（只有全量构建里才有这些类型）
    "DiagnosisContext", "DiagnosisAdviceReport", "DiagnosisReport",
    "MaintenancePlanReview", "MaintenanceTask", "MaintenancePlan",
]


def check_source_list_is_complete() -> list[str]:
    """`Core/` 下的笔记源文件必须"要么在清单里、要么在豁免名单里"。"""
    problems: list[str] = []
    on_disk = sorted(
        path.name for path in (REPO / "Core").glob("*.swift")
        if path.name.startswith("Note") or path.name.startswith("AICapture")
    )
    listed = {pathlib.Path(item).name for item in NOTE_SOURCES + ULTRA_SIDE_SOURCES}
    for name in on_disk:
        if name not in listed:
            problems.append(
                f"Core/{name}: 新的笔记源文件没进本脚本的清单"
                f"（是笔记侧就加进 NOTE_SOURCES，是宿主侧就加进 ULTRA_SIDE_SOURCES）"
            )
    for name in sorted(listed):
        if not (REPO / "Core" / name).exists():
            problems.append(f"Core/{name}: 清单里有、磁盘上没有（改名了？请同步更新本脚本）")
    return problems


def main() -> int:
    problems: list[str] = []
    checked = 0
    for relative in NOTE_SOURCES:
        path = REPO / relative
        if not path.exists():
            print(f"⚠️  找不到 {relative}（改名了？请同步更新本脚本的清单）")
            problems.append(f"{relative}: 文件不存在")
            continue
        checked += 1
        text = path.read_text(encoding="utf-8")
        for line_number, line in enumerate(text.splitlines(), 1):
            stripped = line.strip()
            if stripped.startswith("//"):
                continue
            for match in BANNED_IMPORTS.finditer(line):
                problems.append(f"{relative}:{line_number}: import {match.group(1)}")
            for name in BANNED_TYPES:
                # 用词边界，避免把 NoteBodyFormat 之类误判
                if re.search(rf"\b{name}\b", line):
                    problems.append(f"{relative}:{line_number}: 引用了 {name}")

    problems.extend(check_source_list_is_complete())

    if problems:
        print("❌ 笔记模块解耦门禁失败（Doyah Notes 不能背数据库 / Ultra 侧代码）：")
        for item in problems:
            print("   " + item)
        return 1
    print(
        f"✅ 笔记模块解耦门禁通过（{checked} 个笔记源文件：无平台 import、"
        f"无数据库侧类型引用、无 Ultra 侧类型引用；清单与 Core/ 实际文件对账一致）"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
