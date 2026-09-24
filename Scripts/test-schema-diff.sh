#!/bin/bash
# 验证：Schema 对比与同步（FR-DDL-04）。
#
# 最强的验证不是"能算出差异"，而是**应用生成的同步脚本之后再比一次应当无差异** ——
# 说明生成的语句真能把目标库改成期望的形状。同时验证破坏性变更默认不生成。
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"
PGBIN="$HOME/tools/pgserver/pgserver/pginstall/bin"
DATADIR="$PWD/.build/pgdata-session-test"
PORT=55433
LEFT_DB="doyah_schema_left"
RIGHT_DB="doyah_schema_right"
STARTED=0

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }
cleanup() { [ "$STARTED" = "1" ] && "$PGBIN/pg_ctl" -D "$DATADIR" stop >/dev/null 2>&1; }
trap cleanup EXIT
run_in() { PGDATABASE="$1" "$CLI" -c "$2" >/dev/null 2>&1; }

echo "== 0) 起实例，造两个库：期望 / 目标（结构故意有差异）=="
if [ ! -f "${DATADIR}/PG_VERSION" ]; then
    mkdir -p "$DATADIR"
    "$PGBIN/initdb" -D "$DATADIR" -U postgres --auth=trust -E UTF8 >/dev/null 2>&1
fi
if ! "$PGBIN/pg_ctl" -D "$DATADIR" status >/dev/null 2>&1; then
    "$PGBIN/pg_ctl" -D "$DATADIR" -o "-p ${PORT} -k /tmp" -l /tmp/doyah-schema-pg.log start >/dev/null 2>&1
    STARTED=1
    sleep 2
fi
export PGHOST=127.0.0.1 PGPORT="$PORT" PGUSER=postgres PGPASSWORD=""
# 准备阶段**必须验成功**：上一版把 DROP/CREATE 的输出与退出码全丢了，
# 结果库没被重置（残留连接挡住了 DROP），后面全在旧状态上跑，故障看起来像"生成器与服务器对不上"。
for db in "$LEFT_DB" "$RIGHT_DB"; do
    if ! PGDATABASE=postgres "$CLI" -c "DROP DATABASE IF EXISTS ${db} WITH (FORCE);" >/dev/null 2>&1; then
        echo "  ❌ 无法重建数据库 ${db}（DROP 失败）"
        exit 1
    fi
    if ! PGDATABASE=postgres "$CLI" -c "CREATE DATABASE ${db};" >/dev/null 2>&1; then
        echo "  ❌ 无法创建数据库 ${db}"
        exit 1
    fi
done
# 再确认一次：两个库都必须是**空**的（否则后面的差异断言全无意义）
for db in "$LEFT_DB" "$RIGHT_DB"; do
    LEFT_TABLES="$(PGDATABASE="$db" "$CLI" -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null | grep -A1 "count:" | tail -1 | tr -dc '0-9')"
    [ "${LEFT_TABLES}" = "0" ] || { echo "  ❌ 数据库 ${db} 重置后仍有 ${LEFT_TABLES} 张表"; exit 1; }
done
echo "  ✅ 两个库已重置为空库"
run_in "$LEFT_DB" "CREATE TABLE orders (id integer primary key, note text, amount numeric(10,2));
CREATE TABLE only_left (id integer primary key);"
run_in "$RIGHT_DB" "CREATE TABLE orders (id integer primary key, note text, legacy text);
CREATE TABLE only_right (id integer primary key);"

echo ""
echo "== 1) 导出两个快照 =="
PGDATABASE="$LEFT_DB" "$CLI" schema-snapshot --schema public --out "$PWD/.build/left.json" 2>&1 | sed 's/^/  /'
PGDATABASE="$RIGHT_DB" "$CLI" schema-snapshot --schema public --out "$PWD/.build/right.json" 2>&1 | sed 's/^/  /'
grep -q "orders" "$PWD/.build/left.json" && check "快照里含 orders 表" 0 || check "快照应含表" 1

echo ""
echo "== 2) 安全模式（默认）：只做加法与安全修改，破坏性跳过 =="
SAFE="$(PGDATABASE=postgres "$CLI" schema-diff --left "$PWD/.build/left.json" --right "$PWD/.build/right.json" --json 2>&1)"
SAFE_CODE=$?
echo "$SAFE" > "$PWD/.build/safe.json"
python3 - "$PWD/.build/safe.json" <<'PYEOF'
import json, pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
payload = json.loads(text[text.index("{"):])
statements = "\n".join(payload["statements"])
skipped = "\n".join(payload["skippedDestructive"])
assert 'CREATE TABLE "public"."only_left"' in statements, statements
assert 'ADD COLUMN "amount"' in statements, statements
assert "DROP COLUMN" not in statements, "默认不该生成删列：" + statements
assert "DROP TABLE" not in statements, "默认不该生成删表：" + statements
assert "legacy" in skipped, skipped
assert "only_right" in skipped, skipped
print("  ✅ 生成建表与加列；删列/删表被跳过并如实列出")
PYEOF
[ $? -eq 0 ] || fail=1
[ "$SAFE_CODE" -eq 2 ] && check "有差异时退出码 2（脚本可判定）" 0 || check "退出码应为 2" 1

echo ""
echo "== 3) 应用安全脚本 → 目标库结构被改对；只剩被跳过的多余表 =="
# 逐条执行交给 python：CREATE TABLE 是**多行语句**，用 while read 会拆成碎片全部失败（我第一版就这么错的）
python3 - "$CLI" "$RIGHT_DB" "$PWD/.build/safe.json" <<'PYEOF'
import json, os, pathlib, subprocess, sys
cli, database, path = sys.argv[1], sys.argv[2], sys.argv[3]
text = pathlib.Path(path).read_text(encoding="utf-8")
payload = json.loads(text[text.index("{"):])
env = dict(os.environ, PGDATABASE=database)
for statement in payload["statements"]:
    done = subprocess.run([cli, "-c", statement], env=env, capture_output=True, text=True)
    if done.returncode != 0:
        print("  ❌ 执行失败：", statement.splitlines()[0])
        print("     stdout:", done.stdout[-400:])
        print("     stderr:", done.stderr[-400:])
        sys.exit(1)
print("  ✅ 已应用 %d 条语句到 %s" % (len(payload["statements"]), database))
PYEOF
[ $? -eq 0 ] || fail=1

PGDATABASE="$RIGHT_DB" "$CLI" schema-snapshot --schema public --out "$PWD/.build/right.json" >/dev/null 2>&1
AFTER="$(PGDATABASE=postgres "$CLI" schema-diff --left "$PWD/.build/left.json" --right "$PWD/.build/right.json" --json 2>&1)"
echo "$AFTER" > "$PWD/.build/after.json"
python3 - "$PWD/.build/after.json" <<'PYEOF'
import json, pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
payload = json.loads(text[text.index("{"):])
kinds = {item["table"]: item["kind"] for item in payload["diffs"]}
assert kinds.get("public.only_right", "").startswith("目标库多出"), kinds
assert "public.only_left" not in kinds, "缺的表应已建出来：" + str(kinds)
# orders 仍会有**一处**差异 —— 被安全模式跳过的"多余列 legacy"本就该留着；
# 若列级的 ADD 没生效，这里会显示 2 处（漏加列 + 多余列）
assert kinds.get("public.orders") == "1 处列级差异", "orders 应只剩被跳过的删除列：" + str(kinds)
print("  ✅ 应用后：缺的表已建、新增列已补齐，只剩被安全模式跳过的多余列")
PYEOF
[ $? -eq 0 ] || fail=1

echo ""
echo "== 4) 开 --allow-drop 再来一遍 → 应当完全一致 =="
# **必须先重新快照目标库**：right.json 是"应用改动之前"的状态，拿它再生成脚本
# 会把已经建好的表当成缺失，于是重复 CREATE → `already exists`（我上一版就这么错的）
PGDATABASE="$RIGHT_DB" "$CLI" schema-snapshot --schema public --out "$PWD/.build/right.json" >/dev/null 2>&1
AGGR="$(PGDATABASE=postgres "$CLI" schema-diff --left "$PWD/.build/left.json" --right "$PWD/.build/right.json" --allow-drop --json 2>&1)"
echo "$AGGR" > "$PWD/.build/aggr.json"
python3 - "$CLI" "$RIGHT_DB" "$PWD/.build/aggr.json" <<'PYEOF'
import json, os, pathlib, subprocess, sys
cli, database, path = sys.argv[1], sys.argv[2], sys.argv[3]
text = pathlib.Path(path).read_text(encoding="utf-8")
payload = json.loads(text[text.index("{"):])
env = dict(os.environ, PGDATABASE=database)
for statement in payload["statements"]:
    done = subprocess.run([cli, "-c", statement], env=env, capture_output=True, text=True)
    if done.returncode != 0:
        print("  ❌ 执行失败：", statement.splitlines()[0])
        print("     stdout:", done.stdout[-400:])
        print("     stderr:", done.stderr[-400:])
        sys.exit(1)
print("  ✅ 已应用 %d 条语句（含破坏性）" % len(payload["statements"]))
PYEOF
[ $? -eq 0 ] || fail=1

PGDATABASE="$RIGHT_DB" "$CLI" schema-snapshot --schema public --out "$PWD/.build/right.json" >/dev/null 2>&1
FINAL="$(PGDATABASE=postgres "$CLI" schema-diff --left "$PWD/.build/left.json" --right "$PWD/.build/right.json" --allow-drop 2>&1)"
FINAL_CODE=$?
echo "$FINAL" | sed 's/^/  /'
[ "$FINAL_CODE" -eq 0 ] && echo "$FINAL" | grep -q "结构一致" \
    && check "同步后再比：结构一致（生成的语句与真实服务端对得上）" 0 || check "同步后应一致" 1
rm -f "$PWD/.build/left.json" "$PWD/.build/right.json" "$PWD/.build/safe.json" "$PWD/.build/after.json" "$PWD/.build/aggr.json"

echo ""
if [ "$fail" -eq 0 ]; then
    echo "通过：快照导出 / 安全模式只做加法与安全修改（删列删表跳过并列出）/ 应用生成的脚本后差异消失 /"
    echo "      开 --allow-drop 后完全一致"
    echo "（**边界**：界面里的差异视图仍需人工看；本脚本验的是差异计算与同步脚本）"
else
    echo "有失败项，见上"
fi
exit "$fail"
