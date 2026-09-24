import XCTest
@testable import DoyahCore

/// 导出文本编码（FR-IO-07）：UTF-8 与 GB18030 的字节口径、流式/一次性一致、失败路径。
///
/// 这里只钉**编码本身**（字节与契约）；"文件真的能被中文 Windows 的 Excel / WPS 打开"
/// 这件事在 `Scripts/test-csv-encoding.sh` 里用 Python 的 `gb18030` 编解码器**独立**核对 ——
/// 两份实现互相印证，而不是自己验自己。
final class ResultExportEncodingTests: XCTestCase {

    private func result(
        columns: [String] = ["id", "名称"],
        rows: [[String?]] = [[ "1", "中文，1990"], ["2", nil]]
    ) -> QueryResult {
        QueryResult(
            columns: columns.enumerated().map { ColumnMeta(id: $0.offset, name: $0.element) },
            rows: rows,
            affectedRows: nil,
            executionTime: 0.01,
            isTruncated: false,
            truncationLimit: nil
        )
    }

    // MARK: - 字节口径

    func testUTF8ByteOrderMarkIsThreeBytes() {
        XCTAssertEqual(ResultExportEncoding.utf8.byteOrderMark, [0xEF, 0xBB, 0xBF])
        XCTAssertTrue(ResultExportEncoding.gb18030.byteOrderMark.isEmpty, "GB18030 没有 BOM 概念")
    }

    /// 已知字节对照：`中文，1990` 在 GBK / GB18030 下是 `D6 D0 CE C4 A3 AC 31 39 39 30`
    /// （逗号是全角 `A3 AC`，数字落 ASCII 区）—— 这个期望值来自 GB2312 码表，
    /// 不是"跑一遍看打印什么就写什么"。
    func testGB18030KnownBytes() throws {
        try XCTSkipUnless(ResultExportEncoding.gb18030.isAvailable, "本机 Foundation 没有 GB18030 编码器")
        let data = try ResultExportEncoding.gb18030.encode("中文，1990")
        XCTAssertEqual(
            Array(data),
            [0xD6, 0xD0, 0xCE, 0xC4, 0xA3, 0xAC, 0x31, 0x39, 0x39, 0x30],
            "GB18030 下的中文字节应与 GB2312 码表一致"
        )
    }

    func testRoundTripThroughTargetEncoding() throws {
        for encoding in ResultExportEncoding.allCases where encoding.isAvailable {
            let text = "中文、emoji 😀、罗马数字 ①"
            let decoded = try encoding.decode(try encoding.encode(text))
            XCTAssertEqual(decoded, text, "\(encoding.shortName) 往返应逐字符相等")
        }
    }

    /// 实测订正：GB18030 是**全 Unicode** 编码，四字节序列覆盖 emoji —— 不是"表达不了"。
    /// 这条断言把"我以为的"钉成"实际是的"，避免以后又按错误的直觉去做降级设计。
    func testGB18030CoversEmojiAndRareCharacters() throws {
        try XCTSkipUnless(ResultExportEncoding.gb18030.isAvailable, "本机 Foundation 没有 GB18030 编码器")
        let data = try ResultExportEncoding.gb18030.encode("😀𠀀€")
        XCTAssertEqual(Array(data), [0x94, 0x39, 0xFC, 0x36, 0x95, 0x32, 0x82, 0x36, 0xA2, 0xE3])
    }

    /// 失败检测器本身：喂一个**故意很窄**的编码（ASCII），它要指出第一个编不出的字符。
    func testUnencodableDetectorFindsFirstOffendingCharacter() {
        XCTAssertEqual(
            ResultExportEncoding.firstUnencodableCharacter(in: "abc中文", encoding: .ascii),
            "中"
        )
        XCTAssertNil(ResultExportEncoding.firstUnencodableCharacter(in: "plain ascii", encoding: .ascii))
    }

    // MARK: - 解析

    func testParseAcceptsCommonAliases() {
        XCTAssertEqual(ResultExportEncoding.parse("UTF-8"), .utf8)
        XCTAssertEqual(ResultExportEncoding.parse("gbk"), .gb18030)
        XCTAssertEqual(ResultExportEncoding.parse("GB2312"), .gb18030)
        XCTAssertEqual(ResultExportEncoding.parse(" ansi "), .gb18030)
        XCTAssertEqual(ResultExportEncoding.parse("cp936"), .gb18030)
        XCTAssertNil(ResultExportEncoding.parse("latin1"), "不认识的编码必须拒绝，不能悄悄退回 UTF-8")
    }

    // MARK: - 导出入口

    /// UTF-8 路径与既有行为**逐字节相同**（BOM 从字符级挪到字节级，结果不变）。
    func testUTF8DataMatchesLegacyTextOutput() throws {
        let model = result()
        let data = try ResultExporter.data(for: model, format: .csv, encoding: .utf8)
        XCTAssertEqual(data, Data(ResultExporter.text(for: model, format: .csv).utf8))
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF])
    }

    /// GB18030：没有 BOM，正文与 UTF-8 那份**解码后相同**（只是字节不同）。
    func testGB18030CSVHasNoBOMAndSameTextAsUTF8() throws {
        try XCTSkipUnless(ResultExportEncoding.gb18030.isAvailable, "本机 Foundation 没有 GB18030 编码器")
        let model = result()
        let gb = try ResultExporter.data(for: model, format: .csv, encoding: .gb18030)
        XCTAssertFalse(gb.starts(with: [0xEF, 0xBB, 0xBF]), "GB18030 不该有 UTF-8 BOM")
        XCTAssertEqual(
            try ResultExportEncoding.gb18030.decode(gb),
            String(ResultExporter.text(for: model, format: .csv).dropFirst())
        )
        // 数字与 ASCII 部分在两份里一致 —— 出问题的只可能是中文那几个字节。
        XCTAssertTrue(String(decoding: gb, as: UTF8.self).contains("1990"))
    }

    /// 编码只对 CSV 生效：其余格式传 GB18030 必须**抛错**，而不是忽略参数后按 UTF-8 写出。
    func testEncodingOtherThanUTF8IsRejectedForOtherFormats() {
        let model = result()
        for format in [ResultExportFormat.json, .tsv, .markdown, .sqlInsert, .xlsx] {
            XCTAssertThrowsError(try ResultExporter.data(for: model, format: format, encoding: .gb18030)) { error in
                XCTAssertEqual(
                    error as? ResultExportEncodingError,
                    .notApplicableToFormat(encoding: .gb18030, format: format),
                    "\(format.fileExtension) 不该接受 GB18030"
                )
            }
        }
        // UTF-8 对所有格式都合法（回归：别把默认路径一起拦掉）。
        for format in ResultExportFormat.allCases {
            XCTAssertNoThrow(try ResultExporter.data(for: model, format: format, encoding: .utf8))
        }
    }

    // MARK: - 流式与一次性一致（换编码后依然成立）

    func testStreamingMatchesOneShotBytes() throws {
        for encoding in ResultExportEncoding.allCases {
            // 本机没有这个编码器就换下一个，而不是把整个用例跳过（UTF-8 永远该被测到）。
            guard encoding.isAvailable else { continue }
            let model = result()
            let expected = try ResultExporter.data(for: model, format: .csv, encoding: encoding)

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("doyah-encoding-\(UUID().uuidString).csv")
            defer { try? FileManager.default.removeItem(at: url) }

            // flushByteLimit = 1：每一行都单独落盘一次，把"分块"放到最大 ——
            // 多字节序列若被切在块边界上，这里就会露馅。
            let writer = ResultStreamWriter(
                targetURL: url,
                format: .csv,
                columns: model.columns,
                encoding: encoding,
                flushByteLimit: 1
            )
            try writer.begin()
            try writer.write([model.rows[0]])
            try writer.write([model.rows[1]])
            let report = try writer.finish()

            XCTAssertEqual(try Data(contentsOf: url), expected, "\(encoding.shortName)：流式与一次性必须逐字节相同")
            XCTAssertEqual(report.rowCount, 2)
            XCTAssertTrue(report.flushCount > 2, "flushByteLimit=1 时应当确实分多次落盘")
        }
    }

    func testStreamingRejectsNonCSVWithGB18030AndLeavesNoFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("doyah-encoding-reject-\(UUID().uuidString).json")
        let writer = ResultStreamWriter(targetURL: url, format: .json, columns: result().columns, encoding: .gb18030)
        XCTAssertThrowsError(try writer.begin()) { error in
            XCTAssertEqual(error as? ResultExportEncodingError, .notApplicableToFormat(encoding: .gb18030, format: .json))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "被拒绝的导出不该留下文件")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(".\(url.lastPathComponent).partial-") }
        XCTAssertTrue(leftovers.isEmpty, "也不该留下 .partial 半成品：\(leftovers)")
    }

    /// 值里带 emoji 时 GB18030 也能导出（实测结论），且目标文件内容可解回原值。
    func testGB18030ExportKeepsEmojiValues() throws {
        try XCTSkipUnless(ResultExportEncoding.gb18030.isAvailable, "本机 Foundation 没有 GB18030 编码器")
        let model = result(rows: [["1", "emoji 😀 与中文"]])
        let data = try ResultExporter.data(for: model, format: .csv, encoding: .gb18030)
        XCTAssertTrue(try ResultExportEncoding.gb18030.decode(data).contains("emoji 😀 与中文"))
    }
}
