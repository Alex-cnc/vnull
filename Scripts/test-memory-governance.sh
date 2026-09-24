#!/bin/bash
# 验证：记忆治理（FR-AI-15）。
#
# 四条验收各自的落点：
#   ① 「一年只用一次但很关键」的巡检脚本**不会被按天数清掉** → 钉住类的判定必须永不遗忘
#   ② 删除 / 清空**立即生效且可验证** → 删完重建索引，那条记忆确实不在
#   ③ 每条记忆都能回答「为什么记了它 / 为什么它被忘了」 → `--show` 的理由必须带实际数字
#   ④ 通用层提升**不得携带具体库表名与数据值** → 脱敏闸
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }
DIR="$(mktemp -d -t doyah-governance)"
cleanup() { rm -rf "$DIR"; }
trap cleanup EXIT

OLD_AT="$(python3 -c 'import datetime; print((datetime.datetime(2026,9,23) - datetime.timedelta(days=400)).strftime("%Y-%m-%dT09:00:00Z"))')"
NEW_AT="2026-09-23T09:00:00Z"

"$CLI" archive-add --dir "$DIR" --sql "SELECT count(*) FROM inspect_jobs WHERE state = 'stale'" --connection 生产库 --runs 1 --at "$OLD_AT" >/dev/null
"$CLI" archive-add --dir "$DIR" --sql "SELECT * FROM orders WHERE id = 7" --connection 生产库 --runs 4 --at "$NEW_AT" >/dev/null

# 指纹一律从 **JSON 出口**取，不去解析人类可读文本：
# 上一版按缩进数"猜"指纹，第一次跑就全错（缩进是 5/6 空格，我按 4/8 取）——
# 脚本解析给人看的文本是错的做法（这条教训在 FR-AI-14 的脚本里也记过一次）。
fingerprint_of() { # fingerprint_of <SQL 子串>
    "$CLI" memory --dir "$DIR" --json 2>/dev/null | python3 -c '
import json, sys
text = sys.stdin.read()
payload = json.loads(text[text.index("["):])
needle = sys.argv[1]
for item in payload:
    if needle in item["sql"]:
        print(item["fingerprint"])
        break
' "$1"
}

INSPECT_FP="$(fingerprint_of inspect_jobs)"
ORDERS_FP="$(fingerprint_of orders)"
echo "  巡检脚本指纹：$INSPECT_FP"
echo "  订单脚本指纹：$ORDERS_FP"
[ -n "$INSPECT_FP" ] && [ -n "$ORDERS_FP" ] && check "两条记忆都已建立（前提）" 0 || check "应建立两条记忆" 1

echo ""
echo "== ① 一年只用一次的关键脚本：钉住类永不被时间清掉 =="
SHOW="$("$CLI" memory --dir "$DIR" --show "$INSPECT_FP" --kind pinned 2>&1)"
echo "$SHOW" | sed 's/^/  /'
echo "$SHOW" | grep -q "为什么记了它" && check "给出「为什么记了它」" 0 || check "应给出理由" 1
echo "$SHOW" | grep -qE "已闲置 (3[0-9]{2}|4[0-9]{2}|[5-9][0-9]{2}) 天" && check "理由里带实际闲置天数" 0 || { check "理由应含实际天数" 1; echo "$SHOW" | tail -2; }
echo "$SHOW" | grep -q "不按天数清理" && check "钉住类明确「不按天数清理」" 0 || check "钉住类不该按天数清理" 1
# 排障类在同样年龄 + 低使用下**应该**被遗忘（对照，证明这条判据真的在起作用）
DROP="$("$CLI" memory --dir "$DIR" --show "$INSPECT_FP" --kind troubleshooting 2>&1)"
echo "$DROP" | grep -q "为什么它被忘了" && check "对照：同类记忆按排障类判定会被遗忘（判据确实在起作用）" 0 || { check "排障类应可遗忘" 1; echo "$DROP" | tail -2; }

echo ""
echo "== ③ 每条记忆都能解释来路 =="
echo "$SHOW" | grep -q "生产库" && check "来源里有连接名（环境层按连接隔离的依据）" 0 || check "来源应含连接名" 1
echo "$SHOW" | grep -q "累计执行 1 次" && check "理由里带实际执行次数" 0 || check "理由应含实际次数" 1
S1="$("$CLI" memory --dir "$DIR" --show "$INSPECT_FP" 2>&1)"
S2="$("$CLI" memory --dir "$DIR" --show "$INSPECT_FP" 2>&1)"
[ "$S1" = "$S2" ] && check "两次 --show 输出一致（可复核）" 0 || check "输出应确定" 1

echo ""
echo "== ② 删除立即生效：重建索引后不再出现 =="
BEFORE="$("$CLI" memory --dir "$DIR" 2>&1 | grep -c '^      ' || true)"
"$CLI" memory --dir "$DIR" --delete "$ORDERS_FP" 2>&1 | sed 's/^/  /'
AFTER="$("$CLI" memory --dir "$DIR" 2>&1)"
REMAINING="$("$CLI" memory --dir "$DIR" --json 2>/dev/null | python3 -c '
import json, sys
text = sys.stdin.read()
payload = json.loads(text[text.index("["):])
print(len(payload))
')"
[ "$REMAINING" = "1" ] && check "删除后重建索引：2 条 → 1 条" 0 || { check "删除应即时生效（实际 $REMAINING 条）" 1; echo "$AFTER" | head -3; }
echo "$AFTER" | grep -q "orders" && check "被删的那条不该再出现" 1 || check "被删的那条已不在索引里" 0

# 不存在的指纹：不该假装成功
"$CLI" memory --dir "$DIR" --delete "select * from nothing where id = ?" >/dev/null 2>&1
[ $? -ne 0 ] && check "删除不存在的指纹返回非零（不假装成功）" 0 || check "不存在的指纹应返回非零" 1

echo ""
echo "== ② 清空：不给 --yes 必须拒绝，且归档毫发无损 =="
FILES_BEFORE="$(ls "$DIR" | sort)"
REFUSE="$("$CLI" memory --dir "$DIR" --clear 2>&1)"; CODE=$?
echo "$REFUSE" | sed 's/^/  /'
[ "$CODE" -eq 64 ] && check "无 --yes 时退出码 64（拒绝执行）" 0 || check "应拒绝执行" 1
[ "$FILES_BEFORE" = "$(ls "$DIR" | sort)" ] && check "被拒绝时归档一个字节都没动" 0 || check "被拒绝时不该改动归档" 1

"$CLI" memory --dir "$DIR" --clear --yes 2>&1 | sed 's/^/  /'
CLEARED="$("$CLI" memory --dir "$DIR" --json 2>/dev/null | python3 -c '
import json, sys
text = sys.stdin.read()
start = text.find("[")
print("0" if start < 0 else len(json.loads(text[start:])))
')"
[ "$CLEARED" = "0" ] && check "确认后整层清空（0 条记忆）" 0 || { check "清空应彻底（实际 $CLEARED 条）" 1; }
[ -z "$(ls "$DIR" 2>/dev/null)" ] && check "清空后不留下空文件" 0 || check "不该留下空文件" 1

echo ""
echo "== ④ 通用层提升：脱敏闸（不得带库表名与数据值）=="
DIR2="$(mktemp -d -t doyah-governance-2)"
"$CLI" archive-add --dir "$DIR2" --sql "SELECT count(*) FROM orders WHERE status = 'paid'" --connection 生产库 --runs 3 --at "$NEW_AT" >/dev/null
FP2="$("$CLI" memory --dir "$DIR2" --json 2>/dev/null | python3 -c '
import json, sys
text = sys.stdin.read()
print(json.loads(text[text.index("["):])[0]["fingerprint"])
')"
PROMOTE="$("$CLI" memory --dir "$DIR2" --promote "$FP2" 2>&1)"
echo "$PROMOTE" | sed 's/^/  /'
echo "$PROMOTE" | grep -q "‹标识符›" && check "标识符被替换成占位符" 0 || check "应替换标识符" 1
echo "$PROMOTE" | grep -q "orders" && check "通用写法里不许留下表名" 1 || check "通用写法里没有表名" 0
echo "$PROMOTE" | grep -q "paid" && check "通用写法里不许留下数据值" 1 || check "通用写法里没有数据值" 0
echo "$PROMOTE" | grep -q "脱敏闸：通过" && check "脱敏闸判定通过" 0 || check "脱敏闸应通过" 1
rm -rf "$DIR2"

echo ""
if [ "$fail" -eq 0 ]; then
    echo "通过：钉住类不按天数清理 / 排障类判据在起作用 / 每条记忆可解释 / 删除即时生效 / 清空需确认且不误伤 / 通用层提升过脱敏闸"
else
    echo "有失败项，见上"
fi
exit "$fail"
