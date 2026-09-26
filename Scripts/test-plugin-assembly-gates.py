#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""插件链两条门禁的**负例验证**（FR-PLUG-01~03 / 06 / 07 + ADR-35）。

为什么要有它：`check-plugin-assembly.py` 与 `check-note-module-isolation.py` 每轮都绿 ——
但"一直是绿的"有两种可能：口径守住了，或者门禁根本拦不住。本脚本把**常见的退化方式**
逐个写坏一遍，断言门禁真的退出码 1 并报出对的原因，然后还原。

每个负例：写坏 → 跑门禁 → 断言（退出码 = 1 且输出含预期原因）→ 还原 → 断言字节回到原样；
收场再断言工作区只剩本轮该改的文件（探针文件必须删掉）。

**故意不接进 `verify-all.sh`**：它要临时改源码。按需跑（改门禁 / 拆笔记模块之后各跑一次）：

    python3 Scripts/test-plugin-assembly-gates.py

退出码 0 = 全部负例达到预期（门禁真的会红）。
"""
import pathlib
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
ASSEMBLY = "Scripts/check-plugin-assembly.py"
ISOLATION = "Scripts/check-note-module-isolation.py"

EXPECTED_WORKTREE = {
    "Core/AICapture.swift",
    "Core/AICaptureUltra.swift",
    "Scripts/check-note-module-isolation.py",
    "Scripts/check-plugin-assembly.py",
    "Scripts/test-plugin-assembly-gates.py",
}

results = []
failures = []


def run(script):
    proc = subprocess.run([sys.executable, script], cwd=REPO, capture_output=True, text=True)
    return proc.returncode, proc.stdout + proc.stderr


def case(name, relative, transform, script, expect_code, expect_text):
    path = REPO / relative
    existed = path.exists()
    original = path.read_text(encoding="utf-8") if existed else ""
    try:
        new_text = transform(original)
        assert new_text != original, f"{name}: 修改没有生效（文本没变）"
        path.write_text(new_text, encoding="utf-8")
        code, output = run(script)
        ok = (code == expect_code) and (expect_text in output)
        detail = "退出码 %d（期望 %d）" % (code, expect_code)
        if expect_text not in output:
            detail += "；输出里没有 %r" % expect_text
        results.append((name, ok, detail))
        if not ok:
            failures.append(f"{name}: {detail}\n{output}")
    finally:
        if existed:
            path.write_text(original, encoding="utf-8")
            if path.read_text(encoding="utf-8") != original:
                failures.append(f"{name}: 还原失败！{relative}")
        elif path.exists():
            path.unlink()


def add(snippet):
    def transform(text):
        return text + "\n" + snippet + "\n"
    return transform


def replace(old, new):
    def transform(text):
        assert old in text, f"找不到待替换的片段：{old}"
        return text.replace(old, new, 1)
    return transform


# ---- 装配链门禁的负例 -------------------------------------------------------
case("FR-PLUG-02 视图层自己过滤 allCases", "App/Views/ActivityBarView.swift",
     add('private func __negativeProbe() { _ = ActivityBarItem.allCases }'),
     ASSEMBLY, 1, "视图层自己过滤 allCases")

case("ADR-35 绕过 resolveSelection 直接赋值", "App/AppState.swift",
     add('extension AppState { func __negativeProbeSet() { selectedActivityItem = .notes } }'),
     ASSEMBLY, 1, "没过 resolveSelection")

case("ADR-35 selectedActivityItem 不再是 private(set)", "App/AppState.swift",
     replace("@Published private(set) var selectedActivityItem", "@Published var selectedActivityItem"),
     ASSEMBLY, 1, "不再是 private(set)")

case("FR-PLUG-06 能力位少一位（笔记没进一套许可）", "Core/License.swift",
     replace("static let all: LicenseCapabilities = [.workspaces, .database, .notes]",
             "static let all: LicenseCapabilities = [.workspaces, .database]"),
     ASSEMBLY, 1, "不再是三个能力位")

case("FR-PLUG-03 笔记侧入口混进非文本参数", "Core/AICapture.swift",
     replace("public static func sqlNote(sql: String, connectionName: String?, title: String? = nil)",
             "public static func sqlNote(sql: String, connectionName: String?, title: String? = nil, extra: [String: Any] = [:])"),
     ASSEMBLY, 1, "不在白名单")

# ---- 解耦门禁的负例 ---------------------------------------------------------
case("FR-PLUG-07 笔记源文件引用 Ultra 侧类型", "Core/AICapture.swift",
     add("func __negativeProbe(_ context: DiagnosisContext) {}"),
     ISOLATION, 1, "引用了 DiagnosisContext")

case("FR-PLUG-07 新笔记源文件没进门禁清单", "Core/NoteNegativeProbe.swift",
     lambda _: "import Foundation\n\nstruct __NegativeProbe: Sendable { let id: String }\n",
     ISOLATION, 1, "没进本脚本的清单")

# ---- 收场：探针文件、工作区都要干净 -----------------------------------------
probe = REPO / "Core/NoteNegativeProbe.swift"
if probe.exists():
    probe.unlink()
    results.append(("探针文件已删除 Core/NoteNegativeProbe.swift", True, ""))

status = subprocess.run(["git", "status", "--porcelain"], cwd=REPO, capture_output=True, text=True).stdout
unexpected = [line[3:] for line in status.splitlines() if line[3:] not in EXPECTED_WORKTREE]
results.append(("工作区只剩本轮该改的文件", not unexpected,
                "多余改动：%s" % unexpected if unexpected else ""))

print("=== 负例验证 ===")
for name, ok, detail in results:
    print(("  PASS  " if ok else "  FAIL  ") + name + (f"  [{detail}]" if detail and not ok else ""))
print()
if failures:
    print(f"❌ {len(failures)} 个负例没达到预期：")
    for item in failures:
        print("----\n" + item)
    sys.exit(1)
print(f"✅ 全部 {len(results)} 个负例达到预期（门禁真的会红，改动已还原）")
