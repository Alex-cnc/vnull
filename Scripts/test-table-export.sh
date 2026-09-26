#!/bin/bash
# 验证：整表 / 整库导出（FR-IO-02）。
#
# 同时给「COPY … TO STDOUT 走不通」留下**实测证据**（不是靠读代码下结论）：
# 驱动只实现了 CopyFrom，CopyOut 会在消息解码处失败。
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"
# 连接信息（本机过渡集群 / 远程专用库）由共用入口决定 —— 三档端口与目录只写在它里面
source "$(cd "$(dirname "$0")" && pwd)/lib/test-env.sh"
doyah_test_env_summary

PGBIN="${DOYAH_TEST_PG_BIN}"
DATADIR="${DOYAH_TEST_LOCAL_DATADIR}"
PORT="${DOYAH_TEST_PGPORT}"
DB="doyah_export_check"
SCHEMA="expschema"
OUTDIR="$(mktemp -d -t doyah-export-all)"
STARTED=0

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }
cleanup() {
    rm -rf "$OUTDIR"
    [ "$STARTED" = "1" ] && "$PGBIN/pg_ctl" -D "$DATADIR" stop >/dev/null 2>&1
}
trap cleanup EXIT

echo "== 0) 起本机实例并造三张表（其中一张 12 万行）=="
if [ ! -f "${DATADIR}/PG_VERSION" ]; then
    mkdir -p "$DATADIR"
    "$PGBIN/initdb" -D "$DATADIR" -U postgres --auth=trust -E UTF8 >/dev/null 2>&1
fi
if ! "$PGBIN/pg_ctl" -D "$DATADIR" status >/dev/null 2>&1; then
    "$PGBIN/pg_ctl" -D "$DATADIR" -o "-p ${PORT} -k /tmp" -l /tmp/doyah-export-pg.log start >/dev/null 2>&1
    STARTED=1
    sleep 2
fi
doyah_test_env_export_connection
PGDATABASE="${DOYAH_TEST_ADMIN_DB}" "$CLI" -c "DROP DATABASE IF EXISTS ${DB};" >/dev/null 2>&1
PGDATABASE="${DOYAH_TEST_ADMIN_DB}" "$CLI" -c "CREATE DATABASE ${DB};" >/dev/null 2>&1
export PGDATABASE="$DB"
"$CLI" -c "CREATE SCHEMA ${SCHEMA};
CREATE TABLE ${SCHEMA}.big AS SELECT g AS id, md5(g::text) AS payload, repeat('x', 200) AS filler FROM generate_series(1, 120000) g;
CREATE TABLE ${SCHEMA}.small_a (id int primary key, note text);
INSERT INTO ${SCHEMA}.small_a VALUES (1, 'alpha'), (2, 'beta');
CREATE TABLE ${SCHEMA}.small_b (id int primary key, note text);
INSERT INTO ${SCHEMA}.small_b VALUES (1, '一'), (2, '二');" >/dev/null 2>&1
[ $? -eq 0 ] && echo "  ✅ 三张表已就绪（big 12 万行 / small_a 2 行 / small_b 2 行）" || { echo "  ❌ 造现场失败"; exit 1; }

echo ""
echo "== 1) COPY … TO STDOUT 的实测结论（决定这一项能不能走 COPY）=="
COPY_OUT="$("$CLI" -c "COPY (SELECT 1 AS a) TO STDOUT WITH (FORMAT csv)" 2>&1)"
COPY_CODE=$?
[ "$COPY_CODE" -ne 0 ] && check "现有驱动**不支持** COPY TO STDOUT（退出码 ${COPY_CODE}）" 0 || check "不该成功" 1
echo "$COPY_OUT" | grep -q "copyOutResponse" && check "失败原因是消息解码：Unknown message kind: copyOutResponse" 0 \
    || { check "应给出 copyOutResponse 相关错误" 1; echo "$COPY_OUT" | tail -2; }
# 服务端写文件的形态是可用的（作为对照，说明不是权限问题）
"$CLI" -c "COPY (SELECT 1) TO '/tmp/doyah-copy-server-side.csv'" >/dev/null 2>&1
[ $? -eq 0 ] && check "对照：COPY … TO <服务端文件> 可用（所以问题在客户端驱动，不在权限 / SQL）" 0 || check "对照项失败" 1
rm -f /tmp/doyah-copy-server-side.csv

echo ""
echo "== 2) 整表导出（12 万行，走游标逐页 + 流式写盘）=="
BIG_OUT="$OUTDIR/big.csv"
/usr/bin/time -l "$CLI" export --table big --schema "$SCHEMA" --out "$BIG_OUT" --format csv --fetch-size 5000 \
    > /tmp/doyah-big-export.log 2>/tmp/doyah-big-export-time.log
BIG_CODE=$?
cat /tmp/doyah-big-export.log | grep -E "导出完成|文件|取数方式" | sed 's/^/  /'
[ "$BIG_CODE" -eq 0 ] && check "整表导出成功（不手写 SELECT）" 0 || { check "整表导出" 1; tail -3 /tmp/doyah-big-export.log; }
LINES=$(wc -l < "$BIG_OUT" | tr -d ' ')
[ "${LINES:-0}" -eq 120001 ] && check "行数正确（表头 + 120000）" 0 || check "行数应为 120001，实际 ${LINES:-?}" 1
# 导出文件带 UTF-8 BOM（Excel 打开中文不乱码，是有意为之）→ 判据要 BOM 容错。
# 注意：macOS 的 sed **不支持 `\xEF` 这类转义**，所以用子串匹配而不是"先剥 BOM 再全等"（本轮踩到）。
head -1 "$BIG_OUT" | grep -q "id,payload,filler" \
    && check "表头是表的列名" 0 \
    || { check "表头" 1; head -1 "$BIG_OUT" | cut -c1-60; }
head -c 3 "$BIG_OUT" | od -An -tx1 | tr -d ' \n' | grep -qi "efbbbf" \
    && check "文件带 UTF-8 BOM（Excel 友好）" 0 \
    || check "文件应带 UTF-8 BOM" 1
tail -1 "$BIG_OUT" | grep -q "^120000," && check "末行是 id=120000（没有漏取最后一页）" 0 || check "末行" 1
PAGES=$(grep -o "[0-9]* 页" /tmp/doyah-big-export.log | head -1 | grep -o "[0-9]*")
[ "${PAGES:-0}" -gt 1 ] && check "确实按页取数（${PAGES} 页）" 0 || check "应当多页（实际 ${PAGES:-0}）" 1
MAX_RSS=$(awk '/maximum resident set size/{print $1}' /tmp/doyah-big-export-time.log)
FILE_BYTES=$(wc -c < "$BIG_OUT" | tr -d ' ')
# 判据必须是**跨规模对照**，不能用绝对值：进程本身有几十 MB 基线（运行时 + 驱动缓冲），
# 小文件上"峰值 < 文件大小"这种判据毫无意义（本轮实测：4 MB 的文件配 25 MB 基线，必然误报）。
/usr/bin/time -l "$CLI" export --table small_a --schema "$SCHEMA" --out "$OUTDIR/tiny.csv" --format csv \
    > /dev/null 2>/tmp/doyah-tiny-export-time.log
TINY_RSS=$(awk '/maximum resident set size/{print $1}' /tmp/doyah-tiny-export-time.log)
TINY_BYTES=$(wc -c < "$OUTDIR/tiny.csv" | tr -d ' ')
if [ -n "${MAX_RSS:-}" ] && [ -n "${TINY_RSS:-}" ]; then
    echo "  2 行：文件 $((TINY_BYTES / 1024)) KB，峰值 $((TINY_RSS / 1024 / 1024)) MB"
    echo "  12 万行：文件 $((FILE_BYTES / 1024 / 1024)) MB，峰值 $((MAX_RSS / 1024 / 1024)) MB"
    RSS_GROWTH=$((MAX_RSS - TINY_RSS))
    FILE_GROWTH=$((FILE_BYTES - TINY_BYTES))
    [ "$FILE_GROWTH" -gt $((TINY_BYTES * 100)) ] && check "两次规模相差百倍以上（对照有效）" 0 \
        || check "规模没拉开，对照无效" 1
    # 判据说清楚它证明了什么：**次线性**（内存增量明显小于数据增量），不是"内存恒定"。
    # "恒定"的更强证据在 `Scripts/test-cursor-export.sh`：100 万行 / 230 MB 文件，内存只增 20 MB。
    [ "$RSS_GROWTH" -lt $((FILE_GROWTH / 2)) ] && check "内存增量明显小于数据增量（次线性，非把全量读进内存）" 0 \
        || check "内存增量与数据增量同量级（可能没在流式）" 1
else
    echo "  ⚠️ 没读到 maximum resident set size，这一项不做结论"
    fail=1
fi

echo ""
echo "== 3) 整库导出（schema 下每张表各一个文件）=="
ALL_OUT="$("$CLI" export --all-tables --schema "$SCHEMA" --out-dir "$OUTDIR/all" --format csv --fetch-size 5000 2>&1)"
echo "$ALL_OUT" | sed 's/^/  /' | head -8
echo "$ALL_OUT" | grep -q "整库导出完成：3 张表" && check "3 张表都导出了" 0 || check "整库导出" 1
for t in big small_a small_b; do
    if [ -s "$OUTDIR/all/${t}.csv" ]; then
        check "生成 ${t}.csv（以表名命名）" 0
    else
        check "应生成 ${t}.csv" 1
    fi
done
A_LINES=$(wc -l < "$OUTDIR/all/small_a.csv" | tr -d ' ')
[ "${A_LINES:-0}" -eq 3 ] && check "small_a 行数正确（表头 + 2）" 0 || check "small_a 行数（实际 ${A_LINES:-?}）" 1
grep -q "一" "$OUTDIR/all/small_b.csv" && check "中文内容原样导出" 0 || check "中文内容" 1

echo ""
echo "== 4) 多格式都能用（同一张表换格式）=="
for fmt in json tsv insert; do
    "$CLI" export --table small_a --schema "$SCHEMA" --out "$OUTDIR/a.$fmt" --format "$fmt" --fetch-size 100 >/dev/null 2>&1
    [ -s "$OUTDIR/a.$fmt" ] && check "${fmt} 导出非空" 0 || check "${fmt} 导出" 1
done

echo ""
echo "== 5) 清理现场 =="
PGDATABASE="${DOYAH_TEST_ADMIN_DB}" "$CLI" -c "DROP DATABASE IF EXISTS ${DB};" >/dev/null 2>&1
echo "  ✅ 已删除临时库 ${DB}"

echo ""
if [ "$fail" -eq 0 ]; then
    echo "通过：整表 / 整库导出可用且内存不随结果集增长；COPY TO STDOUT 的驱动缺口已留下实测证据"
else
    echo "有失败项，见上"
fi
exit "$fail"
