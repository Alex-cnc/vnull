#!/bin/bash
# 验证：只读连接与启动 SQL（FR-CONN-17）。
#
# 只读是**客户端侧保护**：光看配置文件里写着 `isReadOnly: true` 证明不了任何东西，
# 所以这里必须走一遍**真实判定**（CLI `connections --check` 用的就是 App 执行前那条同一个
# `ExecutionSafety`）。注意 `--check` 刻意把 Safe Mode 关掉（`isEnabled: false`）——
# 于是"被拒绝"只可能来自只读标记，而不可能来自高危确认。
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"
DIR="$(mktemp -d -t doyah-readonly)"

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }
cleanup() { rm -rf "$DIR"; }
trap cleanup EXIT

cat > "$DIR/connections.json" <<'JSON'
[
 {"id":"11111111-1111-1111-1111-111111111111","name":"只读巡检库","host":"10.0.0.5","port":5432,
  "database":"inspect","username":"ro","schemaVersion":1,
  "isReadOnly":true,
  "startupSQL":"SET search_path TO public; SET statement_timeout = '5s';"},
 {"id":"22222222-2222-2222-2222-222222222222","name":"可写业务库","host":"10.0.0.6","port":5432,
  "database":"orders","username":"app","schemaVersion":1},
 {"id":"33333333-3333-3333-3333-333333333333","name":"老配置","host":"10.0.0.7",
  "database":"legacy","username":"old","schemaVersion":1}
]
JSON

echo "== 1) 配置读得回来：只读标记与启动 SQL 都在 =="
OUT="$("$CLI" connections --dir "$DIR" 2>&1)"
echo "$OUT" | sed 's/^/  /'
echo "$OUT" | grep -q "只读巡检库.*这是只读连接.*启动 SQL 2 条" && check "只读标记与启动 SQL 条数都在列表里" 0 || check "列表应显示只读与启动 SQL" 1
echo "$OUT" | grep -q "可写业务库.*可写.*启动 SQL 0 条" && check "未标记的连接显示可写" 0 || check "应显示可写" 1
echo "$OUT" | grep -q "老配置.*可写" && check "老配置（无新字段）读出为可写 = 默认值" 0 || check "老配置默认值" 1

echo ""
echo "== 2) 老配置文件不该被凭空改写（schemaVersion 仍是 1，没有新增字段）=="
python3 - "$DIR/connections.json" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
legacy = [item for item in data if item["name"] == "老配置"][0]
assert legacy.get("schemaVersion") == 1, legacy.get("schemaVersion")
assert "isReadOnly" not in legacy and "startupSQL" not in legacy, legacy
print("  ✅ 老配置条目原样保留（没有凭空写入新字段）")
PY
[ $? -eq 0 ] || fail=1

echo ""
echo "== 3) 只读连接：读放行、写拒绝（且拒绝不来自高危确认）=="
"$CLI" connections --dir "$DIR" --check "只读巡检库" --sql "SELECT count(*) FROM jobs" >/dev/null 2>&1
[ $? -eq 0 ] && check "只读连接上 SELECT 放行" 0 || check "SELECT 应放行" 1
"$CLI" connections --dir "$DIR" --check "只读巡检库" --sql "SET search_path TO public" >/dev/null 2>&1
[ $? -eq 0 ] && check "只读连接上 SET（启动 SQL 的常见内容）放行" 0 || check "SET 应放行" 1

REFUSE="$("$CLI" connections --dir "$DIR" --check "只读巡检库" --sql "DROP TABLE jobs" 2>&1)"; CODE=$?
echo "$REFUSE" | sed 's/^/  /'
[ "$CODE" -eq 3 ] && check "只读连接上 DROP 被拒绝（退出码 3）" 0 || check "DROP 应被拒绝" 1
echo "$REFUSE" | grep -q "只读" && check "拒绝理由说明是只读（不是高危确认）" 0 || check "理由应说明只读" 1
echo "$REFUSE" | grep -q "DROP TABLE jobs" && check "点名了违规语句" 0 || check "应点名违规语句" 1

# 各种写语句都要挡住
for sql in "INSERT INTO jobs VALUES (1)" "UPDATE jobs SET a = 1" "DELETE FROM jobs" "TRUNCATE jobs" "CREATE TABLE x (id int)"; do
    "$CLI" connections --dir "$DIR" --check "只读巡检库" --sql "$sql" >/dev/null 2>&1
    [ $? -eq 3 ] || { check "只读应拒绝：$sql" 1; break; }
done
check "五种写语句全部被拒（INSERT/UPDATE/DELETE/TRUNCATE/CREATE）" 0

echo ""
echo "== 4) 对照：可写连接上同样的语句放行（证明拒绝来自只读标记）=="
"$CLI" connections --dir "$DIR" --check "可写业务库" --sql "DROP TABLE jobs" >/dev/null 2>&1
[ $? -eq 0 ] && check "可写连接上 DROP 放行" 0 || check "可写连接不该被拦" 1

echo ""
echo "== 5) 启动 SQL 逐条拆开（一条失败不该吞掉后面）=="
STARTUP="$("$CLI" connections --dir "$DIR" --show-startup "只读巡检库" 2>&1)"
echo "$STARTUP" | sed 's/^/  /'
echo "$STARTUP" | grep -q "启动 SQL 2 条" && check "两条语句被拆开" 0 || check "应拆成 2 条" 1
echo "$STARTUP" | grep -q "SET search_path TO public" && check "第一条内容正确（末尾分号已去掉）" 0 || check "第一条内容" 1
echo "$STARTUP" | grep -q "statement_timeout" && check "第二条内容正确" 0 || check "第二条内容" 1
"$CLI" connections --dir "$DIR" --show-startup "可写业务库" >/dev/null 2>&1
[ $? -eq 1 ] && check "没配启动 SQL 的连接返回非零（不假装有）" 0 || check "空启动 SQL 应返回非零" 1

echo ""
if [ "$fail" -eq 0 ]; then
    echo "通过：只读标记可持久化（老配置默认可写）/ 只读真实拦住五类写语句且理由说明是只读 /"
    echo "      对照可写连接放行 / 启动 SQL 逐条拆开且空配置不假装有"
    echo "（**边界**：只读是客户端保护，不替代数据库权限；界面上的开关与启动 SQL 输入框仍需人工点）"
else
    echo "有失败项，见上"
fi
exit "$fail"
