#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""笔记模块的**解耦门禁**（FR-NOTE-23 / 版本矩阵的硬约束）。

为什么要有它：`Doyah Notes`（Windows / 移动）是**独立应用**，不能背着数据库代码；
而"约定别依赖"这种纪律在几百个文件里迟早失守。所以把它变成一条**机械检查**。

口径（刻意保守，只查真正该干净的那一层）：
  · 扫描范围 = **Core 里直接属于笔记的源文件**（Note / NoteBody / License 等）；
  · 禁止 import 平台/数据库模块（只允许 Foundation）；
  · 禁止引用数据库侧类型名（DatabaseService / PostgresService / MySQLService / SQLDialect …）；
  · 发现违规 → 退出码 1，并列出文件、行号、命中的名字。

**已知未覆盖（写在这里，不让它悄悄通过）**：
  · **App 层**：`AppState` 现在同时认识笔记与数据库 —— 那是"只装配笔记那一块"改造前的事实；
  · **`Core/AICapture.swift`**：它把"诊断结论 / 维护计划"映射成笔记草稿，因此**天然引用 Ultra 侧类型**
    （`DiagnosisContext` / `MaintenancePlanReview`）。正确做法是**拆成两层**：
    笔记侧只收"标题 / 正文 / 来源"（`skillNote` / `sqlNote` 已属这一侧），
    Ultra 侧再放"诊断 / 维护 → 草稿"的适配器 —— 拆完把 AICapture 纳入本门禁。
"""

from __future__ import annotations

import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
# 只扫"Core 里直接属于笔记"的文件；新增笔记源文件时把它加进来。
NOTE_SOURCES = [
    "Core/Note.swift",
    "Core/NoteBody.swift",
    "Core/License.swift",
    # 拆分后 `AICapture` 只剩"笔记侧"的映射（诊断 / 维护那两个已移到 AICaptureUltra）
    "Core/AICapture.swift",
]

BANNED_IMPORTS = re.compile(r"^\s*import\s+(?!Foundation\b)(\w+)", re.M)
BANNED_TYPES = [
    "DatabaseService", "NotImplementedDatabaseService", "PostgresService", "MySQLService",
    "GBaseService", "SQLDialect", "PostgresDialect", "MySQLDialect", "GBaseDialect",
    "DatabaseServiceFactory", "SQLDialectFactory", "MetadataService", "StatementSplitter",
    "ConnectionConfig", "ConnectionStore", "DatabaseType",
]


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

    if problems:
        print("❌ 笔记模块解耦门禁失败（Doyah Notes 不能背数据库代码）：")
        for item in problems:
            print("   " + item)
        return 1
    print(f"✅ 笔记模块解耦门禁通过（{checked} 个源文件：无平台 import、无数据库侧类型引用）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
