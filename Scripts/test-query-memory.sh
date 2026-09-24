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
# 验收标准⑤：记忆出口的键**只有** sql/score/runs —— 结构上就没有承载结果集行数据的地方
assert all(set(item) == {"sql", "score", "runs"} for item in payload), payload
assert "orders" in payload[0]["sql"]
assert payload[0]["runs"] == 19, payload[0]   # 12 + 2 + 5
print("  ✅ JSON 可解析、字段稳定、次数正确（12+2+5=19）")
PY
[ $? -eq 0 ] || fail=1

echo ""
echo "== 8) 编辑器补全链路（S4）：关键字在前、空前缀不刷屏、长句不灌光标 =="
# 这一节核对的是**编辑器里实际会看到的候选**（`--completion` 与 UI 走同一个 QueryCompletion）。
LONG_SQL="SELECT '$(python3 -c 'print("a" * 600, end="")')' AS big"
archive_add "$LONG_SQL" 长句库 3 2026-09-22T12:00:00Z

COMPLETION_FILE="$DIR/completion.txt"
"$CLI" memory --dir "$DIR" --prefix "sel" --connection 生产库 --completion >"$COMPLETION_FILE" 2>&1
head -8 "$COMPLETION_FILE" | sed 's/^/  /'
python3 - "$COMPLETION_FILE" <<'PY'
import re, sys
lines = [l for l in open(sys.argv[1], encoding="utf-8").read().splitlines()
         if re.match(r"\s+\d+\. \[", l)]
assert lines, "没有任何候选"
sources = [re.search(r"\[(关键字|记忆)\]", l).group(1) for l in lines]
assert len(lines) <= 20, "候选超过上限：%d" % len(lines)
# 关键字必须**全部排在**记忆之前：记忆不许顶掉、也不许插队
first_memory = sources.index("记忆") if "记忆" in sources else len(sources)
assert all(s == "关键字" for s in sources[:first_memory]), sources
assert "记忆" in sources, "该前缀下应出现生产库记忆：%s" % sources
print("  ✅ %d 条候选：%d 个关键字在前、%d 条记忆在后（上限 20）"
      % (len(lines), sources.count("关键字"), sources.count("记忆")))
PY
[ $? -eq 0 ] || fail=1

# 空前缀：只给关键字，不给记忆（打开补全先看到 SELECT，不是历史）
"$CLI" memory --dir "$DIR" --prefix "" --completion >"$DIR/empty.txt" 2>&1
# 前提：确实出了候选 —— 否则"没有记忆"可能只是因为它整个没跑起来（假通过）
grep -q "编辑器补全" "$DIR/empty.txt" && grep -q "\[关键字\]" "$DIR/empty.txt" && EMPTY_RAN=0 || EMPTY_RAN=1
check "空前缀确实给出了关键字候选（否定式断言的前提）" "$EMPTY_RAN"
grep -q "\[记忆\]" "$DIR/empty.txt" && check "空前缀不该出现记忆（不刷屏）" 1 || check "空前缀只给关键字" 0
# 候选上限在真实路径上也成立：空前缀恰好给满 20 条关键字
EMPTY_COUNT="$(grep -cE "^ +[0-9]+\. \[" "$DIR/empty.txt" || true)"
[ "$EMPTY_COUNT" = "20" ] && check "候选上限生效（空前缀 $EMPTY_COUNT 条关键字）" 0 \
    || check "候选上限（期望 20 条，实际 $EMPTY_COUNT）" 1

# 超长 SQL（600 字符）不入补全：补全是替换光标处的半个词，不是往光标里灌报表
"$CLI" memory --dir "$DIR" --prefix "SELECT '" --completion --connection 长句库 >"$DIR/long.txt" 2>&1
LONG_RAN=0
grep -q "编辑器补全" "$DIR/long.txt" || LONG_RAN=1
grep -q "\[记忆\]" "$DIR/long.txt" && check "超长 SQL 不该进补全" 1 || check "超长 SQL 被挡在补全外" 0
[ "$LONG_RAN" -eq 0 ] || check "长句库那条补全确实跑过（前提）" 1
# 但它照样是一条记忆（只是不参与补全）—— 别把"不补全"误做成"丢掉"
"$CLI" memory --dir "$DIR" --prefix "SELECT '" --connection 长句库 >"$DIR/longmem.txt" 2>&1
grep -q "big" "$DIR/longmem.txt" && check "超长 SQL 仍作为记忆存在（只是不补全）" 0 || check "超长记忆仍在" 1

# 越界检查：补齐策略不能把连接隔离搞丢（补全链路上再验一次）
"$CLI" memory --dir "$DIR" --prefix "select" --completion --connection 测试库 >"$DIR/staging.txt" 2>&1
grep -q "orders" "$DIR/staging.txt" && check "补全也必须按连接隔离" 1 || check "补全链路上连接隔离仍生效" 0

echo ""
echo "== 9) 补全的 JSON 出口（脚本可断言来源）=="
"$CLI" memory --dir "$DIR" --prefix "sel" --connection 生产库 --completion --json >"$DIR/cjson.txt" 2>&1
python3 - "$DIR/cjson.txt" <<'PY'
import json, sys
text = open(sys.argv[1], encoding="utf-8").read()
payload = json.loads(text[text.index("["):])
assert payload, payload
assert all(set(item) == {"text", "source"} for item in payload), payload
sources = [item["source"] for item in payload]
assert "memory" in sources, sources
print("  ✅ 补全 JSON 可解析、来源字段稳定（dialect %d / memory %d）"
      % (sources.count("dialect"), sources.count("memory")))
PY
[ $? -eq 0 ] || fail=1

echo ""
echo "== 10) 骨架保真回归：表名里的数字不是参数（2026-09-23 实测抓到的真缺陷）=="
# 旧实现逐字符扫描，把 orders1 / orders2 / orders3 都归一成 `orders?`，
# 三条不同表的记忆被并成一条（6 次、3 变体），补全会张冠李戴。
# **这个现场当初没有** —— 所以 16 项单测与第 1~9 节全过了，缺陷却还在。
DIGIT_DIR="$(mktemp -d -t doyah-memory-digits)"
for n in 1 2 3; do
    "$CLI" archive-add --dir "$DIGIT_DIR" --sql "SELECT * FROM orders$n WHERE id = 1" \
        --connection 生产库 --runs 2 --at "2026-09-21T0$n:00:00Z" >/dev/null
done
DIGIT_OUT="$("$CLI" memory --dir "$DIGIT_DIR" 2>&1)"
echo "$DIGIT_OUT" | sed 's/^/  /'
echo "$DIGIT_OUT" | grep -q "派生出 3 条记忆" && check "三张只有数字不同的表 → 三条记忆（不被误合并）" 0 \
    || { check "表名里的数字被误当参数（会张冠李戴）" 1; echo "$DIGIT_OUT" | head -4; }
echo "$DIGIT_OUT" | grep -q "orders1" && echo "$DIGIT_OUT" | grep -q "orders2" && echo "$DIGIT_OUT" | grep -q "orders3" \
    && check "三条骨架各自保留了真实表名" 0 || check "骨架应保留表名里的数字" 1
# 频次不能被合并成 6：每条应为 2 次
[ "$(echo "$DIGIT_OUT" | grep -c "2 次")" = "3" ] && check "频次按表分别累计（各 2 次，不是合并的 6 次）" 0 \
    || check "频次累计" 1
rm -rf "$DIGIT_DIR"

echo ""
if [ "$fail" -eq 0 ]; then
    echo "通过：记忆层聚类 / 频次 / 跨天 / 连接隔离 / 纯派生缓存（搬目录等价）/ 坏文件容错 / 补全合并策略都成立"
else
    echo "有失败项，见上"
fi
exit "$fail"
