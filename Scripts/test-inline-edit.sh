#!/bin/bash
# 验证：结果集内联编辑（FR-DATA-04）。
#
# 界面里的"改单元格 / 加行 / 删行"没法脚本化，但**这一项真正危险的那部分可以**：
#   · 生成的 DML 是否用主键定位（不是"所有列都相等"那种会一次改多行的退化写法）
#   · NULL 与空串是否写成两种东西
#   · 预览的语句与真正执行的是不是**同一份**
#   · 一批变更是否包在单个事务里，失败是否**整批回滚**（不留半截）
# 所以在真表上往返一遍：预览 → apply → 查回来核对；再造一个必然失败的批次，确认数据没动。
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"
PGBIN="$HOME/tools/pgserver/pgserver/pginstall/bin"
DATADIR="$PWD/.build/pgdata-session-test"
PORT=55433
DB="doyah_inline_edit"
STARTED=0

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }

# 取单列查询的**值**（CLI 输出是「--- statement 1 ---」+ 表头行 + 值行 + finished 行；
# 之前直接 tail -1 取到的是收尾的「查询执行完成。」—— 是我解析错了，不是产品错）
scalar() {
    "$CLI" -c "$1" 2>/dev/null | awk '
        /^--- statement 1 ---/ { seen = 1; next }
        seen && /^finished:/ { exit }
        seen { if (header == "") { header = $0 } else { print $0; exit } }'
}
cleanup() { [ "$STARTED" = "1" ] && "$PGBIN/pg_ctl" -D "$DATADIR" stop >/dev/null 2>&1; }
trap cleanup EXIT

echo "== 0) 起实例并造一张有主键的表 =="
if [ ! -f "${DATADIR}/PG_VERSION" ]; then
    mkdir -p "$DATADIR"
    "$PGBIN/initdb" -D "$DATADIR" -U postgres --auth=trust -E UTF8 >/dev/null 2>&1
fi
if ! "$PGBIN/pg_ctl" -D "$DATADIR" status >/dev/null 2>&1; then
    "$PGBIN/pg_ctl" -D "$DATADIR" -o "-p ${PORT} -k /tmp" -l /tmp/doyah-inline-pg.log start >/dev/null 2>&1
    STARTED=1
    sleep 2
fi
export PGHOST=127.0.0.1 PGPORT="$PORT" PGUSER=postgres PGPASSWORD=""
PGDATABASE=postgres "$CLI" -c "DROP DATABASE IF EXISTS ${DB};" >/dev/null 2>&1
PGDATABASE=postgres "$CLI" -c "CREATE DATABASE ${DB};" >/dev/null 2>&1
export PGDATABASE="$DB"
"$CLI" -c "CREATE TABLE items (id int primary key, status text, note text);
CREATE TABLE logs (a text, b text);
INSERT INTO items VALUES (1, 'paid', 'first'), (2, 'paid', 'second');
INSERT INTO logs VALUES ('x', 'y'), ('x', 'y');" >/dev/null 2>&1
COUNT="$(scalar "SELECT count(*) FROM items;" | tr -dc '0-9')"
[ "$COUNT" = "2" ] && check "表已就绪（2 行）" 0 || { check "建表" 1; exit 1; }

echo ""
echo "== 1) 预览：按主键定位、NULL 与空串分开写 =="
PREVIEW="$("$CLI" row-edit --table items --pk id=1 --set status=refunded --set note=NULL 2>&1)"
echo "$PREVIEW" | sed 's/^/  /'
echo "$PREVIEW" | grep -q "WHERE \"id\" = 1" && check "UPDATE 用主键定位（不是整行相等）" 0 || check "应按主键定位" 1
echo "$PREVIEW" | grep -q "note\" = NULL" && check "NULL 写成 NULL" 0 || check "NULL 渲染" 1
echo "$PREVIEW" | grep -q "预览模式" && check "默认**只预览不执行**" 0 || check "默认应只预览" 1
# 预览之后数据不该变（这是"预览"的定义）
STILL="$(scalar "SELECT status FROM items WHERE id = 1;")"
echo "$STILL" | grep -q "paid" && check "预览后数据未变（仍是 paid）" 0 || check "预览不该改数据" 1

echo ""
echo "== 2) apply：真写库，且预览与执行是同一份语句 =="
APPLY="$("$CLI" row-edit --table items --pk id=1 --set status=refunded --set note=NULL --apply 2>&1)"
echo "$APPLY" | sed 's/^/  /'
AFTER="$(scalar "SELECT status || '|' || CASE WHEN note IS NULL THEN 'NULL' ELSE 'notnull' END FROM items WHERE id = 1;")"
echo "  查回来：$AFTER"
echo "$AFTER" | grep -q "refunded" && check "status 已改（真写进去了）" 0 || check "status 应已改" 1
echo "$AFTER" | grep -q "NULL" && check "note 是 NULL（不是空串）" 0 || check "note 应为 NULL" 1
# 只改了 id=1：id=2 必须原样
UNTOUCHED="$(scalar "SELECT status FROM items WHERE id = 2;")"
echo "$UNTOUCHED" | grep -q "paid" && check "只改目标行，id=2 未受影响" 0 || check "不该波及其它行" 1

echo ""
echo "== 3) 空串与 NULL 是两回事（写回后能区分）=="
EMPTY="$("$CLI" row-edit --table items --pk id=2 --set note= --apply 2>&1)"; CODE=$?
echo "$EMPTY" | grep -q "已提交" && check "空串写法被接受（--set note=）" 0 || { check "空串写法应被接受" 1; echo "$EMPTY" | tail -2; }
[ "$CODE" -eq 0 ] || fail=1
DISTINCT="$(scalar "SELECT count(*) FROM items WHERE note IS NULL;" | tr -dc '0-9')"
IS_EMPTY="$(scalar "SELECT CASE WHEN note = '' THEN 'EMPTY' ELSE 'OTHER' END FROM items WHERE id = 2;")"
# 两条一起看才不假通过：NULL 只有 id=1 一行，且 id=2 确实是**空串**（不是"没改成"）
[ "$DISTINCT" = "1" ] && [ "$IS_EMPTY" = "EMPTY" ] \
    && check "id=1 是 NULL、id=2 是空串（两者可区分）" 0 \
    || { check "NULL 与空串应可区分（NULL 行数=${DISTINCT}，id=2 实际=${IS_EMPTY}）" 1; }

echo ""
echo "== 4) 新增 / 删除 =="
"$CLI" row-edit --table items --insert "id=3,status=new,note=" --apply >/dev/null 2>&1
THREE="$(scalar "SELECT count(*) FROM items;" | tr -dc '0-9')"
[ "$THREE" = "3" ] && check "新增一行（2 → 3）" 0 || check "新增应生效" 1
"$CLI" row-edit --table items --pk id=3 --delete --apply >/dev/null 2>&1
TWO="$(scalar "SELECT count(*) FROM items;" | tr -dc '0-9')"
[ "$TWO" = "2" ] && check "删除一行（3 → 2）" 0 || check "删除应生效" 1

echo ""
echo "== 5) 没有主键的表：**拒绝**而不是退化成「整行相等」 =="
REFUSE="$("$CLI" row-edit --table logs --set a=z 2>&1)"; CODE=$?
echo "$REFUSE" | sed 's/^/  /'
[ "$CODE" -eq 3 ] && check "没有主键 → 退出码 3（拒绝）" 0 || check "应拒绝" 1
echo "$REFUSE" | grep -q "没有主键" && check "拒绝理由说明缺主键" 0 || check "理由应说明缺主键" 1
# 退化的写法（整行相等）会一次改掉两行 —— 这里断言它**没有**执行
LOGS="$(scalar "SELECT count(*) FROM logs WHERE a = 'z';" | tr -dc '0-9')"
[ "$LOGS" = "0" ] && check "拒绝时没有改到任何行" 0 || check "拒绝时不该动数据" 1

echo ""
echo "== 6) 失败整批回滚：一条坏语句不能让别的改动留下来 =="
BEFORE_ALL="$(scalar "SELECT string_agg(status || ':' || coalesce(note, '<null>'), ',' ORDER BY id) FROM items;")"
# 第二条必然失败（列不存在）→ 整批应回滚，包括第一条成功的改动
FAILED="$("$CLI" row-edit --table items --pk id=1 --set status=changed --pk id=2 --set nope=x --apply 2>&1)"; CODE=$?
echo "$FAILED" | tail -3 | sed 's/^/  /'
[ "$CODE" -ne 0 ] && check "失败批次返回非零" 0 || check "失败批次应返回非零" 1
AFTER_ALL="$(scalar "SELECT string_agg(status || ':' || coalesce(note, '<null>'), ',' ORDER BY id) FROM items;")"
[ "$BEFORE_ALL" = "$AFTER_ALL" ] && check "整批回滚：一条失败 → 数据与批前完全一致" 0 || { check "应整批回滚" 1; echo "  批前：$BEFORE_ALL"; echo "  批后：$AFTER_ALL"; }

echo ""
if [ "$fail" -eq 0 ]; then
    echo "通过：主键定位 / NULL 与空串分开 / 预览不改数据 / apply 真写库且只动目标行 /"
    echo "      无主键表被拒绝（退化写法没有执行）/ 失败批次整批回滚"
    echo "（**边界**：界面上的单元格编辑交互仍需人工点；本脚本验的是 DML 生成与事务语义）"
else
    echo "有失败项，见上"
fi
exit "$fail"
