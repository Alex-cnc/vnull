#!/bin/bash
# 验证：查询记忆层（FR-AI-13）。
#
# 事实源是**归档 .sql 文件**，所以这里直接用真归档文件建索引：
# 用 CLI 自己的归档格式写出多天 / 多连接的记录，再核对
# 聚类、频次、跨天、**按连接隔离**、以及"删掉索引重建结果一致"（纯派生缓存）。
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"
DIR="$(mktemp -d -t doyah-memory)"

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }
cleanup() { rm -rf "$DIR"; }
trap cleanup EXIT

# **用产品自己的归档写入器**产出归档（`archive-add`）。
# 为什么不用手编格式：本脚本第一版就是手写的元信息注释，结果 `SQLArchive.parse` 解析出 0 条 ——
# 验的是"我以为的格式"，不是产品格式。用写入器产出，验的才是产品。
archive_add() {
    "$CLI" archive-add --dir "$DIR" --sql "$1" --connection "$2" --runs "$3" --at "$4" >/dev/null
}

echo "== 1) 造现场：两天、两个连接、重复与非重复查询 =="
archive_add "SELECT count(*) FROM orders WHERE status = 'paid'" 生产库 12 2026-09-21T09:00:00Z
archive_add "SELECT count(*) FROM orders WHERE status = 'refunded'" 生产库 2 2026-09-21T10:00:00Z
archive_add "SELECT * FROM customers" 测试库 40 2026-09-21T11:00:00Z
archive_add "SELECT count(*) FROM orders WHERE status = 'paid'" 生产库 5 2026-09-22T09:00:00Z
ls "$DIR" | sed 's/^/  /'
check "归档文件已用产品格式生成" $([ "$(ls "$DIR" | wc -l | tr -d ' ')" = "2" ] && echo 0 || echo 1)

echo ""
echo "== 2) 建索引：聚类（同一骨架合成一条）、频次累加、跨天 =="
OUT="$("$CLI" memory --dir "$DIR" 2>&1)"
echo "$OUT" | head -10 | sed 's/^/  /'
# 4 条记录 → **2 条**记忆：两条 count 语句同骨架（status 只是字面量不同）合成一条，customers 一条。
# 我第一版写"3 条"，是把 paid 与 refunded 当成了不同骨架 —— 期望算错，产品是对的。
echo "$OUT" | grep -q "从 4 条归档记录派生出 2 条记忆" && check "4 条记录 → 2 条记忆（两条 count 同骨架合并）" 0 \
    || { check "聚类结果" 1; echo "$OUT" | head -3; }
# 频次 = paid 12 + refunded 2 + paid 5 = **19**（我第一版漏了 refunded 的 2）。
echo "$OUT" | grep -q "19 次" && check "频次累加（12+2+5=19）" 0 || { check "频次累加（期望 19 次）" 1; echo "$OUT" | grep "次 ·" | head -3; }

echo ""
echo "== 3) 补全：前缀命中排前，并按连接隔离 =="
SUG="$("$CLI" memory --dir "$DIR" --prefix "SELECT count" --connection 生产库 2>&1)"
echo "$SUG" | head -6 | sed 's/^/  /'
echo "$SUG" | grep -q "补全候选" && check "给出补全候选" 0 || check "补全候选" 1
echo "$SUG" | grep -q "orders" && check "命中生产库的 count 查询" 0 || check "命中" 1
echo "$SUG" | grep -q "customers" && check "不该出现测试库的记忆（按连接隔离）" 1 || check "按连接隔离生效" 0

echo ""
echo "== 4) 同前摆在测试库连接下：应当看到 customers 而不是 orders =="
STAGING="$("$CLI" memory --dir "$DIR" --prefix "SELECT" --connection 测试库 2>&1)"
echo "$STAGING" | head -5 | sed 's/^/  /'
echo "$STAGING" | grep -q "customers" && check "测试库连接下命中 customers" 0 || check "测试库命中" 1
echo "$STAGING" | grep -q "count(\\*)" && check "生产库的 count 记忆不该流进测试库" 1 || check "隔离方向也对" 0

echo ""
echo "== 5) 纯派生缓存：重建结果一致、没有隐藏状态 =="
FIRST="$("$CLI" memory --dir "$DIR" 2>&1)"
SECOND="$("$CLI" memory --dir "$DIR" 2>&1)"
[ "$FIRST" = "$SECOND" ] && check "同一目录重建两次结果完全一致" 0 || check "重建应一致" 1
# 复制一份归档到新目录 → 索引应当等价（说明索引不依赖任何隐藏状态 / 缓存文件）
COPY="$(mktemp -d -t doyah-memory-copy)"
cp "$DIR"/*.sql "$COPY"/
THIRD="$("$CLI" memory --dir "$COPY" 2>&1 | sed "s|$COPY|$DIR|g")"
[ "$FIRST" = "$THIRD" ] && check "只带归档文件搬到新目录，索引等价（事实源是文件）" 0 \
    || { check "搬目录后索引应等价" 1; diff <(echo "$FIRST") <(echo "$THIRD") | head -5; }
rm -rf "$COPY"

echo ""
echo "== 6) 健壮性：坏文件跳过并报告，好文件照常建索引 =="
echo "这不是归档文件" > "$DIR/garbage.sql"
ROBUST="$("$CLI" memory --dir "$DIR" 2>&1)"
echo "$ROBUST" | head -3 | sed 's/^/  /'
echo "$ROBUST" | grep -q "跳过" && check "坏文件被跳过且报告出来（不静默）" 0 || check "跳过报告" 1
echo "$ROBUST" | grep -q "派生出 2 条记忆" && check "好文件仍然建出索引" 0 || check "好文件" 1

echo ""
echo "== 7) JSON 出口（脚本可断言）=="
JSON_OUT="$("$CLI" memory --dir "$DIR" --prefix "SELECT count" --connection 生产库 --json 2>&1)"
python3 - "$JSON_OUT" <<'PY'
import json, sys
text = sys.argv[1]
# JSON 模式前面仍有"从 N 条归档记录…"这类信息行 —— 只取最后一段 JSON 数组
start = text.index("[")
payload = json.loads(text[start:])
assert payload, payload
assert "orders" in payload[0]["sql"]
assert payload[0]["runs"] == 19, payload[0]   # 12 + 2 + 5
print("  ✅ JSON 可解析、字段稳定、次数正确（12+2+5=19）")
PY
[ $? -eq 0 ] || fail=1

echo ""
if [ "$fail" -eq 0 ]; then
    echo "通过：记忆层聚类 / 频次 / 跨天 / 连接隔离 / 纯派生缓存（搬目录等价）/ 坏文件容错都成立"
else
    echo "有失败项，见上"
fi
exit "$fail"
