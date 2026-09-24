#!/usr/bin/env python3
"""生成 .xlsx 读取测试的夹具（FR-IO-06），产物入库在 `Tests/Fixtures/xlsx/`。

为什么要**手写 OOXML** 而不是用 openpyxl：
    夹具要覆盖的是"真实 Excel 里常见、但自己写文件时想不到"的形状 —— 共享字符串、
    `<rPh>` 拼音块（不跳过就会把注音读进单元格）、日期序列号 + 样式、公式的缓存值、
    稀疏行（`r="6"` 跳号）、present-but-empty 的内联串。openpyxl 会把这些"规整"掉，
    正好丢掉要测的东西；手写 XML 才能逐个钉住。

为什么压缩用 **deflate** 而不是 stored：
    真实 Excel / WPS 导出的 xlsx 都是 deflate。夹具必须走真实压缩路径，否则
    `Inflate` 根本没被覆盖到（`Scripts/test-xlsx-import.sh` 还会再造一份 deflate 文件端到端验）。

用法：
    python3 Scripts/make-xlsx-fixtures.py            # 重新生成全部夹具
    python3 Scripts/make-xlsx-fixtures.py --print    # 只打印期望值（写测试时对照用）
"""

from __future__ import annotations

import pathlib
import sys
import zipfile

OUT = pathlib.Path("Tests/Fixtures/xlsx")

CONTENT_TYPES = """<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
<Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>
<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
</Types>"""

ROOT_RELS = """<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>"""

WORKBOOK_RELS = """<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>
<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>
<Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>"""

# 共享字符串：第 2 条带 `<rPh>` 拼音块（读取时**必须跳过**），第 3 条含 XML 实体。
SHARED_STRINGS = """<?xml version="1.0" encoding="UTF-8"?>
<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="5" uniqueCount="5">
<si><t>订单一</t></si>
<si><t>订单二</t><rPh sb="0" eb="3"><t>ディンデン</t></rPh></si>
<si><r><t>Order </t></r><r><t>Three</t></r><r><t> Inc.</t></r></si>
<si><t>含逗号,与引号"x" 与实体 &amp; &lt;标签&gt;</t></si>
<si><t xml:space="preserve">  前后有空格  </t></si>
</sst>"""

# 样式：0=默认、1=内建日期(14)、2=自定义日期码(165 yyyy/mm/dd)、3=数字。
STYLES = """<?xml version="1.0" encoding="UTF-8"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<numFmts count="1"><numFmt numFmtId="165" formatCode="yyyy/mm/dd"/></numFmts>
<fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>
<fills count="1"><fill><patternFill patternType="none"/></fill></fills>
<borders count="1"><border/></borders>
<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
<cellXfs count="4">
<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
<xf numFmtId="14" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
<xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
<xf numFmtId="3" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
</cellXfs>
</styleSheet>"""

WORKBOOK = """<?xml version="1.0" encoding="UTF-8"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
          xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<sheets>
<sheet name="订单" sheetId="1" r:id="rId1"/>
<sheet name="第二张" sheetId="2" r:id="rId2"/>
</sheets>
</workbook>"""

WORKBOOK_1904 = WORKBOOK.replace("<sheets>", '<workbookPr date1904="1"/><sheets>')

# 第一张表：把「真实文件里最容易读错」的形状全放一遍。
SHEET1 = """<?xml version="1.0" encoding="UTF-8"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<dimension ref="A1:H6"/>
<sheetData>
<row r="1">
<c r="A1" t="inlineStr"><is><t>id</t></is></c>
<c r="B1" t="inlineStr"><is><t>名称</t></is></c>
<c r="C1" t="inlineStr"><is><t>金额</t></is></c>
<c r="D1" t="inlineStr"><is><t>下单日期</t></is></c>
<c r="E1" t="inlineStr"><is><t>已付</t></is></c>
<c r="F1" t="inlineStr"><is><t>备注</t></is></c>
</row>
<row r="2">
<c r="A2" s="3"><v>1</v></c>
<c r="B2" t="s"><v>0</v></c>
<c r="C2" s="3"><v>12.5</v></c>
<c r="D2" s="1"><v>45296</v></c>
<c r="E2" t="b"><v>1</v></c>
<c r="F2" t="s"><v>3</v></c>
</row>
<row r="3">
<c r="A3" s="3"><v>2</v></c>
<c r="B3" t="inlineStr"><is><r><t>订单</t></r><r><t>二</t></r></is></c>
<c r="C3" s="3"><v>0</v></c>
<c r="D3" s="2"><v>45297.5</v></c>
<c r="E3" t="b"><v>0</v></c>
<c r="F3" t="inlineStr"><is><t></t></is></c>
</row>
<row r="4">
<c r="A4" s="3"><v>3</v></c>
<c r="B4" t="s"><v>2</v></c>
<c r="C4"><f>A2*10</f><v>125</v></c>
<c r="E4" t="b"><v>1</v></c>
<c r="F4" t="str"><f>CONCATENATE("公式","结果")</f><v>公式结果</v></c>
</row>
<row r="5">
<c r="A5" s="3"><v>4</v></c>
<c r="B5" t="e"><v>#DIV/0!</v></c>
<c r="C5" s="3"><v>-3.25</v></c>
<c r="D5" s="1"><v>45299</v></c>
<c r="E5" t="b"><v>0</v></c>
<c r="F5" t="s"><v>4</v></c>
</row>
<row r="6">
<c r="H6" t="inlineStr"><is><t>稀疏</t></is></c>
</row>
</sheetData>
</worksheet>"""

SHEET2 = """<?xml version="1.0" encoding="UTF-8"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<sheetData>
<row r="1"><c r="A1" t="inlineStr"><is><t>编号</t></is></c><c r="B1" t="inlineStr"><is><t>说明</t></is></c></row>
<row r="2"><c r="A2" t="inlineStr"><is><t>X-1</t></is></c><c r="B2" t="inlineStr"><is><t>第二张表</t></is></c></row>
</sheetData>
</worksheet>"""

SHEET_1904 = SHEET1.replace('<c r="D2" s="1"><v>45296</v></c>', '<c r="D2" s="1"><v>100</v></c>')

# 最小文件：没有 styles.xml / sharedStrings.xml，只有内联串（考验可选部件的兜底）。
MINIMAL_SHEET = """<?xml version="1.0" encoding="UTF-8"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<sheetData>
<row r="1"><c r="A1" t="inlineStr"><is><t>列一</t></is></c><c r="B1" t="inlineStr"><is><t>列二</t></is></c></row>
<row r="2"><c r="A2" t="inlineStr"><is><t>值</t></is></c><c r="B2"><v>42</v></c></row>
</sheetData>
</worksheet>"""

MINIMAL_WORKBOOK_RELS = """<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
</Relationships>"""

MINIMAL_WORKBOOK = """<?xml version="1.0" encoding="UTF-8"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
          xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<sheets><sheet name="最小" sheetId="1" r:id="rId1"/></sheets>
</workbook>"""


def write_zip(path: pathlib.Path, parts: dict[str, str], compression=zipfile.ZIP_DEFLATED) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w", compression=compression) as archive:
        for name, content in parts.items():
            archive.writestr(name, content.encode("utf-8"))


def main() -> int:
    if "--print" in sys.argv:
        print("orders.xlsx 的期望值：")
        print("  工作表：['订单', '第二张']")
        print("  订单 行数：6 / 列数：8（H 列稀疏）")
        print("  B2 = 订单一（共享串）| B3 = 订单二（内联富文本；<rPh> 拼音必须被跳过）")
        print("  B4 = Order Three Inc.（共享串富文本三段拼接）")
        print("  F2 = 含逗号,与引号\"x\" 与实体 & <标签>（实体解码）")
        print("  F3 = ''（present-but-empty 内联串 = 空字符串，不是 NULL）")
        print("  D2 = 2024-01-05（序列号 45296 + 内建日期样式 14）")
        print("  D3 = 2024-01-06 12:00:00（45297.5 + 自定义格式码 yyyy/mm/dd）")
        print("  C4 = 125（公式的缓存值）| F4 = 公式结果（t=str 的缓存值）")
        print("  B5 = #DIV/0!（错误值原样保留）| D4 = NULL（整格缺省）| H6 = 稀疏（第 6 行 H 列）")
        print("  F5 = '  前后有空格  '（xml:space=preserve 必须保留空白）")
        print("dates1904.xlsx：D2 = 1904-04-10（date1904=\"1\"，序列号 100）")
        print("minimal.xlsx：无 styles.xml / sharedStrings.xml，仍要能读（A1=列一, B2=42）")
        return 0

    write_zip(
        OUT / "orders.xlsx",
        {
            "[Content_Types].xml": CONTENT_TYPES,
            "_rels/.rels": ROOT_RELS,
            "xl/workbook.xml": WORKBOOK,
            "xl/_rels/workbook.xml.rels": WORKBOOK_RELS,
            "xl/sharedStrings.xml": SHARED_STRINGS,
            "xl/styles.xml": STYLES,
            "xl/worksheets/sheet1.xml": SHEET1,
            "xl/worksheets/sheet2.xml": SHEET2,
        },
    )
    write_zip(
        OUT / "dates1904.xlsx",
        {
            "[Content_Types].xml": CONTENT_TYPES,
            "_rels/.rels": ROOT_RELS,
            "xl/workbook.xml": WORKBOOK_1904,
            "xl/_rels/workbook.xml.rels": WORKBOOK_RELS,
            "xl/sharedStrings.xml": SHARED_STRINGS,
            "xl/styles.xml": STYLES,
            "xl/worksheets/sheet1.xml": SHEET_1904,
            "xl/worksheets/sheet2.xml": SHEET2,
        },
    )
    write_zip(
        OUT / "minimal.xlsx",
        {
            "[Content_Types].xml": CONTENT_TYPES,
            "_rels/.rels": ROOT_RELS,
            "xl/workbook.xml": MINIMAL_WORKBOOK,
            "xl/_rels/workbook.xml.rels": MINIMAL_WORKBOOK_RELS,
            "xl/worksheets/sheet1.xml": MINIMAL_SHEET,
        },
    )
    # stored（不压缩）的一份：证明两条压缩方法都认（真实 Excel 用 deflate，但 stored 合法）。
    write_zip(
        OUT / "stored.xlsx",
        {
            "[Content_Types].xml": CONTENT_TYPES,
            "_rels/.rels": ROOT_RELS,
            "xl/workbook.xml": MINIMAL_WORKBOOK,
            "xl/_rels/workbook.xml.rels": MINIMAL_WORKBOOK_RELS,
            "xl/worksheets/sheet1.xml": MINIMAL_SHEET,
        },
        compression=zipfile.ZIP_STORED,
    )
    for path in sorted(OUT.glob("*.xlsx")):
        print(f"生成 {path}（{path.stat().st_size} 字节）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
