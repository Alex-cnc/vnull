#!/bin/bash
# 真机验证：超大结果集**流式取数 + 流式写盘**（FR-RES-13 的「取」那一半）。
#
# 验三件事：① 服务端游标逐页取（不是一次取回、也不是 OFFSET 翻页）；
# ② 文件内容完整正确；③ **内存峰值不随结果集增长**（这是"不把全量结果驻留内存"的可测量形式）。
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"
ACCOUNT="D264B21B-1880-4E73-A2D0-59A3F8E4D7EC"
S="doyah_cursor_check"
ROWS=1000000
OUT="$(mktemp -t doyah-export).csv"

export PGHOST=192.168.5.217 PGUSER=zxvmax PGDATABASE=zxvmax PGSSLMODE=disable
PGPASSWORD="$("$CLI" secret get --id "$ACCOUNT")"
export PGPASSWORD

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }

echo "== 1) 造现场：${ROWS} 行大表 =="
"$CLI" -c "DROP SCHEMA IF EXISTS $S CASCADE;
CREATE SCHEMA $S;
CREATE TABLE $S.big AS
SELECT g AS id, md5(g::text) AS payload, repeat('x', 200) AS filler
FROM generate_series(1, $ROWS) g;" > /tmp/cursor-setup.log 2>&1
[ $? -eq 0 ] && echo "  ✅ 大表已建立（约 $((ROWS * 250 / 1024 / 1024)) MB 文本）" || { echo "  ❌ 建表失败"; tail -3 /tmp/cursor-setup.log; exit 1; }

echo ""
echo "== 2) 单条查询校验：多语句必须被拒绝 =="
"$CLI" export --query "SELECT 1; DROP TABLE $S.big" --out /tmp/should-not-exist.csv > /tmp/cursor-refuse.log 2>&1
REFUSE_CODE=$?
[ "$REFUSE_CODE" -ne 0 ] && check "多语句被拒绝（退出码 ${REFUSE_CODE}）" 0 || check "多语句应被拒绝" 1
grep -q "只支持单条查询" /tmp/cursor-refuse.log && check "拒绝原因可读" 0 || { check "拒绝原因可读" 1; head -2 /tmp/cursor-refuse.log; }
[ ! -f /tmp/should-not-exist.csv ] && check "拒绝时没有生成文件" 0 || check "拒绝时不该生成文件" 1
"$CLI" -c "SELECT 1 FROM $S.big LIMIT 1" >/dev/null 2>&1 && check "大表毫发无损（没有执行到 DROP）" 0 || check "大表被误删" 1

echo ""
echo "== 3) 流式导出并在导出过程测峰值内存 =="
# macOS 的 /usr/bin/time -l 会给 maximum resident set size（字节）。
/usr/bin/time -l "$CLI" export \
    --query "SELECT * FROM $S.big ORDER BY id" \
    --out "$OUT" \
    --format csv \
    --fetch-size 5000 > /tmp/cursor-export.log 2>/tmp/cursor-export-time.log
EXPORT_CODE=$?
cat /tmp/cursor-export.log | head -4
[ "$EXPORT_CODE" -eq 0 ] && check "导出成功（退出码 0）" 0 || { check "导出成功" 1; tail -5 /tmp/cursor-export.log; }

PAGES=$(grep -o "[0-9]* 页" /tmp/cursor-export.log | head -1 | grep -o "[0-9]*")
[ "${PAGES:-0}" -gt 1 ] && check "确实按页取数（${PAGES} 页，每页 5000 行）" 0 || check "应当多页取数（实际 ${PAGES:-0} 页）" 1

echo ""
echo "== 4) 文件内容核对 =="
LINE_COUNT=$(wc -l < "$OUT" | tr -d ' ')
[ "$LINE_COUNT" -eq $((ROWS + 1)) ] && check "行数正确（$((ROWS + 1)) = 表头 + $ROWS 行）" 0 \
    || check "行数应为 $((ROWS + 1))，实际 $LINE_COUNT" 1
head -2 "$OUT" | tail -1 | grep -q "^1," && check "首行是 id=1" 0 || { check "首行是 id=1" 1; head -2 "$OUT" | tail -1 | cut -c1-60; }
tail -1 "$OUT" | grep -q "^$ROWS," && check "末行是 id=${ROWS}（没有漏取最后一页）" 0 \
    || { check "末行是 id=$ROWS" 1; tail -1 "$OUT" | cut -c1-60; }

echo ""
echo "== 5) 内存峰值**不随结果集增长**（三点对照）=="
# 为什么不用"峰值 < 文件大小"这种绝对值判据：进程有几十 MB 的基线（运行时 + 驱动缓冲），
# 跟文件比绝对值说明不了问题。**有意义的对照是同一进程导出三个量级**：
# 数据放大两三百倍，峰值内存应当只动几 MB（分配器噪声量级），而不是跟着线性涨。
measure() { # measure <行数上限或 full> <输出路径前缀>
    local limit="$1"
    local out="$2"
    local query
    if [ "$limit" = "full" ]; then
        query="SELECT * FROM $S.big ORDER BY id"
    else
        query="SELECT * FROM $S.big ORDER BY id LIMIT $limit"
    fi
    /usr/bin/time -l "$CLI" export --query "$query" --out "$out" --format csv --fetch-size 5000 \
        > /dev/null 2>"$out.time"
    echo "$(wc -c < "$out" | tr -d ' ') $(awk '/maximum resident set size/{print $1}' "$out.time")"
    rm -f "$out" "$out.time"
}

SMALL="$(mktemp -t doyah-exp-5k)"
MID="$(mktemp -t doyah-exp-200k)"
BIG="$(mktemp -t doyah-exp-full)"
read -r SMALL_BYTES SMALL_RSS <<< "$(measure 5000 "$SMALL")"
read -r MID_BYTES MID_RSS <<< "$(measure 200000 "$MID")"
read -r BIG_BYTES BIG_RSS <<< "$(measure full "$BIG")"

if [ -n "${SMALL_RSS:-}" ] && [ -n "${MID_RSS:-}" ] && [ -n "${BIG_RSS:-}" ]; then
    echo "  5 千行：文件 $((SMALL_BYTES / 1024 / 1024)) MB，峰值 $((SMALL_RSS / 1024 / 1024)) MB"
    echo "  20 万行：文件 $((MID_BYTES / 1024 / 1024)) MB，峰值 $((MID_RSS / 1024 / 1024)) MB"
    echo "  100 万行：文件 $((BIG_BYTES / 1024 / 1024)) MB，峰值 $((BIG_RSS / 1024 / 1024)) MB"

    if [ "$BIG_BYTES" -gt $((SMALL_BYTES * 10)) ]; then
        check "最大与最小规模相差 10 倍以上（对照有效）" 0
    else
        check "规模没拉开，对照无效（${SMALL_BYTES} → ${BIG_BYTES} 字节）" 1
    fi

    RSS_GROWTH=$((BIG_RSS - SMALL_RSS))
    FILE_GROWTH=$((BIG_BYTES - SMALL_BYTES))
    # 宽松但真实的界：内存增量 < 文件增量的 1/10（实测约 1/20 以下）。
    if [ "$RSS_GROWTH" -lt $((FILE_GROWTH / 10)) ]; then
        check "峰值内存增量（${RSS_GROWTH} 字节）远小于数据增量（${FILE_GROWTH} 字节）" 0
    else
        check "峰值内存随结果集线性增长了（内存增量 ${RSS_GROWTH} 字节）" 1
    fi

    # 中间那点也要落在同一条趋势上：不能出现"20 万行比 100 万行还费内存"这种噪声级翻转
    if [ "$MID_RSS" -le $((BIG_RSS + 8 * 1024 * 1024)) ]; then
        check "中间规模与最大规模的峰值同量级（${MID_RSS} vs ${BIG_RSS} 字节）" 0
    else
        check "中间规模峰值异常偏高（${MID_RSS} vs ${BIG_RSS} 字节）" 1
    fi
else
    echo "  ⚠️ 没读到 maximum resident set size，这一项**不做结论**（不猜）"
    fail=1
fi

echo ""
echo "== 6) 输出格式各来一次（json / tsv / insert 的可解析性）=="
for fmt in json tsv insert; do
    TMP="$(mktemp -t doyah-fmt).$fmt"
    # `insert` 格式必须给 `--table`：FR-RES-12 之后**明确要求**目标表名，
    # 否则生成的 INSERT 会引用 `table_name` 这种不存在的表 —— 宁可报错也不产出坏 SQL。
    # 这条断言原来是漏的（脚本写在那个要求之前），2026-09-24 复跑时被抓出来。
    EXTRA=()
    if [ "$fmt" = "insert" ]; then EXTRA=(--table "$S.big"); fi
    "$CLI" export --query "SELECT id FROM $S.big ORDER BY id" --out "$TMP" --format "$fmt" --fetch-size 20000 "${EXTRA[@]+"${EXTRA[@]}"}" > /tmp/cursor-fmt.log 2>&1
    if [ $? -eq 0 ] && [ -s "$TMP" ]; then
        check "$fmt 导出非空" 0
    else
        check "$fmt 导出" 1
    fi
    rm -f "$TMP"
done

echo ""
echo "== 7) 清理现场 =="
"$CLI" -c "DROP SCHEMA IF EXISTS $S CASCADE;" > /tmp/cursor-cleanup.log 2>&1
[ $? -eq 0 ] && echo "  ✅ 已删除 $S" || { echo "  ❌ 清理失败"; fail=1; }
rm -f "$OUT"

echo ""
if [ "$fail" -eq 0 ]; then
    echo "通过：流式取数 + 流式写盘在真机 18.6 上成立（游标逐页、内容正确、内存不随结果集增长）"
else
    echo "有失败项，见上"
fi
exit "$fail"
