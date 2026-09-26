#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""**界面快照的语言覆盖门禁**（队列 L-13）。

为什么要有它：L-13 把「语言」做成了宿主参数，于是每张图都有中英两份。但"两份都生成了"
**不等于**"语言到了像素上"——最容易发生的退化是：宿主参数被忽略、或某个面板的文案走了
绕过 `L(...)` 的路，于是两张图**逐字节相同**，而图看起来照样正常（第 10 / 11 轮吃过两次
「判据太松」的亏：一次是假绿的占位图，一次是注释里的假设被实测推翻）。

判据（两个方向都是硬的，只留一个口子）：

  · **未注册**的快照：中英两张 PNG 必须**逐字节不同**
    —— 相同 ⇒ 语言没到像素上（或者这张图本来就是语言无关的，那就要**显式注册**并写明理由）。
  · **已注册为语言无关**的快照（`Scripts/ui-snapshot-language-exemptions.json`）：两张必须**逐字节相同**
    —— 不同 ⇒ 条目过期（那张图已经随语言变了），必须把条目删掉。
  · 注册表里**不得有陈旧条目**（manifest 里没有这张图 ⇒ 红）。
  · 每个快照名必须带 `-zh` / `-en`，且**每个 base 恰好各一份**。
  · 每条记录必须带 `language` 与 `localizedStrings`（证明快照工具自己把语言落进了清单）。

另外**打印**（不判、供人读）两侧的文案观测：
  · 「注册为语言无关但两遍文案不同」是**正常**的 —— 活动栏正是如此（`L(item.titleKey)`
    只走到 `.help` 与无障碍标签，不进像素）；
  · 「未注册但两遍文案相同」也打印出来 —— 说明那张图的语言差异不是文案带来的，
    看图时可以留意（若哪天它同时**不随语言变化**，会被第一条判据拦下，届时再决定是修
    视图还是注册）。

跑法：

    python3 Scripts/check-ui-snapshot-languages.py                       # 读 .build/ui-snapshots/manifest.json
    python3 Scripts/check-ui-snapshot-languages.py --manifest /tmp/x/manifest.json

它由 `Scripts/make-ui-snapshots.sh` 在渲染完**立刻**调用 —— 快照是取证工具、不进每轮门禁，
但**取证那一刻**要把这件事判住。负例见 `Scripts/test-ui-snapshot-languages.py`。

退出码：0 = 全过；1 = 有判据不成立（打印快照名与原因）；2 = 用法 / 文件问题。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_MANIFEST = REPO / ".build" / "ui-snapshots" / "manifest.json"
DEFAULT_EXEMPTIONS = REPO / "Scripts" / "ui-snapshot-language-exemptions.json"

LANGUAGE_SUFFIX = {"-zh": "zh-Hans", "-en": "en"}


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_json(path: pathlib.Path):
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def split_name(name: str):
    """`result-table-empty-dark-zh` → (`result-table-empty-dark`, `zh-Hans`)；不带后缀则返回 None。"""
    for suffix, language in LANGUAGE_SUFFIX.items():
        if name.endswith(suffix):
            return name[: -len(suffix)], language
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description="界面快照的语言覆盖门禁（L-13）")
    parser.add_argument("--manifest", default=str(DEFAULT_MANIFEST))
    parser.add_argument("--exemptions", default=str(DEFAULT_EXEMPTIONS))
    parser.add_argument("--quiet", action="store_true", help="只打印结论行")
    args = parser.parse_args()

    manifest_path = pathlib.Path(args.manifest)
    exemptions_path = pathlib.Path(args.exemptions)

    if not manifest_path.exists():
        print(f"❌ 没有清单：{manifest_path}（先跑 ./Scripts/make-ui-snapshots.sh）")
        return 2

    manifest = load_json(manifest_path)
    snapshots = manifest.get("snapshots") or []
    if not snapshots:
        print(f"❌ 清单里一条快照都没有：{manifest_path}")
        return 2

    exemptions_payload = load_json(exemptions_path) if exemptions_path.exists() else {"exemptions": {}}
    exemptions = exemptions_payload.get("exemptions") or {}

    problems: list[str] = []
    notes: list[str] = []

    # 记录归组：base → {language: record}
    groups: dict[str, dict[str, dict]] = {}
    for record in snapshots:
        name = record.get("name") or ""
        split = split_name(name)
        if split is None:
            problems.append(f"{name}：快照名没带语言后缀（-zh / -en）")
            continue
        base, language = split
        if record.get("language") != language:
            problems.append(
                f"{name}：名字说的是 {language}，记录里写的却是 {record.get('language')!r}"
            )
        if "localizedStrings" not in record:
            problems.append(f"{name}：记录里没有 `localizedStrings`（语言没被观测，判据无从下手）")
        bucket = groups.setdefault(base, {})
        if language in bucket:
            problems.append(f"{name}：同一个语言出现了两份（{base} · {language}）")
        bucket[language] = record

    if not groups:
        print("❌ 一条都不成对，判据无从下手")
        for problem in problems:
            print(f"   - {problem}")
        return 1

    # 注册表：条目必须在 manifest 里出现，且理由非空
    for base, reason in exemptions.items():
        if not str(reason).strip():
            problems.append(f"{base}：注册为语言无关却没写理由（理由就是这条判据的可读性）")
        if base not in groups:
            problems.append(f"{base}：注册表里有这个条目，但清单里没有这张图 —— 陈旧条目，请删掉")

    identical_registered: list[str] = []
    for base in sorted(groups):
        bucket = groups[base]
        missing = [language for language in LANGUAGE_SUFFIX.values() if language not in bucket]
        if missing:
            problems.append(f"{base}：缺 {', '.join(missing)} —— 语言覆盖缺了一半")
            continue

        chinese = bucket["zh-Hans"]
        english = bucket["en"]
        missing_files = [
            record["name"]
            for record in (chinese, english)
            if not pathlib.Path(record["file"]).exists()
        ]
        if missing_files:
            # 文件不在时**不接着算像素**：`sha256` 会抛、把真实原因埋进 traceback
            # （负例 ⑧ 就是这么抓出来的 —— 判据不成立时要报出**为什么**）。
            for record in (chinese, english):
                if not pathlib.Path(record["file"]).exists():
                    problems.append(f"{record['name']}：清单指向的 PNG 不在（{record['file']}）")
            continue

        same_pixels = sha256(pathlib.Path(chinese["file"])) == sha256(pathlib.Path(english["file"]))
        texts_differ = sorted(chinese.get("localizedStrings") or []) != sorted(
            english.get("localizedStrings") or []
        )

        if base in exemptions:
            if not same_pixels:
                problems.append(
                    f"{base}：注册为语言无关，但中英两张**已经不一样**了 —— 条目过期，"
                    f"请从 {exemptions_path.name} 里删掉它"
                )
            identical_registered.append(base)
            if texts_differ and not args.quiet:
                notes.append(f"{base}：语言无关，但两遍文案**不同** —— 文案没进像素（只到 .help / 无障碍标签）")
        else:
            if same_pixels:
                problems.append(
                    f"{base}：中英两张 PNG **逐字节相同** ⇒ 语言没到像素上"
                    f"（若确实语言无关，请到 {exemptions_path.name} 注册并写明理由）"
                )
            if not texts_differ and not args.quiet:
                notes.append(f"{base}：两遍观测到的文案相同 —— 它的语言差异不是文案带来的")

    total_pairs = len(groups)
    print(
        f"🌐 语言覆盖：{len(snapshots)} 张 / {total_pairs} 组"
        f"（随语言变化 {total_pairs - len(identical_registered)} 组，"
        f"注册为语言无关 {len(identical_registered)} 组）"
    )
    for base in identical_registered:
        reason = str(exemptions[base]).strip()
        shown = reason if len(reason) <= 64 else reason[:64] + "…"
        print(f"   · 语言无关（已注册）：{base} —— {shown}")
    for note in notes:
        print(f"   · 观测：{note}")

    if problems:
        print(f"\n❌ 语言覆盖门禁未通过（{len(problems)} 项）：")
        for problem in problems:
            print(f"   - {problem}")
        return 1

    print("✅ 语言覆盖门禁通过：成对齐全，且语言确实到了像素上（注册为无关的除外，且它们仍然逐字节相同）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
