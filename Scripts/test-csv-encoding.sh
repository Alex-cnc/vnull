#!/bin/bash
# 验证：CSV 导出的文本编码（FR-IO-07）—— UTF-8（带 BOM）与 GB18030（中文 Windows）。
#
# 为什么要这么验：编码是**字节层面**的事，而"中文看起来对"在终端里几乎看不出来 ——
# 我的终端是 UTF-8，GB18030 文件在它里面就是乱码，凭肉眼看只会得出错误结论。
# 所以这里把判断交给**另一份实现**（Python 的 `gb18030` / `utf-8-sig` 编解码器）：
#   ① 默认导出带 UTF-8 BOM，且能被 utf-8-sig 完整读回；
#   ② `--encoding gb18030` 无 BOM，能被 gb18030 读回，且「订单一」的字节与 Python
#      用 GBK 码表编出来的**逐字节相同**（不是"我们自己说对"）；
#   ③ emoji（GB18030 的四字节序列）与全角标点都能原样往返；
#   ④ `--fetch-size 1`（每行一次落盘，块边界最多）与一次性导出**逐字节相同**
#      —— 多字节序列若被切在块边界上，这一条就会红；
#   ⑤ 别名 `gbk` 与 `gb18030` 产物一致；
#   ⑥ 三条负例：不认识的编码 / 只对 CSV 生效 / 报错时不留下半个文件；
#   ⑦ 闭环：自己导出的 GB18030 文件，`import` 能读回中文（导入侧解码，附表格式限制说明）。
#
# 环境：本机临时集群（PG 二进制在 ~/tools/pgserver/...，端口 55433）。
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"
PGBIN="$HOME/tools/pgserver/pgserver/pginstall/bin"
DATADIR="$PWD/.build/pgdata-session-test"
PORT=55433
DB="doyah_csv_encoding_check"
STARTED=0

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }
cleanup() { [ "$STARTED" = "1" ] && "$PGBIN/pg_ctl" -D "$DATADIR" stop >/dev/null 2>&1; }
trap cleanup EXIT

echo "== 0) 起实例并造数据（中文 / emoji / 生僻字 / 全角标点 / 引号）=="
if [ ! -f "${DATADIR}/PG_VERSION" ]; then
    mkdir -p "$DATADIR"
    "$PGBIN/initdb" -D "$DATADIR" -U postgres --auth=trust -E UTF8 >/dev/null 2>&1
fi
if ! "$PGBIN/pg_ctl" -D "$DATADIR" status >/dev/null 2>&1; then
    "$PGBIN/pg_ctl" -D "$DATADIR" -o "-p ${PORT} -k /tmp" -l /tmp/doyah-csv-enc-pg.log start >/dev/null 2>&1
    STARTED=1
    sleep 2
fi
export PGHOST=127.0.0.1 PGPORT="$PORT" PGUSER=postgres PGPASSWORD=""
PGDATABASE=postgres "$CLI" -c "DROP DATABASE IF EXISTS ${DB} WITH (FORCE);" >/dev/null 2>&1
PGDATABASE=postgres "$CLI" -c "CREATE DATABASE ${DB};" >/dev/null 2>&1
export PGDATABASE="$DB"
"$CLI" -c "CREATE TABLE csv_check (id integer primary key, name text, note text);
INSERT INTO csv_check VALUES
  (1, '订单一', '中文，含逗号与引号\"x\"'),
  (2, 'emoji 😀 与生僻字 𠀀', NULL),
  (3, 'Order three', '');" >/dev/null 2>&1

QUERY="SELECT id, name, note FROM csv_check ORDER BY id"
UTF8="$(mktemp -t doyah-csv-utf8).csv"
GB="$(mktemp -t doyah-csv-gb).csv"
GB2="$(mktemp -t doyah-csv-gb2).csv"
GBSTREAM="$(mktemp -t doyah-csv-gbstream).csv"

echo ""
echo "== 1) 默认（UTF-8 带 BOM）=="
"$CLI" export --query "$QUERY" --out "$UTF8" > /tmp/doyah-csv-utf8.log 2>&1
check "导出成功（退出码 0）" $?
python3 - "$UTF8" <<'PY' > /tmp/doyah-csv-utf8-verify.txt 2>&1
import sys
raw = open(sys.argv[1], "rb").read()
problems = []
if not raw.startswith(b"\xef\xbb\xbf"):
    problems.append("缺少 UTF-8 BOM")
text = raw.decode("utf-8-sig")
if "订单一" not in text:
    problems.append("中文丢了")
if "emoji 😀" not in text:
    problems.append("emoji 丢了")
if "\r\n" not in text:
    problems.append("行尾不是 CRLF（RFC 4180 要求）")
print("OK" if not problems else "FAIL")
for problem in problems:
    print("  " + problem)
PY
if grep -q "^OK$" /tmp/doyah-csv-utf8-verify.txt; then
    check "UTF-8 BOM + 中文 / emoji / CRLF 经 Python 独立核对" 0
else
    check "UTF-8 BOM + 中文 / emoji / CRLF 经 Python 独立核对" 1
    cat /tmp/doyah-csv-utf8-verify.txt
fi

echo ""
echo "== 2) --encoding gb18030（中文 Windows 的 Excel / WPS）=="
"$CLI" export --query "$QUERY" --out "$GB" --encoding gb18030 > /tmp/doyah-csv-gb.log 2>&1
check "导出成功（退出码 0）" $?
grep -q "文本编码：GB18030" /tmp/doyah-csv-gb.log && check "输出里如实说明了实际编码" 0 || check "输出里如实说明了实际编码" 1
python3 - "$GB" <<'PY' > /tmp/doyah-csv-gb-verify.txt 2>&1
import sys
raw = open(sys.argv[1], "rb").read()
problems = []
if raw.startswith(b"\xef\xbb\xbf"):
    problems.append("GB18030 不该有 UTF-8 BOM")
if raw.startswith(b"\xff\xfe") or raw.startswith(b"\xfe\xff"):
    problems.append("GB18030 不该有 UTF-16 BOM")
# 逐字节对照：用 Python 的 GBK 码表编出同样的字，必须与文件里的字节一致。
expected = "订单一".encode("gbk")
if expected not in raw:
    problems.append(f"「订单一」的字节与 GBK 码表不符（期望 {expected.hex(' ')}）")
text = raw.decode("gb18030")
if "订单一" not in text:
    problems.append("中文解不回来")
if "emoji 😀 与生僻字 𠀀" not in text:
    problems.append("emoji / 生僻字（GB18030 四字节序列）解不回来")
if "，含逗号与引号" not in text:
    problems.append("全角标点解不回来")
# 反向证明这不是 UTF-8：同一份字节按 UTF-8 解会失败或长度不同。
if raw.decode("utf-8", errors="ignore").count("订单一") > 0:
    problems.append("字节同时也是合法 UTF-8 中文？那说明根本没换成 GB18030")
print("OK" if not problems else "FAIL")
for problem in problems:
    print("  " + problem)
PY
if grep -q "^OK$" /tmp/doyah-csv-gb-verify.txt; then
    check "无 BOM + 字节与 GBK 码表一致 + 中文/emoji/生僻字全对（Python 独立核对）" 0
else
    check "无 BOM + 字节与 GBK 码表一致 + 中文/emoji/生僻字全对（Python 独立核对）" 1
    cat /tmp/doyah-csv-gb-verify.txt
fi

echo ""
echo "== 3) 别名与分块一致性 =="
"$CLI" export --query "$QUERY" --out "$GB2" --encoding gbk > /dev/null 2>&1
if cmp -s "$GB" "$GB2"; then check "--encoding gbk 与 gb18030 产物逐字节一致" 0; else check "--encoding gbk 与 gb18030 产物逐字节一致" 1; fi

# 每页 1 行：流式的块边界最多，多字节序列若被切在边界上就会露馅。
"$CLI" export --query "$QUERY" --out "$GBSTREAM" --encoding gb18030 --fetch-size 1 > /tmp/doyah-csv-gbstream.log 2>&1
check "小分页（逐行）导出成功" $?
if cmp -s "$GB" "$GBSTREAM"; then
    check "--fetch-size 1 与一次性导出逐字节一致（GB18030 多字节序列没被切坏）" 0
else
    check "--fetch-size 1 与一次性导出逐字节一致（GB18030 多字节序列没被切坏）" 1
fi

echo ""
echo "== 4) 负例：不认识的编码、非 CSV 格式、别留下半个文件 =="
BAD="$(mktemp -t doyah-csv-bad).csv"; rm -f "$BAD"
"$CLI" export --query "$QUERY" --out "$BAD" --encoding latin1 > /tmp/doyah-csv-bad.log 2>&1
code=$?
check "未知编码被拒（退出码 $code，期望 64）" "$([ "$code" -eq 64 ] && echo 0 || echo 1)"
grep -q "utf8 / gb18030" /tmp/doyah-csv-bad.log && check "错误信息列出了支持的取值" 0 || check "错误信息列出了支持的取值" 1
check "被拒的导出没有写出文件" "$([ -f "$BAD" ] && echo 1 || echo 0)"

"$CLI" export --query "$QUERY" --out /tmp/doyah-csv-bad.json --format json --encoding gb18030 > /tmp/doyah-csv-badjson.log 2>&1
code=$?
check "json + gb18030 被拒（退出码 $code，期望 64）" "$([ "$code" -eq 64 ] && echo 0 || echo 1)"
grep -q "只对 csv 生效" /tmp/doyah-csv-badjson.log && check "并说明原因（只对 csv 生效）" 0 || check "并说明原因（只对 csv 生效）" 1

"$CLI" export --query "$QUERY" --out /tmp/doyah-csv-bad.xlsx --format xlsx --encoding gb18030 > /tmp/doyah-csv-badxlsx.log 2>&1
code=$?
check "xlsx + gb18030 被拒（退出码 $code，期望 64）" "$([ "$code" -eq 64 ] && echo 0 || echo 1)"

echo ""
echo "== 5) 闭环：自己导出的 GB18030 文件，导入侧要能读回 =="
"$CLI" -c "CREATE TABLE csv_roundtrip (id integer, name text, note text);" >/dev/null 2>&1
"$CLI" import --table csv_roundtrip --file "$GB" --write > /tmp/doyah-csv-import.log 2>&1
check "导入成功（退出码 0）" $?
grep -q "文本编码：GB18030" /tmp/doyah-csv-import.log && check "导入侧如实报告了按 GB18030 读取" 0 || check "导入侧如实报告了按 GB18030 读取" 1
"$CLI" export --query "SELECT count(*) AS n, count(*) FILTER (WHERE name = '订单一') AS cn, count(*) FILTER (WHERE name = 'emoji 😀 与生僻字 𠀀') AS emoji FROM csv_roundtrip" --out /tmp/doyah-csv-roundtrip.csv > /dev/null 2>&1
ROUNDTRIP="$(tail -1 /tmp/doyah-csv-roundtrip.csv | tr -d '\r')"
if [ "$ROUNDTRIP" = "3,1,1" ]; then
    check "3 行都回来了，中文与 emoji/生僻字逐字符相等（$ROUNDTRIP）" 0
else
    check "3 行都回来了，中文与 emoji/生僻字逐字符相等（实际 $ROUNDTRIP）" 1
fi

echo ""
echo "== 6) 整库导出也认这个编码 =="
mkdir -p /tmp/doyah-csv-alldir
rm -f /tmp/doyah-csv-alldir/*.csv
"$CLI" export --all-tables --schema public --out-dir /tmp/doyah-csv-alldir --encoding gb18030 > /tmp/doyah-csv-all.log 2>&1
check "整库导出成功（退出码 0）" $?
python3 - /tmp/doyah-csv-alldir/csv_check.csv <<'PY' > /tmp/doyah-csv-all-verify.txt 2>&1
import sys
raw = open(sys.argv[1], "rb").read()
problems = []
if raw.startswith(b"\xef\xbb\xbf"):
    problems.append("整库导出仍写了 UTF-8 BOM（编码没传下去）")
if "订单一" not in raw.decode("gb18030"):
    problems.append("整库导出的中文不是 GB18030")
print("OK" if not problems else "FAIL")
for problem in problems:
    print("  " + problem)
PY
if grep -q "^OK$" /tmp/doyah-csv-all-verify.txt; then
    check "整库导出的每张表也是 GB18030（编码确实传到了逐表路径）" 0
else
    check "整库导出的每张表也是 GB18030（编码确实传到了逐表路径）" 1
    cat /tmp/doyah-csv-all-verify.txt
fi

echo ""
if [ "$fail" -eq 0 ]; then
    echo "全部通过：UTF-8 与 GB18030 两条导出路径的字节都经 Python 独立核对，导入侧能读回。"
    echo "（**边界**：Excel / WPS 双击打开的实际观感仍需人工看一眼 —— 本脚本验的是字节与编码判决；"
    echo "  另：CSV 格式本身无法区分 NULL 与空串，导入时空字段一律成为 NULL，这是格式限制。）"
else
    echo "有失败项，见上"
fi
exit "$fail"
