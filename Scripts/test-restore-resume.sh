#!/bin/bash
# 验证：备份恢复到指定库与失败续跑（FR-IO-05）。
#
# 这一项的关键不是"能跑 pg_restore"，而是**恢复到指定库**、**分段**、
# 以及**失败后能接着做**：脚本造一个真实的失败（把 data 段单独恢复到空库），
# 断言它停下并给出可直接粘的续跑命令，然后按建议把剩下的做完。
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"
PGBIN="$HOME/tools/pgserver/pgserver/pginstall/bin"
DATADIR="$PWD/.build/pgdata-session-test"
PORT=55433
SRC_DB="doyah_restore_src"
DST_DB="doyah_restore_dst"
RETRY_DB="doyah_restore_retry"
ARCHIVE="$PWD/.build/restore-check.dump"
STARTED=0

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }
cleanup() { [ "$STARTED" = "1" ] && "$PGBIN/pg_ctl" -D "$DATADIR" stop >/dev/null 2>&1; rm -f "$ARCHIVE"; }
trap cleanup EXIT

scalar() {
    PGDATABASE="$1" "$CLI" -c "$2" 2>/dev/null | awk '
        /^--- statement 1 ---/ { seen = 1; next }
        seen && /^finished:/ { exit }
        seen { if (header == "") { header = $0 } else { print $0; exit } }'
}

echo "== 0) 起实例：源库有数据，目标库是空的 =="
if [ ! -f "${DATADIR}/PG_VERSION" ]; then
    mkdir -p "$DATADIR"
    "$PGBIN/initdb" -D "$DATADIR" -U postgres --auth=trust -E UTF8 >/dev/null 2>&1
fi
if ! "$PGBIN/pg_ctl" -D "$DATADIR" status >/dev/null 2>&1; then
    "$PGBIN/pg_ctl" -D "$DATADIR" -o "-p ${PORT} -k /tmp" -l /tmp/doyah-restore-pg.log start >/dev/null 2>&1
    STARTED=1
    sleep 2
fi
export PGHOST=127.0.0.1 PGPORT="$PORT" PGUSER=postgres PGPASSWORD=""
for db in "$SRC_DB" "$DST_DB" "$RETRY_DB"; do
    PGDATABASE=postgres "$CLI" -c "DROP DATABASE IF EXISTS ${db} WITH (FORCE);" >/dev/null 2>&1
    PGDATABASE=postgres "$CLI" -c "CREATE DATABASE ${db};" >/dev/null 2>&1
done
PGDATABASE="$SRC_DB" "$CLI" -c "CREATE TABLE items (id integer primary key, note text);
INSERT INTO items VALUES (1, 'a'), (2, 'b'), (3, 'c');" >/dev/null 2>&1
SRC_COUNT="$(scalar "$SRC_DB" "SELECT count(*) FROM items;" | tr -dc '0-9')"
[ "$SRC_COUNT" = "3" ] && check "源库已就绪（3 行）" 0 || { check "源库准备（实际 $SRC_COUNT）" 1; exit 1; }

echo ""
echo "== 1) 备份成自定义格式（pg_restore 只能吃自定义 / 目录格式）=="
PGDATABASE=postgres "$CLI" backup --kind dump --format custom --out "$ARCHIVE" \
    --tool "$PGBIN/pg_dump" --database "$SRC_DB" --no-version-check >/dev/null 2>&1
[ -f "$ARCHIVE" ] && check "归档文件已生成" 0 || { check "应生成归档" 1; exit 1; }

echo ""
echo "== 2) 逐段恢复到**指定库** → 数据应完整 =="
RESTORE="$(PGDATABASE=postgres "$CLI" backup --kind restore --out "$ARCHIVE" --database "$DST_DB" \
    --restore-sections --tool "$PGBIN/pg_restore" --no-version-check 2>&1)"
echo "$RESTORE" | grep -E "^==>|三段全部完成" | sed 's/^/  /'
echo "$RESTORE" | grep -q "结构（pre-data）" && echo "$RESTORE" | grep -q "数据（data）" \
    && echo "$RESTORE" | grep -q "索引与约束（post-data）" && check "三段按依赖顺序都跑了" 0 || check "三段应都跑" 1
COUNT="$(scalar "$DST_DB" "SELECT count(*) FROM items;" | tr -dc '0-9')"
[ "$COUNT" = "3" ] && check "目标库数据完整（3 行，恢复到指定库）" 0 || { check "恢复后应有 3 行（实际 $COUNT）" 1; }

echo ""
echo "== 3) 造一个真实的失败：把 data 段单独恢复到**空库**（没有表，必然失败）=="
FAILED="$(PGDATABASE=postgres "$CLI" backup --kind restore --out "$ARCHIVE" --database "$RETRY_DB" \
    --section data --fail-fast --tool "$PGBIN/pg_restore" --no-version-check 2>&1)"; CODE=$?
echo "$FAILED" | tail -4 | sed 's/^/  /'
[ "$CODE" -ne 0 ] && check "失败时返回非零（不假装成功）" 0 || check "应返回非零" 1
# 空库上单独恢复 data：表不存在，数据没进去
LEFTOVER="$(scalar "$RETRY_DB" "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';" | tr -dc '0-9')"
[ "$LEFTOVER" = "0" ] && check "失败后目标库确实还是空的（没有半截结构）" 0 || check "失败后应为空库" 1

echo ""
echo "== 4) 失败续跑：按建议从 pre-data 起逐段做完 =="
RESUME="$(PGDATABASE=postgres "$CLI" backup --kind restore --out "$ARCHIVE" --database "$RETRY_DB" \
    --restore-sections --tool "$PGBIN/pg_restore" --no-version-check 2>&1)"
echo "$RESUME" | grep -q "三段全部完成" && check "续跑把三段做完" 0 || { check "续跑应完成" 1; echo "$RESUME" | tail -4; }
RESUME_COUNT="$(scalar "$RETRY_DB" "SELECT count(*) FROM items;" | tr -dc '0-9')"
[ "$RESUME_COUNT" = "3" ] && check "续跑后数据完整（3 行）" 0 || { check "续跑后应有 3 行（实际 $RESUME_COUNT）" 1; }

echo ""
echo "== 5) 逐段模式下的失败：必须**打印可直接粘的续跑命令** =="
# 造一个"结构与归档冲突"的场景：目标库里已有一张同名表 → pre-data 段的 CREATE TABLE 会失败
PGDATABASE=postgres "$CLI" -c "DROP DATABASE IF EXISTS doyah_restore_conflict WITH (FORCE);" >/dev/null 2>&1
PGDATABASE=postgres "$CLI" -c "CREATE DATABASE doyah_restore_conflict;" >/dev/null 2>&1
PGDATABASE=doyah_restore_conflict "$CLI" -c "CREATE TABLE items (other text);" >/dev/null 2>&1
HINT="$(PGDATABASE=postgres "$CLI" backup --kind restore --out "$ARCHIVE" --database doyah_restore_conflict \
    --restore-sections --tool "$PGBIN/pg_restore" --no-version-check 2>&1)"; HINT_CODE=$?
echo "$HINT" | grep -A2 "下一步：" | sed 's/^/  /'
[ "$HINT_CODE" -ne 0 ] && check "冲突时返回非零" 0 || check "冲突时应返回非零" 1
echo "$HINT" | grep -q "下一步：" && check "打印了续跑建议" 0 || check "应打印续跑建议" 1
echo "$HINT" | grep -q -- "--section pre-data" && check "续跑命令指出从 pre-data 段起" 0 || check "续跑命令应指定段" 1
echo "$HINT" | grep -q -- "--fail-fast" && check "续跑命令带 --fail-fast（否则不知道停在哪一段）" 0 || check "续跑命令应带 --fail-fast" 1

echo ""
if [ "$fail" -eq 0 ]; then
    echo "通过：自定义格式备份 / 逐段恢复到指定库且数据完整 / 失败时停下且不留半截 / 续跑能把剩下的做完"
    echo "（**边界**：界面里的恢复入口仍需人工点；本脚本验的是命令行恢复与分段续跑）"
else
    echo "有失败项，见上"
fi
exit "$fail"
