#!/bin/bash
set -euo pipefail

# XcodeGen 当前版本在生成 XCLocalSwiftPackageReference 后，
# 可能不会给 XCSwiftPackageProductDependency 补上 package 关联。
# 这会导致 Xcode 报：
#   Missing package product 'PostgresNIO'
#
# 这个脚本在 xcodegen generate 之后自动补齐关联。

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PBXPROJ="${PROJECT_ROOT}/DoyahStudio.xcodeproj/project.pbxproj"

python3 - "${PBXPROJ}" <<'PY'
import re
import sys

path = sys.argv[1]
try:
    content = open(path, encoding="utf-8").read()
except FileNotFoundError:
    print(f"patch-xcodeproj: file not found: {path}")
    sys.exit(1)

local_ref_match = re.search(
    r'([A-F0-9]+) /\* XCLocalSwiftPackageReference "Vendor/postgres-nio" \*/ = \{',
    content,
)
if not local_ref_match:
    print("patch-xcodeproj: no local PostgresNIO package reference found")
    sys.exit(0)

package_id = local_ref_match.group(1)

block_pattern = re.compile(
    r'(?P<indent>[ \t]*)(?P<id>[A-F0-9]+) /\* PostgresNIO \*/ = \{\n'
    r'(?P<body>.*?)\n'
    r'(?P=indent)\};',
    re.S,
)

def repl(match: re.Match) -> str:
    body = match.group("body")
    if "package =" in body:
        return match.group(0)

    indent = match.group("indent")
    inner = indent + "\t"
    new_body = "\n".join(
        [
            f"{inner}isa = XCSwiftPackageProductDependency;",
            f'{inner}package = {package_id} /* XCLocalSwiftPackageReference "Vendor/postgres-nio" */;',
            f"{inner}productName = PostgresNIO;",
        ]
    )
    return f'{indent}{match.group("id")} /* PostgresNIO */ = {{\n{new_body}\n{indent}}};'

updated, count = block_pattern.subn(repl, content, count=1)
if count == 0:
    print("patch-xcodeproj: no PostgresNIO product dependency found")
    sys.exit(0)

if updated != content:
    open(path, "w", encoding="utf-8").write(updated)
    print(f"patch-xcodeproj: linked PostgresNIO product -> {package_id}")
else:
    print("patch-xcodeproj: PostgresNIO already linked")
PY
