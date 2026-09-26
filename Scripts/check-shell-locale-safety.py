#!/usr/bin/env python3
"""门禁：`Scripts/**/*.sh` 里不得出现「**裸写** `$变量` 后面紧跟非 ASCII 字符」。

**为什么要有这条**（2026-09-26 开发循环 L-05 实测发现）：

本仓库所有 shell 脚本的 Shebang 都是 `#!/bin/bash`，而在 macOS 上那就是 **bash 3.2.57**。
实测（`LC_CTYPE=C.UTF-8`，本机）：

    X=VALUE
    echo "中文：$X）"            →  打印「中文：）」        ← 值被吞掉，`）` 也被切坏
    echo "中文：$X，"            →  打印「中文：，」
    echo "中文：$X中"            →  打印「中文：中」
    echo "中文：${X}）"          →  打印「中文：VALUE）」   ← 花括号安全
    echo "中文：$X ）"           →  打印「中文：VALUE ）」  ← 隔一个空格也安全
    加 `set -u` 后第一行直接 `X?: unbound variable` **中止脚本**

成因：bash 3.2 在多字节字符集下把后一个多字节字符的**首字节**当成了变量名的续接字节
（报错信息里会看到变量名后面粘了一个乱码字节）。

**危险在于它默认不报错**：证据脚本照常 exit 0、照常打勾，只是那一行的值空了 ——
与 L-04 查出的 `verify-all.sh` 假绿同一族：闭环绿着，而证据本身是残的。
所以这条门禁是**机械**的，不靠人记得。

修法：`${X}`（推荐）或让变量后面跟一个 ASCII 字符 / 空格。

已知边界：注释行（`#` 开头）跳过；不做 shell 语法解析，只按「裸写变量名 + 紧跟非 ASCII 字节」判定，
所以不会误报 `${X}`、`$X)`、`$X ）`。

用法：`python3 Scripts/check-shell-locale-safety.py`（在仓库根跑；非零退出 = 有命中）
"""

import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKIP_DIRS = {".build", ".git", "Vendor", "node_modules"}
# 裸写 $name（不是 ${name}）后面紧跟一个非 ASCII 字节 —— 正是 bash 3.2 出事的那一格
BARE_VAR_BEFORE_MULTIBYTE = re.compile(rb"\$(?!\{)([A-Za-z_][A-Za-z0-9_]*)(?=[\x80-\xff])")


def scan(paths):
    hits = []
    for path in paths:
        with open(path, "rb") as handle:
            content = handle.read()
        for number, raw in enumerate(content.split(b"\n"), 1):
            if raw.lstrip().startswith(b"#"):
                continue
            for match in BARE_VAR_BEFORE_MULTIBYTE.finditer(raw):
                hits.append((
                    os.path.relpath(path, ROOT),
                    number,
                    "$" + match.group(1).decode("utf-8", "replace"),
                    raw.decode("utf-8", "replace").strip(),
                ))
    return hits


def main():
    paths = [
        p for p in sorted(glob.glob(os.path.join(ROOT, "**", "*.sh"), recursive=True))
        if not any(f"/{d}/" in p for d in SKIP_DIRS)
    ]
    hits = scan(paths)
    print(f"扫描 {len(paths)} 个 .sh（bash 3.2 多字节变量名坑）")
    if not hits:
        print("✅ 无「裸写 $变量 + 紧跟非 ASCII 字符」—— 证据脚本不会静默丢值")
        return 0
    print(f"❌ 命中 {len(hits)} 处（变量会展开成空，配 set -u 直接报 unbound variable 中止脚本）：")
    for path, number, token, line in hits:
        print(f"  {path}:{number}  [{token}]  {line}")
    print()
    print("修法：改成 ${变量}（花括号），或让变量后面跟一个 ASCII 字符 / 空格。")
    return 1


if __name__ == "__main__":
    sys.exit(main())
