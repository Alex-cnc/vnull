#!/bin/bash
# 验证：外键引用导航（FR-DATA-06）。
#
# 需求点名的验收是"**有外键元数据时才呈现入口；没有目标就不显示**"，
# 所以这里既验"两个方向都能找到目标"，也验"没有外键时确实没有入口"，
# 并且**把生成的跳转语句真的跑一遍**看它是否命中那一行。
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"
# 连接信息（本机过渡集群 / 远程专用库）由共用入口决定 —— 三档端口与目录只写在它里面
source "$(cd "$(dirname "$0")" && pwd)/lib/test-env.sh"
doyah_test_env_summary

PGBIN="${DOYAH_TEST_PG_BIN}"
DATADIR="${DOYAH_TEST_LOCAL_DATADIR}"
PORT="${DOYAH_TEST_PGPORT}"
DB="doyah_fk_nav"
STARTED=0

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }
cleanup() { [ "$STARTED" = "1" ] && "$PGBIN/pg_ctl" -D "$DATADIR" stop >/dev/null 2>&1; }
trap cleanup EXIT
scalar() {
    PGDATABASE="$DB" "$CLI" -c "$1" 2>/dev/null | awk '
        /^--- statement 1 ---/ { seen = 1; next }
        seen && /^finished:/ { exit }
        seen { if (header == "") { header = $0 } else { print $0; exit } }'
}

echo "== 0) 起实例，造父子表与外键 =="
if [ ! -f "${DATADIR}/PG_VERSION" ]; then
    mkdir -p "$DATADIR"
    "$PGBIN/initdb" -D "$DATADIR" -U postgres --auth=trust -E UTF8 >/dev/null 2>&1
fi
if ! "$PGBIN/pg_ctl" -D "$DATADIR" status >/dev/null 2>&1; then
    "$PGBIN/pg_ctl" -D "$DATADIR" -o "-p ${PORT} -k /tmp" -l /tmp/doyah-fk-pg.log start >/dev/null 2>&1
    STARTED=1
    sleep 2
fi
doyah_test_env_export_connection
PGDATABASE="${DOYAH_TEST_ADMIN_DB}" "$CLI" -c "DROP DATABASE IF EXISTS ${DB} WITH (FORCE);" >/dev/null 2>&1
PGDATABASE="${DOYAH_TEST_ADMIN_DB}" "$CLI" -c "CREATE DATABASE ${DB};" >/dev/null 2>&1
PGDATABASE="$DB" "$CLI" -c "
CREATE TABLE customers (id integer primary key, name text);
CREATE TABLE orders (id integer primary key, customer_id integer references customers(id), note text);
CREATE TABLE logs (id integer primary key, message text);
INSERT INTO customers VALUES (1, 'acme'), (2, 'globex');
INSERT INTO orders VALUES (10, 1, 'first'), (11, 2, 'second');" >/dev/null 2>&1
COUNT="$(scalar "SELECT count(*) FROM orders;" | tr -dc '0-9')"
[ "$COUNT" = "2" ] && check "现场已就绪（2 张订单）" 0 || { check "建表现场（实际 ${COUNT}）" 1; exit 1; }

echo ""
echo "== 1) 正向：orders.customer_id → 跳到 customers =="
FWD="$(PGDATABASE="$DB" "$CLI" fk-nav --table orders --column customer_id --value 1 2>&1)"
echo "$FWD" | tail -4 | sed 's/^/  /'
echo "$FWD" | grep -q "跳到被引用表：public.customers（id）" && check "找到正向目标" 0 || check "应找到正向目标" 1
QUERY="$(echo "$FWD" | grep -o 'SELECT \* FROM[^;]*;' | head -1)"
[ -n "$QUERY" ] && check "给出了跳转语句" 0 || { check "应给出跳转语句" 1; }
# **把生成的语句真跑一遍**：应当命中 acme 那一行
HIT="$(scalar "${QUERY}" | head -2 | tail -1)"
echo "  跳转结果：$HIT"
echo "$HIT" | grep -q "acme" && check "跳转语句真的命中被引用的那一行" 0 || { check "跳转应命中 acme（实际 ${HIT}）" 1; }

echo ""
echo "== 2) 反向：customers.id → 跳到引用它的 orders =="
REV="$(PGDATABASE="$DB" "$CLI" fk-nav --table customers --column id --value 1 2>&1)"
echo "$REV" | tail -4 | sed 's/^/  /'
echo "$REV" | grep -q "跳到引用本表的行：public.orders（customer_id）" && check "找到反向目标" 0 || check "应找到反向目标" 1
REV_QUERY="$(echo "$REV" | grep -o 'SELECT \* FROM[^;]*;' | head -1)"
REV_COUNT="$(scalar "$REV_QUERY" | head -2 | tail -1)"
echo "  反向结果：$REV_COUNT"
# `scalar` 给的是**整行**（`10 | 1 | first`），所以断言首列而不是整行相等
echo "${REV_COUNT}" | grep -qE "^10[[:space:]]*\|" && check "反向跳转命中被引用的那行（order id=10）" 0 || check "反向应命中 10（实际 ${REV_COUNT}）" 1

echo ""
echo "== 3) 没有外键的表：**没有可跳转目标**（界面据此不显示入口）=="
NONE="$(PGDATABASE="$DB" "$CLI" fk-nav --table logs --column message 2>&1)"; CODE=$?
echo "$NONE" | tail -2 | sed 's/^/  /'
[ "$CODE" -eq 1 ] && check "无目标时返回非零（入口不显示）" 0 || check "无目标应返回非零" 1
echo "$NONE" | grep -q "没有可跳转的目标" && check "明确说明没有目标" 0 || check "应说明无目标" 1

echo ""
echo "== 4) CHECK / UNIQUE 不该被当成外键 =="
PGDATABASE="$DB" "$CLI" -c "ALTER TABLE logs ADD CONSTRAINT logs_msg_ck CHECK (message <> '');" >/dev/null 2>&1
CHECKED="$(PGDATABASE="$DB" "$CLI" fk-nav --table logs --column message 2>&1)"; CODE=$?
[ "$CODE" -eq 1 ] && check "加了 CHECK 约束后仍然没有可跳转目标" 0 || { check "CHECK 不该被当成外键" 1; echo "$CHECKED" | tail -2; }

echo ""
echo "== 5) JSON 出口（脚本 / 界面可用）=="
JSON="$(PGDATABASE="$DB" "$CLI" fk-nav --table orders --column customer_id --value 2 --json 2>&1)"
echo "$JSON" > "$PWD/.build/fk.json"
python3 - "$PWD/.build/fk.json" <<'PYEOF'
import json, pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
payload = json.loads(text[text.index("{"):])
assert payload["options"], payload
assert payload["options"][0]["direction"] == "forward", payload
assert "customers" in payload["options"][0]["query"], payload
print("  ✅ JSON 里含方向、目标与可执行语句")
PYEOF
[ $? -eq 0 ] || fail=1
rm -f "$PWD/.build/fk.json"

echo ""
if [ "$fail" -eq 0 ]; then
    echo "通过：正向与反向都能找到目标且跳转语句真的命中 / 无外键时不给入口（返回非零）/ CHECK 不被当外键 / JSON 出口可用"
    echo "（**边界**：界面里的单元格右键跳转仍需人工点；本脚本验的是外键图与跳转语句）"
else
    echo "有失败项，见上"
fi
exit "$fail"
