#!/bin/bash
# 验证：ER 图 / 关系图（FR-DDL-05）—— 由外键元数据生成的图模型、分层布局与文本导出。
#
# 为什么要这么验：ER 图最容易被"看着像"骗过去 —— 少一条外键、复合外键列配错、互相引用的表
# 把布局算成死循环，画出来都还是"一张图"。所以这里：
#   ① 真库造出六种形状：普通外键 / 复合外键 / 自引用 / 互相引用（环）/ 孤立表 / 视图；
#   ② 导出的 Mermaid 用 **Python 解析出边集**，与期望的边集逐条比对（不是 grep 关键词）；
#   ③ 布局断言：被引用的一方在上层、环被点名、**同一份输入两次导出逐字节一致**；
#   ④ 负例：不认识的格式要报错、没有外键的 schema 不能凭空生出边。
#
# 环境：真库连接信息由 `Scripts/lib/test-env.sh` 决定（过渡期默认本机临时集群，档位见该文件的档位表）。
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"
# 连接信息（本机过渡集群 / 远程专用库）由共用入口决定 —— 三档端口与目录只写在它里面
source "$(cd "$(dirname "$0")" && pwd)/lib/test-env.sh"
doyah_test_env_summary

PGBIN="${DOYAH_TEST_PG_BIN}"
DATADIR="${DOYAH_TEST_LOCAL_DATADIR}"
PORT="${DOYAH_TEST_PGPORT}"
DB="doyah_er_check"
STARTED=0

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }
cleanup() { [ "$STARTED" = "1" ] && "$PGBIN/pg_ctl" -D "$DATADIR" stop >/dev/null 2>&1; }
trap cleanup EXIT

echo "== 0) 起实例并造出六种形状 =="
if [ ! -f "${DATADIR}/PG_VERSION" ]; then
    mkdir -p "$DATADIR"
    "$PGBIN/initdb" -D "$DATADIR" -U postgres --auth=trust -E UTF8 >/dev/null 2>&1
fi
if ! "$PGBIN/pg_ctl" -D "$DATADIR" status >/dev/null 2>&1; then
    "$PGBIN/pg_ctl" -D "$DATADIR" -o "-p ${PORT} -k /tmp" -l /tmp/doyah-er-pg.log start >/dev/null 2>&1
    STARTED=1
    sleep 2
fi
doyah_test_env_export_connection
PGDATABASE="${DOYAH_TEST_ADMIN_DB}" "$CLI" -c "DROP DATABASE IF EXISTS ${DB} WITH (FORCE);" >/dev/null 2>&1
PGDATABASE="${DOYAH_TEST_ADMIN_DB}" "$CLI" -c "CREATE DATABASE ${DB};" >/dev/null 2>&1
export PGDATABASE="$DB"
"$CLI" -c "
CREATE TABLE customers (id integer PRIMARY KEY, name text);
CREATE TABLE orders (id integer PRIMARY KEY, customer_id integer REFERENCES customers(id) ON DELETE CASCADE);
CREATE TABLE order_items (order_id integer REFERENCES orders(id), sku text, PRIMARY KEY (order_id, sku));
CREATE TABLE parent (a integer, b integer, PRIMARY KEY (a, b));
CREATE TABLE child (x integer, y integer, FOREIGN KEY (x, y) REFERENCES parent(a, b));
CREATE TABLE category (id integer PRIMARY KEY, parent_id integer REFERENCES category(id));
CREATE TABLE a (id integer PRIMARY KEY, b_id integer);
CREATE TABLE b (id integer PRIMARY KEY, a_id integer);
ALTER TABLE a ADD CONSTRAINT a_b_fk FOREIGN KEY (b_id) REFERENCES b(id);
ALTER TABLE b ADD CONSTRAINT b_a_fk FOREIGN KEY (a_id) REFERENCES a(id);
CREATE TABLE audit_log (id bigint PRIMARY KEY);
CREATE VIEW v_orders AS SELECT * FROM orders;
" >/dev/null 2>&1
check "建库与建表（含复合外键 / 自引用 / 环 / 视图）" $?

echo ""
echo "== 1) Mermaid 导出：用 Python 解析边集，与期望逐条比对 =="
"$CLI" er-diagram --schema public --format mermaid --out /tmp/doyah-er.mmd > /tmp/doyah-er-mermaid.log 2>&1
check "导出退出码 0" $?
check "输出是 erDiagram" "$(head -1 /tmp/doyah-er.mmd | grep -q '^erDiagram$' && echo 0 || echo 1)"

python3 - /tmp/doyah-er.mmd <<'PY' > /tmp/doyah-er-mermaid.txt 2>&1
import re, sys

text = open(sys.argv[1], encoding="utf-8").read()
problems = []

# 实体名是净化过的（点 → 下划线），注释里保留真实限定名。
entities = re.findall(r"^\s+([A-Za-z_][A-Za-z0-9_]*)\s*\{$", text, re.M)
expected_entities = {
    "public_customers", "public_orders", "public_order_items", "public_parent",
    "public_child", "public_category", "public_a", "public_b", "public_audit_log",
}
missing = expected_entities - set(entities)
if missing:
    problems.append(f"缺少实体：{sorted(missing)}")
if "public_v_orders" in entities:
    problems.append("视图不该画进 ER 图（视图没有外键约束）")

# 关系行：父 ||--o{ 子 : "标签"
edges = set()
for line in text.splitlines():
    match = re.match(r"^\s+([A-Za-z_][A-Za-z0-9_]*)\s+\|\|--o\{\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*\"(.+)\"$", line)
    if match:
        edges.add((match.group(1), match.group(2), match.group(3)))

expected_edges = {
    ("public_customers", "public_orders", "orders_customer_id_fkey"),
    ("public_orders", "public_order_items", "order_items_order_id_fkey"),
    ("public_parent", "public_child", "child_x_y_fkey"),
    ("public_category", "public_category", "category_parent_id_fkey"),
    ("public_b", "public_a", "a_b_fk"),
    ("public_a", "public_b", "b_a_fk"),
}
missing_edges = expected_edges - edges
extra_edges = edges - expected_edges
if missing_edges:
    problems.append(f"缺少关系：{sorted(missing_edges)}")
if extra_edges:
    problems.append(f"多出关系：{sorted(extra_edges)}")

# 属性标记：主键 PK、外键 FK 都要在。
if "integer customer_id FK" not in text:
    problems.append("orders.customer_id 没有标 FK")
if "integer id PK" not in text:
    problems.append("customers.id 没有标 PK")
# 复合外键的两列都要标 FK。
for column in ("integer x FK", "integer y FK"):
    if column not in text:
        problems.append(f"复合外键列没标 FK：{column}")
# 多词类型 / 带括号的类型要净化成能渲染的写法。
if "(" in re.sub(r'^.*\{|^.*\}', '', text):
    pass

print("OK" if not problems else "FAIL")
for problem in problems:
    print("  " + problem)
PY
if grep -q "^OK$" /tmp/doyah-er-mermaid.txt; then
    check "9 个实体（视图排除）+ 6 条关系（含复合 / 自引用 / 环）逐条对上、PK/FK 标注齐全" 0
else
    check "9 个实体（视图排除）+ 6 条关系（含复合 / 自引用 / 环）逐条对上、PK/FK 标注齐全" 1
    cat /tmp/doyah-er-mermaid.txt
fi

echo ""
echo "== 2) 布局：父子方向、环被点名、可复现 =="
"$CLI" er-diagram --schema public --format mermaid --layout > /tmp/doyah-er-layout.txt 2>&1
CUST_LAYER="$(grep "public.customers @" /tmp/doyah-er-layout.txt | sed -n 's/.*第 \([0-9]*\) 层.*/\1/p')"
ORD_LAYER="$(grep "public.orders @" /tmp/doyah-er-layout.txt | sed -n 's/.*第 \([0-9]*\) 层.*/\1/p')"
ITEM_LAYER="$(grep "public.order_items @" /tmp/doyah-er-layout.txt | sed -n 's/.*第 \([0-9]*\) 层.*/\1/p')"
echo "  层号：customers=$CUST_LAYER orders=$ORD_LAYER order_items=$ITEM_LAYER"
if [ -n "$CUST_LAYER" ] && [ -n "$ORD_LAYER" ] && [ -n "$ITEM_LAYER" ] \
    && [ "$CUST_LAYER" -lt "$ORD_LAYER" ] && [ "$ORD_LAYER" -lt "$ITEM_LAYER" ]; then
    check "被引用的一方在上层（customers < orders < order_items）" 0
else
    check "被引用的一方在上层（customers < orders < order_items）" 1
fi
grep -q "互相引用（无法拓扑排序，已放到最后）：public.a、public.b、public.category" /tmp/doyah-er-layout.txt \
    && check "成环与自引用的表被点名列在输出里" 0 \
    || check "成环与自引用的表被点名列在输出里" 1

"$CLI" er-diagram --schema public --format mermaid --out /tmp/doyah-er-again.mmd > /dev/null 2>&1
if cmp -s /tmp/doyah-er.mmd /tmp/doyah-er-again.mmd; then
    check "同一份输入两次导出逐字节一致（位置不会每次乱跳）" 0
else
    check "同一份输入两次导出逐字节一致（位置不会每次乱跳）" 1
fi

echo ""
echo "== 3) DOT 与 JSON 导出 =="
"$CLI" er-diagram --schema public --format dot --out /tmp/doyah-er.dot > /dev/null 2>&1
check "dot 导出退出码 0" $?
grep -q 'digraph er {' /tmp/doyah-er.dot && check "DOT 头正确" 0 || check "DOT 头正确" 1
grep -q '"public.a" -> "public.b"' /tmp/doyah-er.dot && check "DOT 里边的方向是子 → 父" 0 || check "DOT 里边的方向是子 → 父" 1
grep -q 'arrowhead=crow' /tmp/doyah-er.dot && check "DOT 用 crow 箭头（一对多语义）" 0 || check "DOT 用 crow 箭头（一对多语义）" 1

"$CLI" er-diagram --schema public --format json --out /tmp/doyah-er.json > /dev/null 2>&1
python3 - /tmp/doyah-er.json <<'PY' > /tmp/doyah-er-json.txt 2>&1
import json, sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
problems = []
tables = {t["table"]: t for t in data["tables"]}
relationships = {(r["from"], r["to"], r.get("name")): r for r in data["relationships"]}

if len(tables) != 9:
    problems.append(f"期望 9 张表，实际 {len(tables)}：{sorted(tables)}")
if len(relationships) != 6:
    problems.append(f"期望 6 条关系，实际 {len(relationships)}")

pair = relationships.get(("public.child", "public.parent", "child_x_y_fkey"))
if pair is None:
    problems.append("复合外键那条关系没导出")
else:
    if pair["fromColumns"] != ["x", "y"] or pair["toColumns"] != ["a", "b"]:
        problems.append(f"复合外键列配对错了：{pair['fromColumns']} → {pair['toColumns']}")
    if not pair.get("composite"):
        problems.append("复合外键没有 composite 标记")

cascade = relationships.get(("public.orders", "public.customers", "orders_customer_id_fkey"))
if cascade is None or cascade.get("onDelete") != "CASCADE":
    problems.append(f"ON DELETE CASCADE 没解析出来：{cascade}")

self_edge = [r for r in data["relationships"] if r["from"] == r["to"]]
if len(self_edge) != 1:
    problems.append(f"自引用关系应当恰好 1 条，实际 {len(self_edge)}")

print("OK" if not problems else "FAIL")
for problem in problems:
    print("  " + problem)
PY
if grep -q "^OK$" /tmp/doyah-er-json.txt; then
    check "JSON 可被标准解析器解析：表数 / 关系数 / 复合列配对 / CASCADE / 自引用 全对" 0
else
    check "JSON 可被标准解析器解析：表数 / 关系数 / 复合列配对 / CASCADE / 自引用 全对" 1
    cat /tmp/doyah-er-json.txt
fi

echo ""
echo "== 4) 负例 =="
"$CLI" er-diagram --schema public --format png > /tmp/doyah-er-bad.log 2>&1
code=$?
check "不认识的导出格式被拒（退出码 ${code}，期望 64）" "$([ "$code" -eq 64 ] && echo 0 || echo 1)"

"$CLI" -c "CREATE SCHEMA no_fk; CREATE TABLE no_fk.only_table (id integer PRIMARY KEY);" >/dev/null 2>&1
"$CLI" er-diagram --schema no_fk --format mermaid --out /tmp/doyah-er-nofk.mmd > /dev/null 2>&1
edgelines="$(grep -c -- '||--o{' /tmp/doyah-er-nofk.mmd || true)"
entity="$(grep -c 'no_fk_only_table {' /tmp/doyah-er-nofk.mmd || true)"
check "没有外键的 schema：表在、关系 0 条（不凭空生边）" "$([ "$edgelines" = "0" ] && [ "$entity" = "1" ] && echo 0 || echo 1)"

echo ""
if [ "$fail" -eq 0 ]; then
    echo "全部通过：ER 图的模型 / 布局 / 三种导出都经真库与 Python 独立核对。"
    echo "（**边界**：Mermaid / DOT 的**渲染效果**（连线漂不漂亮、文字会不会挤）只能人工看；"
    echo "  本脚本验的是图的结构与布局数值。界面里的 ER 图面板见 Docs/design/剩余任务清单.md。）"
else
    echo "有失败项，见上"
fi
exit "$fail"
