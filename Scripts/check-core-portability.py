#!/usr/bin/env python3
"""Core 平台中立性闸门：Core 里不得出现任何平台专属依赖。

存在的理由（实测，2026-09-23）：
    问「换到 Linux 会不会报错」时，先看的是 `/Users/<用户名>` 这类绝对路径 —— 结果它们是
    **注入参数的测试、注释和文档**，纯字符串，换平台毫无影响。真正会挂的是 Core 里的
    三处 macOS 专属依赖：

      1. `Core/KeychainHelper.swift`          —— `import Security`（钥匙串实现）
      2. `Core/AgentConfigurationStore.swift` —— `import Security`（同上）
      3. `Core/SecureDirectoryAccess.swift`   —— macOS-only 的 Foundation 书签 API
      4. `Core/AppError.swift`                —— `OSStatus`（Darwin 类型）

    Linux 上没有这些模块/类型，Core 会**直接编译不过**。已把它们移到 `Platform/macOS/`
    平台模块（Core 只留协议），本脚本负责让它不再回潮。

口径：
    · 只管 `Core/**/*.swift` —— 平台模块与 App 本来就该写平台实现，不在此列；
    · 确有必要时在该行加 `// portability-ok: 理由` 显式豁免（会有审计痕迹）。

用法：
    python3 Scripts/check-core-portability.py            # 校验（闸门）
    python3 Scripts/check-core-portability.py --report   # 列出命中
"""

from __future__ import annotations

import pathlib
import re
import sys

CORE = pathlib.Path("Core")
EXEMPT_MARK = "portability-ok"

RULES: dict[str, str] = {
    "平台专属模块 import（Linux 上没有这个模块，编译直接失败）":
        r"^\s*(?:@preconcurrency\s+)?import\s+(AppKit|SwiftUI|Security|Cocoa|CoreGraphics|Combine|Darwin|Glibc|XCTest|Metal|CoreData)\b",
    "Darwin / Security 类型与常量":
        r"\b(OSStatus|CFDictionary|CFTypeRef|CFString|CFArray|SecItem[A-Za-z]*|kSec[A-Za-z]+|errSec[A-Za-z]+)\b",
    "macOS 专属的 AppKit 类型":
        r"\b(NSView|NSWindow|NSColor|NSFont|NSImage|NSPasteboard|NSSavePanel|NSOpenPanel|NSTableView|NSTextView|NSApplication)\b",
    "macOS 专属的 Foundation API（安全作用域书签 / 沙箱授权）":
        r"(withSecurityScope|resolvingBookmarkData|startAccessingSecurityScopedResource|stopAccessingSecurityScopedResource|bookmarkData\(\s*options)",
    "平台条件编译（Core 里不该有「这台机器是哪个平台」的判断）":
        r"#if\s+(os\(|canImport\((Darwin|Security|AppKit|SwiftUI|Cocoa)\))",
    "硬编码绝对路径":
        r"\"/(Users|Applications|Library|System|opt/|usr/local)/",
}


def scan() -> list[tuple[str, str, int, str, str]]:
    """返回 [(规则, 文件, 行号, 命中文本, 整行)]。"""
    findings: list[tuple[str, str, int, str, str]] = []
    for path in sorted(CORE.rglob("*.swift")):
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if EXEMPT_MARK in line:
                continue
            stripped = line.lstrip()
            if stripped.startswith("//") and "import " not in stripped:
                continue        # 纯注释行不算（注释里提 macOS 是为了解释为什么这么写）
            for label, pattern in RULES.items():
                for match in re.finditer(pattern, line):
                    findings.append((label, str(path), number, match.group(0), line.strip()))
    return findings


def main() -> int:
    findings = scan()
    if "--report" in sys.argv[1:]:
        for label, path, number, hit, line in findings:
            print(f"{path}:{number}  [{label}] → {hit}")
            print(f"    {line[:120]}")
        print(f"\n合计 {len(findings)} 处")
        return 0

    if not findings:
        print("✅ Core 平台中立性校验通过（无平台专属依赖 —— 换平台不会编译失败）")
        return 0

    print(f"❌ Core 平台中立性校验失败：{len(findings)} 处平台专属依赖")
    for label, path, number, hit, line in findings:
        print(f"   {path}:{number}  [{label}] → {hit}")
    print("   修法：协议留在 Core，实现移到 Platform/macOS/；确有必要时加 // portability-ok: 理由。")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
