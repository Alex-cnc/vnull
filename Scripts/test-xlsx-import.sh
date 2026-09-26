#!/bin/bash
# 验证：Excel（.xlsx）导入（FR-IO-06）—— ZIP(deflate) + OOXML 读取 + 列映射 + 真写入。
#
# 为什么要这么验：xlsx 是**二进制**（ZIP 里套 OOXML），"看起来读进来了"是最容易骗过人的状态 ——
# 日期读成 45296、拼音注音被拼进单元格、空串变 NULL，都能一路"导入成功"。所以：
#   ① 夹具用 Python 的 zipfile(**deflate**) + 手写 OOXML 造（真实 Excel 的压缩路径），
#      覆盖共享字符串、`<rPh>` 拼音块、日期样式、公式缓存值、稀疏行、present-but-empty；
#   ② 导入后**回到数据库逐项核对**（中文 / 日期 / 布尔 / NULL 与空串分得开）；
#   ③ 负例：非 xlsx 的二进制（.xls 改名那种）要给出**能读懂的原因**，工作表序号越界要报错。
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
DB="doyah_xlsx_import_check"
WORK="$(mktemp -d -t doyah-xlsx-import)"
STARTED=0

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }
cleanup() { [ "$STARTED" = "1" ] && "$PGBIN/pg_ctl" -D "$DATADIR" stop >/dev/null 2>&1; }
trap cleanup EXIT

echo "== 0) 起实例并造目标表（列名与 xlsx 表头一致）=="
if [ ! -f "${DATADIR}/PG_VERSION" ]; then
    mkdir -p "$DATADIR"
    "$PGBIN/initdb" -D "$DATADIR" -U postgres --auth=trust -E UTF8 >/dev/null 2>&1
fi
if ! "$PGBIN/pg_ctl" -D "$DATADIR" status >/dev/null 2>&1; then
    "$PGBIN/pg_ctl" -D "$DATADIR" -o "-p ${PORT} -k /tmp" -l /tmp/doyah-xlsx-import-pg.log start >/dev/null 2>&1
    STARTED=1
    sleep 2
fi
doyah_test_env_export_connection
PGDATABASE="${DOYAH_TEST_ADMIN_DB}" "$CLI" -c "DROP DATABASE IF EXISTS ${DB} WITH (FORCE);" >/dev/null 2>&1
PGDATABASE="${DOYAH_TEST_ADMIN_DB}" "$CLI" -c "CREATE DATABASE ${DB};" >/dev/null 2>&1
export PGDATABASE="$DB"
"$CLI" -c "CREATE TABLE 导入目标 (id integer, 名称 text, 金额 numeric(10,2), 下单日期 date, 已付 boolean, 备注 text);" >/dev/null 2>&1

echo ""
echo "== 1) 用 Python 造一份 deflate 压缩的 .xlsx（含拼音块 / 日期样式 / 稀疏行）=="
python3 - "$WORK/订单.xlsx" <<'PY' > /tmp/doyah-xlsx-import-fixture.log 2>&1
import sys, zipfile

path = sys.argv[1]

def sheet(rows):
    body = []
    for row in rows:
        cells = "".join(row)
        body.append(cells)
    return ('<?xml version="1.0" encoding="UTF-8"?>'
            '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
            '<sheetData>' + "".join(f'<row r="{i+1}">{r}</row>' for i, r in enumerate(body)) + '</sheetData></worksheet>')

header = [
    '<c r="A1" t="inlineStr"><is><t>id</t></is></c>',
    '<c r="B1" t="inlineStr"><is><t>名称</t></is></c>',
    '<c r="C1" t="inlineStr"><is><t>金额</t></is></c>',
    '<c r="D1" t="inlineStr"><is><t>下单日期</t></is></c>',
    '<c r="E1" t="inlineStr"><is><t>已付</t></is></c>',
    '<c r="F1" t="inlineStr"><is><t>备注</t></is></c>',
]
rows = [
    # 第 2 行：共享字符串 + 内建日期样式(14) + 布尔 + 含逗号/引号/实体的文本
    ['<c r="A2" s="3"><v>1</v></c>',
     '<c r="B2" t="s"><v>0</v></c>',
     '<c r="C2" s="3"><v>12.5</v></c>',
     '<c r="D2" s="1"><v>45296</v></c>',
     '<c r="E2" t="b"><v>1</v></c>',
     '<c r="F2" t="s"><v>1</v></c>'],
    # 第 3 行：拼音块共享串（必须跳过注音）+ 带时间的自定义日期格式 + present-but-empty 备注
    ['<c r="A3" s="3"><v>2</v></c>',
     '<c r="B3" t="s"><v>2</v></c>',
     '<c r="C3" s="3"><v>0</v></c>',
     '<c r="D3" s="2"><v>45297.5</v></c>',
     '<c r="E3" t="b"><v>0</v></c>',
     '<c r="F3" t="inlineStr"><is><t></t></is></c>'],
    # 第 4 行：备注整格缺省 = NULL；下标 3 是数字样式，不能当成日期
    ['<c r="A4" s="3"><v>3</v></c>',
     '<c r="B4" t="inlineStr"><is><r><t>emoji </t></r><r><t>😀</t></r></is></c>',
     '<c r="C4" s="3"><v>-3.25</v></c>',
     '<c r="D4" s="1"><v>45298</v></c>',
     '<c r="E4" t="b"><v>1</v></c>'],
    # 第 5 行：只有 D 列（稀疏行，前面的列必须补空而不是错位）
    ['<c r="D5" s="1"><v>45299</v></c>'],
]

shared = ('<?xml version="1.0" encoding="UTF-8"?>'
          '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="3" uniqueCount="3">'
          '<si><t>订单一</t></si>'
          '<si><t>含逗号,与引号"x" 与实体 &amp; &lt;标签&gt;</t></si>'
          '<si><t>订单二</t><rPh sb="0" eb="3"><t>ディンデン</t></rPh></si>'
          '</sst>')

styles = ('<?xml version="1.0" encoding="UTF-8"?>'
          '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
          '<numFmts count="1"><numFmt numFmtId="165" formatCode="yyyy/mm/dd"/></numFmts>'
          '<cellXfs count="4">'
          '<xf numFmtId="0"/><xf numFmtId="14"/><xf numFmtId="165"/><xf numFmtId="3"/>'
          '</cellXfs></styleSheet>')

workbook = ('<?xml version="1.0" encoding="UTF-8"?>'
            '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
            'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
            '<sheets><sheet name="订单页" sheetId="1" r:id="rId1"/></sheets></workbook>')
workbook_rels = ('<?xml version="1.0" encoding="UTF-8"?>'
                 '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
                 '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
                 '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>'
                 '<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
                 '</Relationships>')
root_rels = ('<?xml version="1.0" encoding="UTF-8"?>'
             '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
             '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
             '</Relationships>')

with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("[Content_Types].xml", '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/></Types>')
    z.writestr("_rels/.rels", root_rels)
    z.writestr("xl/workbook.xml", workbook)
    z.writestr("xl/_rels/workbook.xml.rels", workbook_rels)
    z.writestr("xl/sharedStrings.xml", shared)
    z.writestr("xl/styles.xml", styles)
    z.writestr("xl/worksheets/sheet1.xml", sheet([header] + rows))
print("已生成", path)
PY
check "夹具生成（deflate 压缩）" $?
python3 -c "
import zipfile,sys
z=zipfile.ZipFile('$WORK/订单.xlsx')
methods={i.compress_type for i in z.infolist()}
assert methods=={8}, methods
print('  压缩方式：deflate(8) ✓')
"

# 伪装成 .xls 的二进制（真实场景：用户把 .xls / .et 当 xlsx 选）
printf 'not a zip at all, this is a BIFF-ish binary' > "$WORK/老格式.xls"

echo ""
echo "== 2) 导入（--format xlsx）=="
"$CLI" import --table 导入目标 --file "$WORK/订单.xlsx" --format xlsx --write > /tmp/doyah-xlsx-import.log 2>&1
check "导入退出码 0" $?
grep -q "Excel 工作表：订单页" /tmp/doyah-xlsx-import.log && check "输出里报了工作表名" 0 || check "输出里报了工作表名" 1
grep -q "已写入\|写入完成\|行" /tmp/doyah-xlsx-import.log && check "输出里报了写入行数" 0 || check "输出里报了写入行数" 1

"$CLI" export --query "SELECT count(*) AS 行数,
  count(*) FILTER (WHERE 名称 = '订单一') AS 中文,
  count(*) FILTER (WHERE 名称 = '订单二') AS 拼音未被拼入,
  count(*) FILTER (WHERE 名称 = 'emoji 😀') AS emoji,
  count(*) FILTER (WHERE 金额 = 12.5) AS 小数,
  count(*) FILTER (WHERE 下单日期 = DATE '2024-01-05') AS 日期,
  count(*) FILTER (WHERE 已付) AS 已付,
  count(*) FILTER (WHERE 备注 IS NULL) AS 空值,
  count(*) FILTER (WHERE 备注 = '') AS 空串
  FROM 导入目标" --out /tmp/doyah-xlsx-import-check.csv > /dev/null 2>&1
LINE="$(tail -1 /tmp/doyah-xlsx-import-check.csv | tr -d '\r')"
echo "  核对结果（行数,中文,拼音,emoji,小数,日期,已付,空值,空串）：$LINE"
# 期望值逐项可审计：夹具 4 行数据（不含表头）；订单一 1 行；订单二 1 行（若把 <rPh> 注音拼进去就是 0）；
# emoji 1 行；金额 12.5 1 行；日期 2024-01-05 1 行；已付为真 2 行；备注 NULL 2 行（第 4 行整格缺省 + 第 5 行没有该列）；
# 备注空串 1 行（present-but-empty 的内联串）。
if [ "$LINE" = "4,1,1,1,1,1,2,2,1" ]; then
    check "4 行全部写入；中文 / 跳过拼音 / emoji / 金额 / 日期 / 布尔 / NULL 与空串 逐项正确" 0
else
    check "4 行全部写入；中文 / 跳过拼音 / emoji / 金额 / 日期 / 布尔 / NULL 与空串 逐项正确（实际 ${LINE}）" 1
fi

# 日期绝不能是序列号（这是"看着成功、数据已错"的典型）
"$CLI" export --query "SELECT string_agg(DISTINCT 下单日期::text, ',' ORDER BY 下单日期::text) FROM 导入目标 WHERE 下单日期 IS NOT NULL" --out /tmp/doyah-xlsx-import-dates.csv > /dev/null 2>&1
if grep -q "2024-01-05,2024-01-06,2024-01-07" /tmp/doyah-xlsx-import-dates.csv; then
    check "日期按 YYYY-MM-DD 落库（不是 45296 这类序列号）" 0
else
    check "日期按 YYYY-MM-DD 落库（不是 45296 这类序列号）" 1
fi

# 稀疏行的值要落在正确的列上（夹具第 5 行只有 D 列 → 其余列都必须是 NULL）
"$CLI" export --query "SELECT count(*) FROM 导入目标 WHERE 下单日期 = DATE '2024-01-08' AND 名称 IS NULL AND id IS NULL AND 金额 IS NULL" --out /tmp/doyah-xlsx-import-sparse.csv > /dev/null 2>&1
SPARSE="$(tail -1 /tmp/doyah-xlsx-import-sparse.csv | tr -d '\r' | tr -d '[:space:]')"
if [ "$SPARSE" = "1" ]; then
    check "稀疏行（只有 D 列）落到了正确的列，前面的列是 NULL" 0
else
    check "稀疏行（只有 D 列）落到了正确的列，前面的列是 NULL（实际 ${SPARSE}）" 1
fi

echo ""
echo "== 3) 负例：不是 xlsx 的文件 / 工作表序号越界 =="
"$CLI" import --table 导入目标 --file "$WORK/老格式.xls" --format xlsx --write > /tmp/doyah-xlsx-import-bad.log 2>&1
code=$?
check "非 xlsx 被拒（退出码 ${code}，期望 65）" "$([ "$code" -eq 65 ] && echo 0 || echo 1)"
grep -q "\.xls" /tmp/doyah-xlsx-import-bad.log && check "错误信息解释了「.xls / .et 不是 xlsx，要另存为 .xlsx」" 0 || check "错误信息解释了「.xls / .et 不是 xlsx，要另存为 .xlsx」" 1
"$CLI" export --query "SELECT count(*) FROM 导入目标" --out /tmp/doyah-xlsx-import-before.csv > /dev/null 2>&1
BEFORE="$(tail -1 /tmp/doyah-xlsx-import-before.csv | tr -d '\r' | tr -d '[:space:]')"
check "被拒的导入没有往表里写数据（仍是 $BEFORE 行）" "$([ "$BEFORE" = "4" ] && echo 0 || echo 1)"

"$CLI" import --table 导入目标 --file "$WORK/订单.xlsx" --format xlsx --sheet 9 --write > /tmp/doyah-xlsx-import-sheet.log 2>&1
code=$?
check "工作表序号越界被拒（退出码 ${code}，期望 64）" "$([ "$code" -eq 64 ] && echo 0 || echo 1)"
grep -q "工作表序号超出范围" /tmp/doyah-xlsx-import-sheet.log && check "并列出这个文件实际有哪些工作表" 0 || check "并列出这个文件实际有哪些工作表" 1

echo ""
echo "== 4) 与仓库里的夹具交叉：orders.xlsx 的第二张表 =="
"$CLI" import --table 导入目标 --file Tests/Fixtures/xlsx/orders.xlsx --format xlsx --sheet 2 > /tmp/doyah-xlsx-import-fixture2.log 2>&1
code=$?
check "列名全对不上时**拒绝导入**并给非零退出码（${code}）" "$([ "$code" -ne 0 ] && echo 0 || echo 1)"
grep -q "Excel 工作表：第二张" /tmp/doyah-xlsx-import-fixture2.log && check "选中的是「第二张」而不是第一张" 0 || check "选中的是「第二张」而不是第一张" 1
grep -q "没有任何列能映射到目标表" /tmp/doyah-xlsx-import-fixture2.log && check "并说出了原因（没有任何列能映射）" 0 || check "并说出了原因（没有任何列能映射）" 1

"$CLI" -c "CREATE TABLE 导入目标2 (编号 text, 说明 text);" >/dev/null 2>&1
"$CLI" import --table 导入目标2 --file Tests/Fixtures/xlsx/orders.xlsx --format xlsx --sheet 2 --write > /tmp/doyah-xlsx-import-fixture2b.log 2>&1
check "列名匹配时第二张表能真导入（退出码 0）" $?
"$CLI" export --query "SELECT 编号, 说明 FROM 导入目标2" --out /tmp/doyah-xlsx-import-fixture2b.csv > /dev/null 2>&1
if tail -1 /tmp/doyah-xlsx-import-fixture2b.csv | tr -d '\r' | grep -q "^X-1,第二张表$"; then
    check "第二张表的内容正确（X-1 / 第二张表）" 0
else
    check "第二张表的内容正确（X-1 / 第二张表）" 1
    cat /tmp/doyah-xlsx-import-fixture2b.csv
fi

echo ""
if [ "$fail" -eq 0 ]; then
    echo "全部通过：xlsx（deflate + OOXML）能读对并写对，日期/拼音/空值与空串都经真库回查。"
    echo "（**边界**：夹具是 Python 手写 OOXML，并非 Excel / WPS 直接产出；"
    echo "  真实软件导出的文件请按 Docs/design/剩余任务清单.md 的人工清单用 WPS 存一份再导一次。）"
else
    echo "有失败项，见上"
fi
exit "$fail"
