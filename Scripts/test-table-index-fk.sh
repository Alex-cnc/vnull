#!/bin/bash
# 真机验证：索引 / 外键 / 约束的读取与变更语句（FR-DDL-03 扩写）。
#
# 验两件事：① 代码里那两条元数据查询在真机上给对了清单（否则界面上的"删除"无从谈起）；
# ② 生成出来的 CREATE INDEX / ADD CONSTRAINT / DROP 语句在真机上真的能执行。
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"
ACCOUNT="D264B21B-1880-4E73-A2D0-59A3F8E4D7EC"
S="doyah_idx_check"

export PGHOST=192.168.5.217 PGUSER=zxvmax PGDATABASE=zxvmax PGSSLMODE=disable
PGPASSWORD="$("$CLI" secret get --id "$ACCOUNT")"
export PGPASSWORD

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }

echo "== 1) 造现场：表 + 索引 + 引用表 + 外键 + CHECK =="
"$CLI" -c "DROP SCHEMA IF EXISTS $S CASCADE;
CREATE SCHEMA $S;
CREATE TABLE $S.u (id integer PRIMARY KEY);
CREATE TABLE $S.t (id integer PRIMARY KEY, owner_id integer, email text, age integer,
  CONSTRAINT t_owner_fkey FOREIGN KEY (owner_id) REFERENCES $S.u(id) ON DELETE CASCADE,
  CONSTRAINT t_age_check CHECK (age > 0));
CREATE INDEX t_email_idx ON $S.t (email);" > /tmp/idx-setup.log 2>&1
[ $? -eq 0 ] && echo "  ✅ 现场已建立" || { echo "  ❌ 建现场失败"; cat /tmp/idx-setup.log; exit 1; }

echo ""
echo "== 2) 代码里那条索引查询的输出 =="
IDX_SQL="SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = '$S' AND tablename = 't' ORDER BY indexname"
IDX_OUT="$("$CLI" -c "$IDX_SQL" 2>&1)"
echo "$IDX_OUT" | sed -n '/^--- statement/,$p' | head -8
echo "$IDX_OUT" | grep -q "t_email_idx" && check "读到自建索引 t_email_idx" 0 || check "读到 t_email_idx" 1
echo "$IDX_OUT" | grep -q "t_pkey" && check "读到主键索引 t_pkey" 0 || check "读到 t_pkey" 1
echo "$IDX_OUT" | grep -q "CREATE INDEX t_email_idx" && check "索引定义是可读的 CREATE INDEX 语句（可直接展示）" 0 || check "索引定义可读" 1

echo ""
echo "== 3) 代码里那条约束查询的输出 =="
CON_SQL="SELECT con.conname, con.contype, pg_get_constraintdef(con.oid)
FROM pg_constraint con
JOIN pg_class c ON c.oid = con.conrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = '$S' AND c.relname = 't' AND con.contype IN ('p', 'u', 'f', 'c')
ORDER BY con.conname"
CON_OUT="$("$CLI" -c "$CON_SQL" 2>&1)"
echo "$CON_OUT" | sed -n '/^--- statement/,$p' | head -8
echo "$CON_OUT" | grep -q "t_owner_fkey | f |" && check "外键读到且类型代码为 f" 0 || check "外键与类型代码" 1
echo "$CON_OUT" | grep -q "t_age_check | c |" && check "CHECK 约束读到且类型代码为 c" 0 || check "CHECK 与类型代码" 1
echo "$CON_OUT" | grep -qE "t_pkey +\| p \|" && check "主键读到且类型代码为 p（界面按此禁用删除）" 0 || check "主键与类型代码" 1
echo "$CON_OUT" | grep -q "FOREIGN KEY (owner_id) REFERENCES $S.u(id) ON DELETE CASCADE" \
    && check "外键定义含引用动作（ON DELETE CASCADE）" 0 || check "外键定义与引用动作" 1

echo ""
echo "== 4) 生成出来的变更语句在真机能执行 =="
run() { # run <说明> <SQL>
    "$CLI" -c "$1" > /tmp/idx-step.log 2>&1
    if [ $? -eq 0 ]; then check "$2" 0; else check "$2"; tail -3 /tmp/idx-step.log; fi
}
run "ALTER TABLE $S.t ADD CONSTRAINT t_age2_check CHECK (age < 200);" "ADD CONSTRAINT（CHECK）"
run "CREATE UNIQUE INDEX t_email_uniq ON $S.t (email) WHERE email IS NOT NULL;" "CREATE UNIQUE INDEX + 部分索引条件"
run "ALTER TABLE $S.t DROP CONSTRAINT t_age2_check;" "DROP CONSTRAINT"
run "DROP INDEX $S.t_email_uniq;" "DROP INDEX"

echo ""
echo "== 5) 清理现场 =="
"$CLI" -c "DROP SCHEMA IF EXISTS $S CASCADE;" > /tmp/idx-cleanup.log 2>&1
[ $? -eq 0 ] && echo "  ✅ 已删除 $S" || { echo "  ❌ 清理失败"; fail=1; }

echo ""
if [ "$fail" -eq 0 ]; then
    echo "通过：索引 / 外键 / 约束在真机 18.6 上读得准、变更语句能执行"
else
    echo "有失败项，见上"
fi
exit "$fail"
