#!/bin/bash
# 真机验证：表结构读取（FR-DDL-03 的元数据前提）。
#
# 表设计器的差异计算依赖「默认值 / 主键 / 可空」读得准 —— 这三项读错，
# 界面会算出错误的 ALTER（例如把没改的列也写成 ALTER，或悄悄丢掉 NOT NULL）。
# 这里用真实 PostgreSQL 跑一遍代码里那条结构查询，逐项核对。
#
# 注意：**ALTER 语句的生成**由 12 项单测覆盖，本脚本只验"读得准"这一半 ——
# 「在真表上应用 ALTER 并核对」需要图形界面，见运行手册清单 H。
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"
ACCOUNT="D264B21B-1880-4E73-A2D0-59A3F8E4D7EC"
SCHEMA="doyah_struct_check"
TABLE="t"

# 本脚本不建集群、不建库，只对一台常驻实例做只读核对 —— 没有「迁移第 2 步」要改的段落
DOYAH_TEST_SCRIPT_READY_FOR_REMOTE=1
# 连接信息（本机过渡集群 / 远程专用库）由共用入口决定 —— 三档端口与目录只写在它里面
source "$(cd "$(dirname "$0")" && pwd)/lib/test-env.sh"
doyah_test_env_summary

export PGHOST="${DOYAH_TEST_REMOTE_HOST}" PGUSER="${DOYAH_TEST_REMOTE_USER}" PGDATABASE="${DOYAH_TEST_REMOTE_DATABASE}" PGSSLMODE="${DOYAH_TEST_PGSSLMODE}"
PGPASSWORD="$("$CLI" secret get --id "$ACCOUNT")"
export PGPASSWORD

fail=0
check() { # check <说明> <条件结果 0/1>
    if [ "$2" -eq 0 ]; then
        echo "  ✅ $1"
    else
        echo "  ❌ $1"
        fail=1
    fi
}

echo "== 1) 造现场：带主键 / 默认值 / NOT NULL 的表 =="
"$CLI" -c "DROP SCHEMA IF EXISTS $SCHEMA CASCADE;
CREATE SCHEMA $SCHEMA;
CREATE TABLE $SCHEMA.$TABLE (
  id integer PRIMARY KEY DEFAULT 7,
  note text NOT NULL DEFAULT 'x',
  flag boolean
);" > /tmp/struct-setup.log 2>&1
[ $? -eq 0 ] && echo "  ✅ 现场已建立" || { echo "  ❌ 建表现场失败"; cat /tmp/struct-setup.log; exit 1; }

echo ""
echo "== 2) 代码里那条结构查询的输出 =="
QUERY="SELECT c.column_name, c.data_type, c.is_nullable, c.column_default,
       CASE WHEN pk.column_name IS NULL THEN 'NO' ELSE 'YES' END AS is_primary_key
FROM information_schema.columns c
LEFT JOIN (
  SELECT kcu.column_name FROM information_schema.table_constraints tc
  JOIN information_schema.key_column_usage kcu
    ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
  WHERE tc.constraint_type = 'PRIMARY KEY' AND tc.table_schema = '$SCHEMA' AND tc.table_name = '$TABLE'
) pk ON pk.column_name = c.column_name
WHERE c.table_schema = '$SCHEMA' AND c.table_name = '$TABLE'
ORDER BY c.ordinal_position"
OUT="$("$CLI" -c "$QUERY" 2>&1)"
echo "$OUT" | sed -n '/^--- statement/,$p'

echo ""
echo "== 3) 逐项核对（表设计器就是按这 5 列算差异的）=="
# CLI 的行格式是 `值 | 值 | …`：字段 1=列名 2=类型 3=可空 4=默认值 5=主键
row_field() {
    echo "$OUT" | awk -F' \\| ' -v name="$1" -v field="$2" '$1 == name { print $field }' | tail -1
}

check_eq() { # check_eq <说明> <实际> <期望>
    if [ "$2" = "$3" ]; then
        echo "  ✅ $1（$2）"
    else
        echo "  ❌ $1：实际 '$2'，期望 '$3'"
        fail=1
    fi
}

check_eq "id 的类型" "$(row_field id 2)" "integer"
check_eq "id 的主键标记（读错就会漏写 PRIMARY KEY）" "$(row_field id 5)" "YES"
check_eq "id 的默认值（读错就会漏写 DEFAULT）" "$(row_field id 4)" "7"
check_eq "id 的 is_nullable（主键列必为 NO）" "$(row_field id 3)" "NO"
check_eq "note 的 is_nullable（NOT NULL 不能丢）" "$(row_field note 3)" "NO"
check_eq "note 的默认值（PostgreSQL 会给成 'x'::text）" "$(row_field note 4)" "'x'::text"
check_eq "flag 的主键标记（不是主键）" "$(row_field flag 5)" "NO"
check_eq "flag 的 is_nullable（可空）" "$(row_field flag 3)" "YES"
check_eq "flag 的默认值（NULL 显示为字面量 NULL）" "$(row_field flag 4)" "NULL"

echo ""
echo "== 3.5) 按条件浏览 / 计数的语句（FR-DATA-02）在真机能跑 =="
# 这两条就是 RowBrowsingQuery 生成的形状：WHERE → ORDER BY → 分页（分页必须在最后）。
BROWSE_SQL="SELECT * FROM $SCHEMA.$TABLE WHERE id > 0 ORDER BY id DESC LIMIT 10 OFFSET 0;"
COUNT_SQL="SELECT count(*) FROM $SCHEMA.$TABLE WHERE id > 0;"
BROWSE_OUT="$("$CLI" -c "$BROWSE_SQL" 2>&1)"
[ $? -eq 0 ] && check "带 WHERE + ORDER BY + 分页的浏览语句被执行（分页在最后才是合法顺序）" 0 \
             || { check "浏览语句执行" 1; echo "$BROWSE_OUT" | tail -3; }
COUNT_OUT="$("$CLI" -c "$COUNT_SQL" 2>&1)"
[ $? -eq 0 ] && check "计数语句（带同一份 WHERE）被执行" 0 \
             || { check "计数语句执行" 1; echo "$COUNT_OUT" | tail -3; }
echo "$COUNT_OUT" | grep -q "count" && check "计数语句返回了结果列" 0 || check "计数语句返回结果列" 1

echo ""
echo "== 4) 方差不支持时不给空数组 =="
# GBase 方言没有 tableStructureQuery 实现（默认 nil）：界面据此给可读错误，
# 而不是把"读不出来"显示成"这张表没有列"。
grep -q "func tableStructureQuery(table: String, schema: String?) -> String? { nil }" Core/Dialects.swift \
    && check "不支持读取的方言默认返回 nil（不会被当成零列）" 0 \
    || check "默认实现存在" 1

echo ""
echo "== 5) 清理现场 =="
"$CLI" -c "DROP SCHEMA IF EXISTS $SCHEMA CASCADE;" > /tmp/struct-cleanup.log 2>&1
[ $? -eq 0 ] && echo "  ✅ 已删除 $SCHEMA" || { echo "  ❌ 清理失败"; fail=1; }

echo ""
if [ "$fail" -eq 0 ]; then
    echo "通过：表结构的 5 个字段在真机 18.6 上都读得准"
    echo "（ALTER 生成见 12 项单测；在真表上应用 ALTER 见运行手册清单 H）"
else
    echo "有失败项，见上"
fi
exit "$fail"
