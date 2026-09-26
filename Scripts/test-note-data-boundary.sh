#!/bin/bash
# 笔记数据边界（FR-PLUG-04）的可复跑证据。
#
# 为什么单独验这一块：**位置错了不会报错，只会慢慢丢东西** ——
# 宿主的清理 / 迁移顺手带走用户的笔记，或者笔记的搬运动到宿主的连接凭据与审计日志。
# 所以这里把三件事逐条钉住：① 默认位置在工程数据家之外；② 一次性迁移搬的是字节、旧文件留备份；
# ③ 出岔子时（坏文件 / 写不进去 / 目标已有）**绝不覆盖、如实报**。
#
# 用法：./Scripts/test-note-data-boundary.sh
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }

echo "== 0) 构建 CLI =="
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
if swift build --disable-sandbox --cache-path "$PWD/.build-cache" --scratch-path "$PWD/.build" \
    --manifest-cache local -Xswiftc -disable-sandbox --product DoyahCLI > /tmp/note-boundary-build.log 2>&1; then
    check "CLI 构建成功" 0
else
    check "CLI 构建成功" 1
    tail -15 /tmp/note-boundary-build.log
    exit 1
fi

echo ""
echo "== 1) 默认位置：在工程数据家之外 =="
"$CLI" notes path > "$WORK/path.txt" 2>&1
NOTES_PATH="$(cat "$WORK/path.txt")"
echo "     笔记库：$NOTES_PATH"
case "$NOTES_PATH" in
    */DoyahNotes/notes.json) check "落在 DoyahNotes 目录下的 notes.json" 0 ;;
    *) check "落在 DoyahNotes 目录下的 notes.json（实际 ${NOTES_PATH}）" 1 ;;
esac
case "$NOTES_PATH" in
    */DoyahStudio/*) check "不在工程数据家（DoyahStudio）里" 1 ;;
    *) check "不在工程数据家（DoyahStudio）里" 0 ;;
esac
"$CLI" notes legacy-path > "$WORK/legacy-path.txt" 2>&1
LEGACY_PATH="$(cat "$WORK/legacy-path.txt")"
echo "     旧位置：$LEGACY_PATH"
case "$LEGACY_PATH" in
    */DoyahStudio/notes.json) check "旧位置仍在工程数据家里（迁移的起点）" 0 ;;
    *) check "旧位置仍在工程数据家里（迁移的起点，实际 ${LEGACY_PATH}）" 1 ;;
esac
[ "$NOTES_PATH" != "$LEGACY_PATH" ] && check "新旧位置不同" 0 || check "新旧位置不同" 1

echo ""
echo "== 2) 迁移：搬字节、留备份、原处不留笔记 =="
mkdir -p "$WORK/legacy" "$WORK/home"
python3 - "$WORK/legacy/notes.json" <<'PY'
import json, sys
notes = [
    {"id": "AD1D86B3-5667-41E4-AB63-16258B9C3C79", "title": "第一条", "body": "SELECT 1",
     "tags": ["pg"], "containsRowData": False,
     "source": {"kind": "manual", "capturedAt": "2026-09-25T13:16:11Z"},
     "createdAt": "2026-09-25T13:16:11Z", "updatedAt": "2026-09-25T13:16:55Z"},
    {"id": "B2E4A1C0-1111-2222-3333-444455556666", "title": "第二条", "body": "SELECT 2",
     "tags": [], "containsRowData": False,
     "source": {"kind": "sql", "connectionName": "本地", "capturedAt": "2026-09-25T14:00:00Z"},
     "createdAt": "2026-09-25T14:00:00Z", "updatedAt": "2026-09-25T14:00:00Z"}
]
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(notes, handle, ensure_ascii=False, indent=2, sort_keys=True)
PY
cp "$WORK/legacy/notes.json" "$WORK/legacy-before.json"

"$CLI" notes migrate --legacy "$WORK/legacy/notes.json" --target "$WORK/home" --json > "$WORK/migrate.json" 2>&1
echo "     输出：$(cat "$WORK/migrate.json")"
grep -q '"outcome":"migrated"' "$WORK/migrate.json" && check "outcome=migrated" 0 || check "outcome=migrated" 1
grep -q '"noteCount":2' "$WORK/migrate.json" && check "搬走 2 条" 0 || check "搬走 2 条" 1
grep -q '"backup":"'"$WORK"'/home/notes.json.migrated"' "$WORK/migrate.json" && check "备份落在笔记数据家里" 0 || check "备份落在笔记数据家里" 1
cmp -s "$WORK/home/notes.json" "$WORK/legacy-before.json" && check "新库与原文件**逐字节一致**" 0 || check "新库与原文件**逐字节一致**" 1
cmp -s "$WORK/home/notes.json.migrated" "$WORK/legacy-before.json" && check "备份内容 = 原文件（不删、只改名）" 0 || check "备份内容 = 原文件（不删、只改名）" 1
[ ! -f "$WORK/legacy/notes.json" ] && check "工程数据家那一侧不再留笔记文件" 0 || check "工程数据家那一侧不再留笔记文件" 1

echo ""
echo "== 3) 幂等：再跑一次不许覆盖 =="
cp "$WORK/home/notes.json" "$WORK/home-before.json"
"$CLI" notes migrate --legacy "$WORK/legacy/notes.json" --target "$WORK/home" --json > "$WORK/migrate2.json" 2>&1
echo "     输出：$(cat "$WORK/migrate2.json")"
grep -q '"outcome":"nothingToMigrate"' "$WORK/migrate2.json" && check "旧文件已不在 → nothingToMigrate" 0 || check "旧文件已不在 → nothingToMigrate" 1
cmp -s "$WORK/home/notes.json" "$WORK/home-before.json" && check "目标文件未被改动" 0 || check "目标文件未被改动" 1

# 目标已有内容 + 旧文件还在（老 App 又写回来的情形）：必须报 skippedTargetExists，且两边都不动。
python3 - "$WORK/legacy/notes.json" <<'PY'
import sys
open(sys.argv[1], "w", encoding="utf-8").write('[{"id":"C0000000-0000-0000-0000-000000000000","title":"旧 App 又写的","body":"","tags":[],"containsRowData":false,"source":{"kind":"manual","capturedAt":"2026-09-25T15:00:00Z"},"createdAt":"2026-09-25T15:00:00Z","updatedAt":"2026-09-25T15:00:00Z"}]')
PY
cp "$WORK/legacy/notes.json" "$WORK/legacy-second.json"
"$CLI" notes migrate --legacy "$WORK/legacy/notes.json" --target "$WORK/home" --json > "$WORK/migrate3.json" 2>&1
grep -q '"outcome":"skippedTargetExists"' "$WORK/migrate3.json" && check "目标已存在 → skippedTargetExists" 0 || check "目标已存在 → skippedTargetExists" 1
cmp -s "$WORK/home/notes.json" "$WORK/home-before.json" && check "目标文件仍未被改动（绝不用新的覆盖旧的）" 0 || check "目标文件仍未被改动（绝不用新的覆盖旧的）" 1
cmp -s "$WORK/legacy/notes.json" "$WORK/legacy-second.json" && check "旧文件也原样保留" 0 || check "旧文件也原样保留" 1
rm -f "$WORK/legacy/notes.json"

echo ""
echo "== 4) 坏文件：原地保留、目标不建、退出码 1 =="
printf '{ 这不是 JSON' > "$WORK/legacy/notes.json"
cp "$WORK/legacy/notes.json" "$WORK/corrupt-before.json"
rm -rf "$WORK/broken-home"
"$CLI" notes migrate --legacy "$WORK/legacy/notes.json" --target "$WORK/broken-home" --json > "$WORK/migrate4.json" 2>&1
code=$?
echo "     输出：$(cat "$WORK/migrate4.json")（退出码 ${code}）"
grep -q '"outcome":"legacyUnreadable"' "$WORK/migrate4.json" && check "outcome=legacyUnreadable" 0 || check "outcome=legacyUnreadable" 1
[ "$code" -eq 1 ] && check "退出码 1（需要人看一眼）" 0 || check "退出码 1（需要人看一眼）" 1
cmp -s "$WORK/legacy/notes.json" "$WORK/corrupt-before.json" && check "坏文件原样保留（不删、不改）" 0 || check "坏文件原样保留（不删、不改）" 1
[ ! -e "$WORK/broken-home/notes.json" ] && check "新位置没有被造出一个空库" 0 || check "新位置没有被造出一个空库" 1
rm -f "$WORK/legacy/notes.json"

echo ""
echo "== 5) 没有旧文件：什么都不做 =="
"$CLI" notes migrate --legacy "$WORK/legacy/notes.json" --target "$WORK/fresh-home" --json > "$WORK/migrate5.json" 2>&1
grep -q '"outcome":"nothingToMigrate"' "$WORK/migrate5.json" && check "outcome=nothingToMigrate" 0 || check "outcome=nothingToMigrate" 1
[ ! -e "$WORK/fresh-home" ] && check "没有凭空造目录" 0 || check "没有凭空造目录" 1

echo ""
echo "== 6) 生效的 DOYAH_NOTES_DIR 覆盖：迁移主动让路 =="
DOYAH_NOTES_DIR="$WORK/override-home" "$CLI" notes path > "$WORK/path2.txt" 2>&1
[ "$(cat "$WORK/path2.txt")" = "$WORK/override-home/notes.json" ] && check "覆盖生效：路径跟着环境变量走" 0 \
    || check "覆盖生效：路径跟着环境变量走（实际 $(cat "${WORK}/path2.txt")）" 1

echo ""
if [ "$fail" -eq 0 ]; then
    echo "✅ 笔记数据边界（FR-PLUG-04）：全部断言通过"
else
    echo "❌ 有断言未通过"
fi
exit "$fail"
