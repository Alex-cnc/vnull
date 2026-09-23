#!/bin/bash
# 真机验证：视图 / 函数 DDL 取回与装配（FR-META-13）。
#
# 为什么必须上真机：这段逻辑的价值全在"服务端到底给什么"——
# 定义体是否带结尾分号、同名函数是不是真的多行、装配出来的语句能不能执行，
# 单测都只能模拟。这里用真实 PostgreSQL 18.6 走一遍，并**看退出码**。
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"
ACCOUNT="D264B21B-1880-4E73-A2D0-59A3F8E4D7EC"

export PGHOST=192.168.5.217 PGUSER=zxvmax PGDATABASE=zxvmax PGSSLMODE=disable
PGPASSWORD="$("$CLI" secret get --id "$ACCOUNT")"
export PGPASSWORD

fail=0
step() { echo ""; echo "== $* =="; }

# 提取结果列内容：到 "finished:" / "查询执行完成" 之类的日志行就停。
extract_column() {
    awk '/^[a-z_]+:TEXT$/{f=1;next} f&&/^finished:|^查询执行完成|^---/{exit} f{print}'
}

step "1) 视图定义体（我在代码里生成的那条查询）"
VIEW_BODY="$("$CLI" -c "SELECT pg_get_viewdef('\"doyah_ddl_check\".\"v\"'::regclass, true) AS view_definition" | extract_column)"
echo "$VIEW_BODY"
case "$VIEW_BODY" in
    *';') echo "→ 定义体自带结尾分号 ✅（装配时必须去掉，否则会生成两条语句）" ;;
    *)    echo "→ 定义体没有结尾分号 ❌（装配规则的前提不成立）"; fail=1 ;;
esac
if echo "$VIEW_BODY" | grep -q "finished:"; then echo "→ 提取混入日志行 ❌"; fail=1; fi

step "2) 装配成 CREATE OR REPLACE VIEW 并真的执行（事务内，随后回滚）"
CLEAN="${VIEW_BODY%;}"
STMT="CREATE OR REPLACE VIEW \"doyah_ddl_check\".\"v\" AS
$CLEAN;"
"$CLI" -c "BEGIN; $STMT ROLLBACK;" > /tmp/ddl-view-check.log 2>&1
VIEW_CODE=$?
if [ "$VIEW_CODE" -eq 0 ]; then
    echo "→ 装配后的语句被 PostgreSQL 接受（退出码 0）✅"
else
    echo "→ 执行失败（退出码 ${VIEW_CODE}）❌"; tail -5 /tmp/ddl-view-check.log; fail=1
fi

step "3) 函数：两个同名重载都要取到"
FUNC_ROWS="$("$CLI" -c "SELECT pg_get_functiondef(p.oid) AS function_definition FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE p.proname = 'f' AND n.nspname = 'doyah_ddl_check' ORDER BY p.oid" | grep -c "^CREATE OR REPLACE FUNCTION doyah_ddl_check.f")"
echo "取到的重载条数：$FUNC_ROWS"
if [ "$FUNC_ROWS" -eq 2 ]; then
    echo "→ 两个重载都在结果里 ✅（不 LIMIT 1 是必须的）"
else
    echo "→ 重载条数不是 2 ❌"; fail=1
fi

step "4) 不支持 / 无权限时的行为：表不存在时 regclass 转换应报错（由界面转成可读提示）"
"$CLI" -c "SELECT pg_get_viewdef('\"doyah_ddl_check\".\"nope\"'::regclass, true) AS view_definition" > /tmp/ddl-missing.log 2>&1
MISSING_CODE=$?
if [ "$MISSING_CODE" -ne 0 ]; then
    echo "→ 查询如实报错（退出码 ${MISSING_CODE}）✅ 不会被当成'空结果'而静默失败"
    grep -m1 "简要信息\|does not exist" /tmp/ddl-missing.log | head -1
else
    echo "→ 竟然成功了 ❌"; fail=1
fi

step "5) 清理现场"
"$CLI" -c "DROP SCHEMA IF EXISTS doyah_ddl_check CASCADE;" > /tmp/ddl-cleanup.log 2>&1
[ $? -eq 0 ] && echo "→ 已删除 doyah_ddl_check ✅" || { echo "→ 清理失败 ❌"; fail=1; }

echo ""
if [ "$fail" -eq 0 ]; then
    echo "全部通过：视图 / 函数 DDL 在真机 18.6 上取回并装配成功"
else
    echo "有失败项，见上"
fi
exit "$fail"
