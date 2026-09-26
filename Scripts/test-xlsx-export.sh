#!/bin/bash
# 验证：结果集导出 Excel（FR-RES-14）。
#
# 为什么要这么验：xlsx 的产物是**二进制 ZIP + OOXML**，"我们自己说写对了"不算数。
# 所以这里用**另一份实现**（Python 的 zipfile + ElementTree）把产物拆开核对：
#   ① ZIP 本身能被标准库完整读出（`testzip()` 通过 = 每个条目的 CRC 都对）
#   ② 六个部件齐全，且 XML 都能解析
#   ③ 表头 / 数据行 / 中文 / 空值 / 数字与文本的类型都对
#   ④ 同样输入两次导出**逐字节一致**（时间戳固定）
#
# 环境：真库连接信息由 `Scripts/lib/test-env.sh` 决定（过渡期默认本机临时集群，档位见该文件的档位表）。
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"
# 连接信息（本机过渡集群 / 远程专用库）由共用入口决定 —— 三档端口与目录只写在它里面
source "$(cd "$(dirname "$0")" && pwd)/lib/test-env.sh"
doyah_test_env_summary

PGBIN="${DOYAH_TEST_PG_BIN}"
DATADIR="${DOYAH_TEST_LOCAL_DATADIR}"
PORT="${DOYAH_TEST_PGPORT}"
DB="doyah_xlsx_check"
STARTED=0

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }
cleanup() { [ "$STARTED" = "1" ] && "$PGBIN/pg_ctl" -D "$DATADIR" stop >/dev/null 2>&1; }
trap cleanup EXIT

echo "== 0) 起实例并造数据（含中文、空值、数字、前导零）=="
if [ ! -f "${DATADIR}/PG_VERSION" ]; then
    mkdir -p "$DATADIR"
    "$PGBIN/initdb" -D "$DATADIR" -U postgres --auth=trust -E UTF8 >/dev/null 2>&1
fi
if ! "$PGBIN/pg_ctl" -D "$DATADIR" status >/dev/null 2>&1; then
    "$PGBIN/pg_ctl" -D "$DATADIR" -o "-p ${PORT} -k /tmp" -l /tmp/doyah-xlsx-pg.log start >/dev/null 2>&1
    STARTED=1
    sleep 2
fi
doyah_test_env_export_connection
PGDATABASE="${DOYAH_TEST_ADMIN_DB}" "$CLI" -c "DROP DATABASE IF EXISTS ${DB} WITH (FORCE);" >/dev/null 2>&1
PGDATABASE="${DOYAH_TEST_ADMIN_DB}" "$CLI" -c "CREATE DATABASE ${DB};" >/dev/null 2>&1
export PGDATABASE="$DB"
"$CLI" -c "CREATE TABLE orders (id integer primary key, name text, phone text, amount numeric(10,2), note text);
INSERT INTO orders VALUES
  (1, '订单一', '007-1234', 12.50, '含 <标签> & 引号\"'),
  (2, '订单二', NULL, -3.25, NULL),
  (3, 'Order 三', '0900', 0, '');" >/dev/null 2>&1

OUT="$(mktemp -t doyah-xlsx).xlsx"
OUT2="$(mktemp -t doyah-xlsx2).xlsx"

echo ""
echo "== 1) 导出 xlsx =="
"$CLI" export --query "SELECT id, name, phone, amount, note FROM orders ORDER BY id" --out "$OUT" --format xlsx > /tmp/doyah-xlsx-export.log 2>&1
check "CLI 导出成功（退出码 0）" $?
check "产物非空" "$([ -s "$OUT" ] && echo 0 || echo 1)"

"$CLI" export --query "SELECT id, name, phone, amount, note FROM orders ORDER BY id" --out "$OUT2" --format xlsx > /dev/null 2>&1
if cmp -s "$OUT" "$OUT2"; then check "同样输入两次导出逐字节一致" 0; else check "同样输入两次导出逐字节一致" 1; fi

echo ""
echo "== 2) 用 Python 的 zipfile + ElementTree 独立解析产物 =="
python3 - "$OUT" <<'PY' > /tmp/doyah-xlsx-verify.txt 2>&1
import sys, zipfile, xml.etree.ElementTree as ET

path = sys.argv[1]
problems = []

with zipfile.ZipFile(path) as archive:
    # ① ZIP 自身完整（每个条目 CRC 校验）
    if archive.testzip() is not None:
        problems.append("zip 校验失败：有条目 CRC 不符")

    required = [
        "[Content_Types].xml",
        "_rels/.rels",
        "xl/workbook.xml",
        "xl/_rels/workbook.xml.rels",
        "xl/styles.xml",
        "xl/worksheets/sheet1.xml",
    ]
    names = archive.namelist()
    for part in required:
        if part not in names:
            problems.append(f"缺少部件：{part}")

    # ② 每个 XML 部件都要能被标准解析器解析
    for part in required:
        if part not in names:
            continue
        try:
            ET.fromstring(archive.read(part))
        except ET.ParseError as error:
            problems.append(f"{part} 解析失败：{error}")

    # ③ 工作表内容
    sheet = archive.read("xl/worksheets/sheet1.xml").decode("utf-8")
    root = ET.fromstring(sheet)
    ns = {"m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
    rows = root.findall(".//m:sheetData/m:row", ns)
    if len(rows) != 4:
        problems.append(f"期望 4 行（表头 + 3 行数据），实际 {len(rows)}")

    def cell_text(row, reference):
        cell = row.find(f"m:c[@r='{reference}']", ns)
        if cell is None:
            return None
        inline = cell.find("m:is/m:t", ns)
        if inline is not None:
            return inline.text or ""
        value = cell.find("m:v", ns)
        return value.text if value is not None else None

    header = rows[0] if rows else None
    if header is not None:
        names_in_sheet = [cell_text(header, f"{c}1") for c in ("A", "B", "C", "D", "E")]
        if names_in_sheet != ["id", "name", "phone", "amount", "note"]:
            problems.append(f"表头不对：{names_in_sheet}")

    # 第 2 行：中文 + 文本形式的号码（前导零必须保住）
    if len(rows) > 1:
        if cell_text(rows[1], "B2") != "订单一":
            problems.append(f"中文丢了：{cell_text(rows[1], 'B2')!r}")
        if cell_text(rows[1], "C2") != "007-1234":
            problems.append(f"文本号码被改了：{cell_text(rows[1], 'C2')!r}")
        # 注意：数值的**标度在数据通道上就被规范化了**（PG 里 `numeric(10,2)` 的 `12.50`
        # 到这里已是 `12.5`）—— 这一点 CSV 导出同样如此（见脚本末尾的对照说明），
        # 不是 xlsx 的缺陷：我们只如实写出拿到的值，不在这里"补零"。
        if cell_text(rows[1], "D2") != "12.5":
            problems.append(f"金额不对：{cell_text(rows[1], 'D2')!r}")
        if cell_text(rows[1], "E2") != '含 <标签> & 引号"':
            problems.append(f"转义没还原回来：{cell_text(rows[1], 'E2')!r}")

    # 第 3 行：NULL 应当是**没有这个格子**（而不是空字符串格子）
    if len(rows) > 2:
        if rows[2].find("m:c[@r='C3']", ns) is not None:
            problems.append("NULL 应当写成空单元格（整格缺省）")
        if rows[2].find("m:c[@r='E3']", ns) is not None:
            problems.append("NULL 应当写成空单元格（整格缺省）")
        if cell_text(rows[2], "D3") != "-3.25":
            problems.append(f"负数不对：{cell_text(rows[2], 'D3')!r}")
        inline = rows[2].find("m:c[@r='C3']/m:is/m:t", ns)
        if inline is not None:
            problems.append("NULL 列不该出现 inlineStr 单元格")

    # 第 4 行：空串与 NULL 要分得开（空串是一个存在但内容为空的格子）
    if len(rows) > 3:
        empty = rows[3].find("m:c[@r='E4']", ns)
        if empty is None:
            problems.append("空串应当写成存在的（内容为空的）格子，而不是缺省")
        if cell_text(rows[3], "C4") != "0900":
            problems.append(f"前导零被当成数字了：{cell_text(rows[3], 'C4')!r}")

    # 数字单元格不能带 inlineStr（类型判断对不对）
    for reference in ("A2", "D2", "A3", "D3", "A4", "D4"):
        cell = None
        for row in rows:
            found = row.find(f"m:c[@r='{reference}']", ns)
            if found is not None:
                cell = found
                break
        if cell is not None and cell.get("t") == "inlineStr":
            problems.append(f"{reference} 是整数列，却写成了文本")

print("OK" if not problems else "FAIL")
for problem in problems:
    print("  " + problem)
PY
if grep -q "^OK$" /tmp/doyah-xlsx-verify.txt; then
    check "六个部件齐全、XML 可解析、内容/类型/转义/空值全对" 0
else
    check "六个部件齐全、XML 可解析、内容/类型/转义/空值全对" 1
    cat /tmp/doyah-xlsx-verify.txt
fi

echo ""
echo "== 3) 对照：数值标度是数据通道的行为，不是 xlsx 的问题 =="
CSVOUT="$(mktemp -t doyah-xlsx-csv).csv"
"$CLI" export --query "SELECT amount FROM orders ORDER BY id" --out "$CSVOUT" --format csv > /dev/null 2>&1
if grep -q "12.5" "$CSVOUT" && ! grep -q "12.50" "$CSVOUT"; then
    check "CSV 同样把 numeric 的标度规范化成 12.5（所以 xlsx 只是如实写出）" 0
else
    check "CSV 同样把 numeric 的标度规范化成 12.5" 1
    head -3 "$CSVOUT"
fi

echo ""
echo "== 4) 大结果集上仍然按一次性取回导出（xlsx 不能流式，如实交代）=="
"$CLI" export --query "SELECT id, name FROM orders ORDER BY id" --out /tmp/doyah-xlsx-small.xlsx --format xlsx --fetch-size 1 > /tmp/doyah-xlsx-fetch.log 2>&1
check "小分页也能导出成功" $?
grep -q "一次性取回" /tmp/doyah-xlsx-fetch.log && check "输出里如实说明了「按一次性取回」" 0 || check "输出里如实说明了「按一次性取回」" 1

echo ""
if [ "$fail" -eq 0 ]; then
    echo "全部通过：xlsx 产物经 Python 独立解析核对无误"
    echo "（**边界**：Excel / Numbers 实际打开的效果仍需人工看一眼；本脚本验的是文件本身合法且内容正确）"
else
    echo "有失败项，见上"
fi
exit "$fail"
