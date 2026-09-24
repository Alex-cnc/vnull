#!/bin/bash
# 工作区代码编辑器的**语言层**可复跑证据（FR-EDIT-36）。
#
# 为什么单独验这一块：着色与补全在界面上只能靠眼睛看，而"哪个词算关键字、哪一段是注释"
# 是可以逐条核对的 —— 这一层错了，界面上的表现是"颜色看着怪"和"补全给不出该给的东西"，
# 而这两件事人工排查很费劲。所以这里用 CLI 对着**语言定义**逐条核。
#
# 用法：./Scripts/test-workspace-editor.sh
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }

echo "== 0) 构建 CLI =="
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
if swift build --disable-sandbox --cache-path "$PWD/.build-cache" --scratch-path "$PWD/.build" \
    --manifest-cache local -Xswiftc -disable-sandbox --product DoyahCLI > /tmp/code-tokens-build.log 2>&1; then
    check "CLI 构建成功" 0
else
    check "CLI 构建成功" 1
    tail -5 /tmp/code-tokens-build.log
    exit 1
fi

echo ""
echo "== 1) 判语言（扩展名 / 文件名 / 认不出）=="
"$CLI" code-tokens --detect index.tsx > /tmp/ct.txt 2>&1
grep -q "typescript" /tmp/ct.txt && check ".tsx → TypeScript" 0 || { cat /tmp/ct.txt; check ".tsx → TypeScript" 1; }
"$CLI" code-tokens --detect "/tmp/项目/查询.SQL" > /tmp/ct.txt 2>&1
grep -q "sql" /tmp/ct.txt && check ".SQL（大写）→ SQL" 0 || { cat /tmp/ct.txt; check ".SQL（大写）→ SQL" 1; }
"$CLI" code-tokens --detect .gitignore > /tmp/ct.txt 2>&1
grep -q "plainText" /tmp/ct.txt && check ".gitignore → 纯文本（认不出就如实回落）" 0 || { cat /tmp/ct.txt; check ".gitignore → 纯文本（认不出就如实回落）" 1; }
"$CLI" code-tokens --detect /Users/me/.zshrc > /tmp/ct.txt 2>&1
grep -q "shell" /tmp/ct.txt && check ".zshrc → Shell（按文件名判）" 0 || { cat /tmp/ct.txt; check ".zshrc → Shell（按文件名判）" 1; }

echo ""
echo "== 2) JavaScript：字符串与注释里的关键字不算关键字 =="
"$CLI" code-tokens --language javascript --text 'const s = "if (x) {}"; // if 注释' > /tmp/ct.txt 2>&1
grep -q $'keyword\tconst' /tmp/ct.txt && check "const 是关键字" 0 || { cat /tmp/ct.txt; check "const 是关键字" 1; }
grep -q $'keyword\tif' /tmp/ct.txt && check "字符串/注释里的 if 不算关键字" 1 || check "字符串/注释里的 if 不算关键字" 0
grep -q $'string\t"if (x) {}"' /tmp/ct.txt && check "整段字符串是一个记号" 0 || { cat /tmp/ct.txt; check "整段字符串是一个记号" 1; }

echo ""
echo "== 3) SQL：大小写不敏感 + 行注释 + 双写引号转义 =="
"$CLI" code-tokens --language sql --text "select 'it''s' -- 注释里的 SELECT" > /tmp/ct.txt 2>&1
grep -qi $'keyword\tselect' /tmp/ct.txt && check "小写 select 也着色" 0 || { cat /tmp/ct.txt; check "小写 select 也着色" 1; }
grep -qF "$(printf 'string\t')'it''s'" /tmp/ct.txt && check "'' 转义后整段是一个字符串" 0 || { cat /tmp/ct.txt; check "'' 转义后整段是一个字符串" 1; }
grep -q $'comment\t-- 注释里的 SELECT' /tmp/ct.txt && check "-- 之后是注释（注释里的 SELECT 不着色）" 0 || { cat /tmp/ct.txt; check "-- 之后是注释（注释里的 SELECT 不着色）" 1; }

echo ""
echo "== 4) HTML / CSS / Python =="
"$CLI" code-tokens --language html --text '<div class="box">text</div>' > /tmp/ct.txt 2>&1
grep -q $'keyword\tdiv' /tmp/ct.txt && grep -q $'builtin\tclass' /tmp/ct.txt \
    && check "HTML：标签与属性分开着色" 0 || { cat /tmp/ct.txt; check "HTML：标签与属性分开着色" 1; }
"$CLI" code-tokens --language css --text '@media screen { display: flex; }' > /tmp/ct.txt 2>&1
grep -q $'keyword\t@media' /tmp/ct.txt && grep -q $'builtin\tdisplay' /tmp/ct.txt \
    && check "CSS：@media 是关键字、属性名是内置" 0 || { cat /tmp/ct.txt; check "CSS：@media 是关键字、属性名是内置" 1; }
"$CLI" code-tokens --language python --text 'def f():
    """文档：这里的 # 不是注释"""
    return 1  # 真注释' > /tmp/ct.txt 2>&1
grep -q $'keyword\treturn' /tmp/ct.txt && grep -q $'comment\t# 真注释' /tmp/ct.txt \
    && check "Python：三引号文档串里的 # 不当注释" 0 || { cat /tmp/ct.txt; check "Python：三引号文档串里的 # 不当注释" 1; }

echo ""
echo "== 5) 补全候选：关键字在前、文档词在后 =="
"$CLI" code-tokens --language javascript --text 'const conA = 1; function conB() {}' --complete con > /tmp/ct.txt 2>&1
grep -q "补全（前缀 con" /tmp/ct.txt && check "给了补全列表" 0 || { cat /tmp/ct.txt; check "给了补全列表" 1; }
grep -q "const" /tmp/ct.txt && check "候选里有 const" 0 || { cat /tmp/ct.txt; check "候选里有 const" 1; }

echo ""
echo "== 6) 纯文本：什么都不着色 =="
"$CLI" code-tokens --language plainText --text 'const x = 1 // 不是代码' > /tmp/ct.txt 2>&1
grep -q "其中着色 0 个" /tmp/ct.txt && check "纯文本零着色" 0 || { cat /tmp/ct.txt; check "纯文本零着色" 1; }

echo ""
if [ "$fail" -eq 0 ]; then
    echo "全部通过：判语言 / 着色 / 补全的语言层都对着语言定义核过了。"
else
    echo "有失败项，见上"
fi
exit "$fail"
