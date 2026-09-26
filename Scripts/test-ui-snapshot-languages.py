#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""`check-ui-snapshot-languages.py` 的**负例验证**（队列 L-13）。

为什么要有它：那条门禁每跑一次快照就会绿。但"一直是绿的"有两种可能 —— 判据真的守住了，
或者它根本拦不住。本脚本在**临时目录**里造合成清单（不碰真产物、不改任何源码），
把常见的退化方式逐个写坏一遍，断言门禁**真的退出码 1 并报出对的原因**，最后跑一遍正例。

跑法（改门禁 / 改快照工具之后各跑一次）：

    python3 Scripts/test-ui-snapshot-languages.py

退出码 0 = 全部负例达到预期、正例通过。
"""

from __future__ import annotations

import json
import pathlib
import shutil
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent
CHECKER = "Scripts/check-ui-snapshot-languages.py"

results: list[tuple[str, bool, str]] = []


def write_png(directory: pathlib.Path, name: str, payload: bytes) -> str:
    path = directory / f"{name}.png"
    path.write_bytes(payload)
    return str(path)


def record(directory: pathlib.Path, name: str, language: str, payload: bytes, texts: list[str], **overrides):
    item = {
        "name": name,
        "file": write_png(directory, name, payload),
        "width": 10,
        "height": 10,
        "scale": 2.0,
        "scheme": "light",
        "bytes": len(payload),
        "contentRatio": 0.01,
        "renderer": "合成",
        "language": language,
        "localizedStrings": texts,
    }
    item.update(overrides)
    return item


def run(checker_dir: pathlib.Path, manifest: dict, exemptions: dict):
    with (checker_dir / "manifest.json").open("w", encoding="utf-8") as handle:
        json.dump(manifest, handle, ensure_ascii=False)
    with (checker_dir / "exemptions.json").open("w", encoding="utf-8") as handle:
        json.dump(exemptions, handle, ensure_ascii=False)
    proc = subprocess.run(
        [
            sys.executable,
            CHECKER,
            "--manifest",
            str(checker_dir / "manifest.json"),
            "--exemptions",
            str(checker_dir / "exemptions.json"),
        ],
        cwd=REPO,
        capture_output=True,
        text=True,
    )
    return proc.returncode, proc.stdout + proc.stderr


def case(name: str, expect_code: int, expect_text: str, build):
    """`build(directory)` 返回 (manifest, exemptions)。"""
    directory = pathlib.Path(tempfile.mkdtemp(prefix="doyah-lang-neg-"))
    try:
        manifest, exemptions = build(directory)
        code, output = run(directory, manifest, exemptions)
        ok = code == expect_code and expect_text in output
        detail = ""
        if not ok:
            detail = f"退出码 {code}（期望 {expect_code}）/ 输出未含 {expect_text!r}：{output.strip()[:300]}"
        results.append((name, ok, detail))
    finally:
        shutil.rmtree(directory, ignore_errors=True)


# —— 负例 ①：只有中文那一张（语言覆盖缺一半）
def missing_english(directory):
    return (
        {
            "snapshots": [
                record(directory, "panel-a-zh", "zh-Hans", b"aa", ["中文"]),
            ]
        },
        {"exemptions": {}},
    )


case("缺英文那一张", 1, "缺 en", missing_english)


# —— 负例 ②：名字没带语言后缀
def no_suffix(directory):
    return (
        {"snapshots": [record(directory, "panel-a", "zh-Hans", b"aa", ["中文"])]},
        {"exemptions": {}},
    )


case("快照名没带语言后缀", 1, "没带语言后缀", no_suffix)


# —— 负例 ③：未注册却两张逐字节相同（语言没到像素上）
def unregistered_identical(directory):
    return (
        {
            "snapshots": [
                record(directory, "panel-a-zh", "zh-Hans", b"same", ["中文"]),
                record(directory, "panel-a-en", "en", b"same", ["English"]),
            ]
        },
        {"exemptions": {}},
    )


case("未注册却两张相同", 1, "逐字节相同", unregistered_identical)


# —— 负例 ④：注册为语言无关，但两张已经不一样了（条目过期）
def stale_exemption_pixels(directory):
    return (
        {
            "snapshots": [
                record(directory, "panel-a-zh", "zh-Hans", b"aa", ["中文"]),
                record(directory, "panel-a-en", "en", b"bb", ["English"]),
            ]
        },
        {"exemptions": {"panel-a": "活动栏只有图标"}},
    )


case("注册却已随语言变", 1, "条目过期", stale_exemption_pixels)


# —— 负例 ⑤：注册表里有清单里没有的陈旧条目
def stale_exemption_entry(directory):
    return (
        {
            "snapshots": [
                record(directory, "panel-a-zh", "zh-Hans", b"aa", ["中文"]),
                record(directory, "panel-a-en", "en", b"bb", ["English"]),
            ]
        },
        {"exemptions": {"panel-ghost": "这张图早就不渲染了"}},
    )


case("注册表陈旧条目", 1, "陈旧条目", stale_exemption_entry)


# —— 负例 ⑥：记录里没有 localizedStrings（没观测，判据无从下手）
def missing_texts(directory):
    chinese = record(directory, "panel-a-zh", "zh-Hans", b"aa", ["中文"])
    chinese.pop("localizedStrings")
    return (
        {"snapshots": [chinese, record(directory, "panel-a-en", "en", b"bb", ["English"])]},
        {"exemptions": {}},
    )


case("记录缺 localizedStrings", 1, "localizedStrings", missing_texts)


# —— 负例 ⑦：名字说 zh，记录里却是 en
def language_mismatch(directory):
    return (
        {
            "snapshots": [
                record(directory, "panel-a-zh", "en", b"aa", ["中文"]),
                record(directory, "panel-a-en", "en", b"bb", ["English"]),
            ]
        },
        {"exemptions": {}},
    )


case("名字与记录语言不一致", 1, "记录里写的却是", language_mismatch)


# —— 负例 ⑧：PNG 文件不在
def missing_file(directory):
    english = record(directory, "panel-a-en", "en", b"bb", ["English"])
    pathlib.Path(english["file"]).unlink()
    return (
        {"snapshots": [record(directory, "panel-a-zh", "zh-Hans", b"aa", ["中文"]), english]},
        {"exemptions": {}},
    )


case("清单指向的 PNG 不在", 1, "不在", missing_file)


# —— 负例 ⑨：空清单（用法 / 产物问题，退出码 2）
def empty_manifest(directory):
    return ({"snapshots": []}, {"exemptions": {}})


case("清单里一条都没有", 2, "一条快照都没有", empty_manifest)


# —— 正例：两组随语言变 + 一组注册为语言无关，且注册的那组确实逐字节相同
def positive(directory):
    return (
        {
            "snapshots": [
                record(directory, "panel-a-zh", "zh-Hans", b"aa", ["查询", "保存"]),
                record(directory, "panel-a-en", "en", b"bb", ["Query", "Save"]),
                record(directory, "bar-zh", "zh-Hans", b"same", ["数据库", "工作区"]),
                record(directory, "bar-en", "en", b"same", ["Database", "Workspace"]),
            ]
        },
        {"exemptions": {"bar": "只有图标；文案只到 .help 与无障碍标签"}},
    )


case("正例（含一个注册条目）", 0, "语言覆盖门禁通过", positive)

print("==> 界面快照语言覆盖门禁 · 负例验证")
for name, ok, detail in results:
    print(f"  {'✅' if ok else '❌'} {name}")
    if not ok:
        print(f"      {detail}")

failures = [name for name, ok, _ in results if not ok]
print()
if failures:
    print(f"❌ {len(failures)}/{len(results)} 项未达预期：{'、'.join(failures)}")
    sys.exit(1)
print(f"✅ {len(results)}/{len(results)} 项达到预期（门禁真的会红，正例也真的会绿）")
