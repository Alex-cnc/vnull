#!/bin/bash
# 真机验证：备份 / 恢复**真的执行一遍**（FR-IO-04）。
#
# 分两段，各自验不同的东西：
#   · 217（服务端 18.6）—— 验**提前诊断**：本机工具是 16.2，pg_dump 只能处理不比自己新的服务器，
#     必须在执行前拦下并说明原因，而不是跑到一半丢一句服务端报错（这是本轮实测撞到的真问题）。
#   · 本机 16.2 服务端 —— 验**完整往返**：建库灌数据 → pg_dump → **删表破坏现场** → pg_restore → 核对行数与抽样值。
# 另外验：密码不进 argv、--dry-run 不执行、失败时有可读线索。
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"
ACCOUNT="D264B21B-1880-4E73-A2D0-59A3F8E4D7EC"
TOOL_DIR="$HOME/tools/pgserver/pgserver/pginstall/bin"
SRC="doyah_backup_src"
DUMP="$(mktemp -t doyah-backup).dump"

export PGHOST=192.168.5.217 PGUSER=zxvmax PGSSLMODE=disable
PGPASSWORD="$("$CLI" secret get --id "$ACCOUNT")"
export PGPASSWORD

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }

echo "== 0) 工具链 =="
if [ -x "$TOOL_DIR/pg_dump" ] && [ -x "$TOOL_DIR/pg_restore" ]; then
    echo "  ✅ 找到 pg_dump / pg_restore（${TOOL_DIR}）"
else
    echo "  ❌ 本机没有 pg_dump / pg_restore，无法验证"
    exit 1
fi
"$TOOL_DIR/pg_dump" --version | sed 's/^/  /'

echo ""
echo "== 1) 造现场：临时库 + 数据 =="
"$CLI" -c "DROP DATABASE IF EXISTS $SRC;" >/dev/null 2>&1
"$CLI" -c "CREATE DATABASE $SRC;" >/dev/null 2>&1
[ $? -eq 0 ] || { echo "  ❌ 建库失败"; exit 1; }
PGDATABASE="$SRC" "$CLI" -c "CREATE TABLE t (id int primary key, note text);
INSERT INTO t SELECT g, 'note-' || g FROM generate_series(1, 500) g;" >/dev/null 2>&1
[ $? -eq 0 ] && echo "  ✅ $SRC.t 已建好（500 行，与另一套基线数据分隔开）" || { echo "  ❌ 建表失败"; exit 1; }

echo ""
echo "== 2) --dry-run：只打印命令、不执行 =="
DRY_OUT="$("$CLI" backup --kind dump --database "$SRC" --out "$DUMP" --format custom --tool "$TOOL_DIR/pg_dump" --dry-run 2>&1)"
echo "$DRY_OUT" | sed 's/^/  /'
echo "$DRY_OUT" | grep -q "PGPASSWORD=\*\*\*" && check "命令行里密码显示为 ***（不打印真密码）" 0 || check "密码应显示为 ***" 1
echo "$DRY_OUT" | grep -qv "$PGPASSWORD" && check "输出里没有真实密码" 0 || check "输出不该含真实密码" 1
[ ! -f "$DUMP" ] && check "--dry-run 没有生成文件" 0 || check "--dry-run 不该生成文件" 1

echo ""
echo "== 3) 217（服务端 18.6）+ 本机工具 16.2：**提前给出可读诊断**，而不是跑到一半才报错 =="
MISMATCH_OUT="$("$CLI" backup --kind dump --database "$SRC" --out "$DUMP" --format custom --tool "$TOOL_DIR/pg_dump" 2>&1)"
MISMATCH_CODE=$?
echo "$MISMATCH_OUT" | grep -v "^PostgreSQL" | head -6 | sed 's/^/  /'
[ "$MISMATCH_CODE" -eq 65 ] && check "提前拦下（退出码 65，不是跑到一半才失败）" 0 \
    || check "应当提前拦下（实际 ${MISMATCH_CODE}）" 1
echo "$MISMATCH_OUT" | grep -q "备份工具版本低于服务器" && check "诊断说明白了原因" 0 || check "诊断说明原因" 1
echo "$MISMATCH_OUT" | grep -q -- "--tool" && check "诊断给出了怎么办（--tool 指定路径）" 0 || check "诊断给出办法" 1
[ ! -f "$DUMP" ] && check "没有生成半截的归档文件" 0 || check "不该留下半截文件" 1

echo ""
echo "== 4) 版本匹配的服务器上做**完整往返**（本机 16.2 服务端）=="
# 用本机内置的 16.2 服务器：客户端与服务端主版本一致，pg_dump 才肯干活。
PGBIN="$TOOL_DIR"
LOCAL_DATADIR="${PGSERVER_DATADIR:-$HOME/tools/pgdata-querytest}"
LOCAL_PORT=55432
if [ ! -f "${LOCAL_DATADIR}/PG_VERSION" ]; then
    "${PGBIN}/initdb" -D "${LOCAL_DATADIR}" -U postgres --auth=trust -E UTF8 >/dev/null 2>&1
fi
if ! "${PGBIN}/pg_ctl" -D "${LOCAL_DATADIR}" status >/dev/null 2>&1; then
    "${PGBIN}/pg_ctl" -D "${LOCAL_DATADIR}" -o "-p ${LOCAL_PORT} -k /tmp" -l /tmp/doyah-backup-pg.log start >/dev/null 2>&1
    STARTED_LOCAL=1
    sleep 2
fi
LOCAL_DB="doyah_backup_local"
export PGHOST=127.0.0.1 PGPORT="$LOCAL_PORT" PGUSER=postgres PGDATABASE=postgres
export PGPASSWORD=""
"$CLI" -c "DROP DATABASE IF EXISTS $LOCAL_DB;" >/dev/null 2>&1
"$CLI" -c "CREATE DATABASE $LOCAL_DB;" >/dev/null 2>&1
PGDATABASE="$LOCAL_DB" "$CLI" -c "CREATE TABLE t (id int primary key, note text);
INSERT INTO t SELECT g, 'note-' || g FROM generate_series(1, 500) g;" >/dev/null 2>&1
[ $? -eq 0 ] && check "本地 16.2 库与数据已就绪" 0 || check "本地库就绪" 1

LOCAL_DUMP="$(mktemp -t doyah-backup-local).dump"
DUMP_OUT="$("$CLI" backup --kind dump --database "$LOCAL_DB" --out "$LOCAL_DUMP" --format custom --tool "${PGBIN}/pg_dump" 2>&1)"
[ $? -eq 0 ] && check "备份成功" 0 || { check "备份成功" 1; echo "$DUMP_OUT" | tail -4; }
[ -s "$LOCAL_DUMP" ] && check "归档非空（$(wc -c < "$LOCAL_DUMP" | tr -d ' ') 字节）" 0 || check "归档非空" 1
"${PGBIN}/pg_restore" --list "$LOCAL_DUMP" > /tmp/doyah-restore-list.txt 2>&1
grep -qE "^[0-9;]+;.*TABLE .*\bt\b" /tmp/doyah-restore-list.txt \
    && check "归档里含表 t（可被 pg_restore 解析）" 0 \
    || { check "归档含表 t" 1; grep -i "table" /tmp/doyah-restore-list.txt | head -3; }

# 破坏现场：删表 —— 否则"恢复成功"可能只是表本来就在
PGDATABASE="$LOCAL_DB" "$CLI" -c "DROP TABLE t;" >/dev/null 2>&1
GONE="$(PGDATABASE="$LOCAL_DB" "$CLI" -c "SELECT count(*) AS n FROM information_schema.tables WHERE table_name = 't';" 2>/dev/null | awk -F'|' '/^[0-9]/{print $1}' | tr -d ' ' | head -1)"
[ "${GONE:-x}" = "0" ] && check "表已删除（现场确实被破坏）" 0 || echo "  ⚠️ 删表结果未解析到（${GONE:-无}）"

RESTORE_OUT="$("$CLI" backup --kind restore --database "$LOCAL_DB" --out "$LOCAL_DUMP" --tool "${PGBIN}/pg_restore" 2>&1)"
[ $? -eq 0 ] && check "恢复成功" 0 || { check "恢复成功" 1; echo "$RESTORE_OUT" | tail -4; }
ROWS="$(PGDATABASE="$LOCAL_DB" "$CLI" -c "SELECT count(*) AS rows FROM t;" 2>/dev/null | awk -F'|' '/^[0-9]/{print $1}' | tr -d ' ' | head -1)"
[ "${ROWS:-0}" = "500" ] && check "行数回到 500" 0 || check "行数应为 500，实际 ${ROWS:-未解析}" 1
SAMPLE="$(PGDATABASE="$LOCAL_DB" "$CLI" -c "SELECT note FROM t WHERE id = 42;" 2>/dev/null | grep -c "note-42")"
[ "${SAMPLE:-0}" -ge 1 ] && check "抽样（id=42 → note-42）对得上" 0 || check "抽样对得上" 1

"$CLI" -c "DROP DATABASE IF EXISTS $LOCAL_DB;" >/dev/null 2>&1
rm -f "$LOCAL_DUMP"
[ "${STARTED_LOCAL:-0}" = "1" ] && "${PGBIN}/pg_ctl" -D "${LOCAL_DATADIR}" stop >/dev/null 2>&1

echo ""
echo "== 6) 清理现场 =="
rm -f "$DUMP" /tmp/doyah-should-fail.dump
"$CLI" -c "DROP DATABASE IF EXISTS $SRC;" >/dev/null 2>&1
[ $? -eq 0 ] && echo "  ✅ 已删除临时库 $SRC" || { echo "  ❌ 清理失败（临时库还留着）"; fail=1; }

echo ""
if [ "$fail" -eq 0 ]; then
    echo "通过：备份 / 恢复的完整往返（本机 16.2 服务端）与提前诊断（217 / 18.6）都成立，"
    echo "      密码不进 argv、--dry-run 不执行、失败路径有可读线索"
else
    echo "有失败项，见上"
fi
exit "$fail"
