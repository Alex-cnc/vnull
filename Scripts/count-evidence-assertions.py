#!/usr/bin/env python3
"""数一个证据脚本输出里的**断言条数**（开发循环 L-05 起的机械计数）。

**为什么要机器数**：文档里写「13 项断言全过」这类话时，脚本后来加了断言、或删掉了几条，
文档不会自己变 —— 于是「账」和「事实」就悄悄脱钩（L-04 查出的 `verify-all.sh` 假绿是同一类病）。

**口径**（改口径要连文档一起改，`Docs/design/待人工验收清单.md` §10.7~§10.10 与本文件一致）：

    断言 = 输出里以 `  ✅ ` 开头的行
           − 每节末尾的「（详见上）」汇总行（那是复述，不是独立断言）
           − 第 0 节（`== 0)` 里的构建 / 起库等前置检查，不是对需求的断言）

用法：

    ./Scripts/count-evidence-assertions.py .build/no-endpoint-evidence/test-mcp.log
    ./Scripts/count-evidence-assertions.py <日志> --json
"""

import argparse
import json
import re
import sys

SECTION_RE = re.compile(r"^\s*==\s*(\d+)\)")
ASSERTION_PREFIX = "  ✅ "

# 第 0 节 = 构建 CLI / 起本机 PostgreSQL 等前置检查，不计入断言
SETUP_SECTION = "0"
# 每节末尾的复述行：把本节几条合成一条「…三项（详见上）」
SUMMARY_MARKER = "（详见上）"


def count(path):
    assertions = 0
    all_ok_lines = 0
    section = None
    by_section = {}
    sections = []
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            match = SECTION_RE.match(line)
            if match:
                section = match.group(1)
                if section not in sections:
                    sections.append(section)
                continue
            if not line.startswith(ASSERTION_PREFIX):
                continue
            all_ok_lines += 1
            if SUMMARY_MARKER in line:
                continue
            if section == SETUP_SECTION:
                continue
            assertions += 1
            key = f"§{section}" if section is not None else "§?"
            by_section[key] = by_section.get(key, 0) + 1
    return {
        "file": path,
        "assertions": assertions,
        "allOkLines": all_ok_lines,
        "sections": sections,
        "bySection": by_section,
        "rule": "✅ 行 −（详见上）汇总行 − 第 0 节前置检查",
    }


def main():
    parser = argparse.ArgumentParser(description="数证据脚本输出里的断言条数")
    parser.add_argument("log")
    parser.add_argument("--json", action="store_true", help="输出 JSON（默认人读）")
    args = parser.parse_args()

    result = count(args.log)
    if args.json:
        print(json.dumps(result, ensure_ascii=False))
        return 0
    print(f"{result['file']}：断言 {result['assertions']} 项（✅ 行合计 {result['allOkLines']}）")
    for key, value in result["bySection"].items():
        print(f"  {key} {value} 项")
    return 0


if __name__ == "__main__":
    sys.exit(main())
