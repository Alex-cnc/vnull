#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""`check-effective-language.py` 的**负例验证**（队列 L-13）。

为什么要有它：那条门禁每轮都绿。但"一直是绿的"有两种可能 —— 口径守住了，或者它根本拦不住
（第 10 / 11 / 12 轮各吃过一次：假绿的占位图、注释里的假设、以及一条只在**读图**时才看得出来的
语言混排）。本脚本把常见的退化方式逐个写坏一遍，断言门禁**真的退出码 1 并报出对的原因**。

**只在临时副本上改**：把仓库的 `App/` 拷到临时目录，在副本上写坏，跑门禁时用 `--root` 指过去。
仓库本身一个字节都不动（跑完会断言这一点）。

跑法（改门禁 / 改语言来源相关代码之后各跑一次）：

    python3 Scripts/test-effective-language-gate.py

退出码 0 = 全部负例达到预期。
"""

from __future__ import annotations

import pathlib
import shutil
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent
CHECKER = "Scripts/check-effective-language.py"

results: list[tuple[str, bool, str]] = []


def snapshot(directory: pathlib.Path) -> dict[str, str]:
    out = {}
    for path in sorted(directory.rglob("*.swift")):
        out[path.relative_to(directory).as_posix()] = path.read_text(encoding="utf-8")
    return out


def run(root: pathlib.Path):
    proc = subprocess.run(
        [sys.executable, CHECKER, "--root", str(root)],
        cwd=REPO,
        capture_output=True,
        text=True,
    )
    return proc.returncode, proc.stdout + proc.stderr


def case(name: str, expect_code: int, expect_text: str, mutate):
    """`mutate(app_dir)` 在副本上写坏；返回改动的相对路径（供报告）。"""
    temp = pathlib.Path(tempfile.mkdtemp(prefix="doyah-lang-gate-"))
    try:
        shutil.copytree(REPO / "App", temp / "App")
        mutate(temp / "App")
        code, output = run(temp)
        ok = code == expect_code and expect_text in output
        detail = ""
        if not ok:
            detail = f"退出码 {code}（期望 {expect_code}）/ 输出未含 {expect_text!r}：{output.strip()[:400]}"
        results.append((name, ok, detail))
    finally:
        shutil.rmtree(temp, ignore_errors=True)


# —— 负例 ①：把已经修好的那处改回去（非例外文件按用户选择取语言）
def revert_row_detail(app: pathlib.Path):
    path = app / "Views" / "RowDetailPanel.swift"
    text = path.read_text(encoding="utf-8")
    assert "LocalizationManager.shared.effectiveLanguage" in text
    path.write_text(
        text.replace("LocalizationManager.shared.effectiveLanguage", "LocalizationManager.shared.language"),
        encoding="utf-8",
    )


case("改回用户选择（RowDetailPanel）", 1, "RowDetailPanel.swift", revert_row_detail)


# —— 负例 ②：新写的视图里再出现一次
def new_offender(app: pathlib.Path):
    (app / "Views" / "BrandNewPanel.swift").write_text(
        "import SwiftUI\n\nstruct BrandNewPanel: View {\n"
        "    var body: some View { Text(TerminalCursorStyle.block.label(language: localization.language)) }\n"
        "}\n",
        encoding="utf-8",
    )


case("新文件里又按用户选择取语言", 1, "BrandNewPanel.swift", new_offender)


# —— 负例 ③：口子被改名（门禁要当场说清，而不是从此什么都查不到）
def rename_gateway(app: pathlib.Path):
    path = app / "LocalizationManager.swift"
    text = path.read_text(encoding="utf-8")
    assert "var effectiveLanguage: AppLanguage" in text
    path.write_text(text.replace("var effectiveLanguage: AppLanguage", "var currentLanguage: AppLanguage"), encoding="utf-8")


case("口子被改名", 1, "effectiveLanguage", rename_gateway)


# —— 负例 ④：例外表陈旧（文件里已经没有那种写法了）
def stale_exception(app: pathlib.Path):
    path = app / "MainMenuLocalizer.swift"
    text = path.read_text(encoding="utf-8")
    assert "LocalizationManager.shared.language" in text
    path.write_text(text.replace("LocalizationManager.shared.language", "LocalizationManager.shared.effectiveLanguage"), encoding="utf-8")


case("例外表陈旧条目", 1, "陈旧", stale_exception)


# —— 负例 ⑤：例外表里的文件没了
def missing_exception_file(app: pathlib.Path):
    (app / "MainMenuLocalizer.swift").unlink()


case("例外表文件不存在", 1, "不存在", missing_exception_file)


# —— 正例：未改动的副本必须绿
case("正例（未改动的副本）", 0, "语言来源门禁通过", lambda app: None)

print("==> 「当前语言只有一个来源」门禁 · 负例验证")
for name, ok, detail in results:
    print(f"  {'✅' if ok else '❌'} {name}")
    if not ok:
        print(f"      {detail}")

# 收场：断言仓库自身一个字节都没动（本轮全部改动只发生在临时副本里）
before = snapshot(REPO / "App")
proc = subprocess.run(["git", "status", "--porcelain", "App"], cwd=REPO, capture_output=True, text=True)
after = snapshot(REPO / "App")
if before != after:
    results.append(("仓库 App/ 未被改动", False, "临时副本的操作漏到了仓库上"))
else:
    results.append(("仓库 App/ 未被改动", True, ""))

changed = [line for line in proc.stdout.splitlines() if line.strip()]
print(f"\n（仓库 App/ 当前 git 状态：{'干净' if not changed else '有改动 → ' + '；'.join(changed)}）")

failures = [name for name, ok, _ in results if not ok]
print()
if failures:
    print(f"❌ {len(failures)}/{len(results)} 项未达预期：{'、'.join(failures)}")
    sys.exit(1)
print(f"✅ {len(results)}/{len(results)} 项达到预期（门禁真的会红，正例也真的会绿）")
