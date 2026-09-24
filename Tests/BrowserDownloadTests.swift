import XCTest
@testable import DoyahCore

/// 浏览器下载的落盘命名与目标解析（FR-EDIT-34）。
///
/// 服务器给的 `Content-Disposition` 文件名**不可信**：`../` 会写穿授权目录、控制字符会让
/// 文件名变成不可见怪东西、空名与 `..` 是路径语义。这些判断全在 Core，所以能逐条钉住 ——
/// 一旦错了，症状是"文件落到了不该落的地方"，而不是一个显眼的报错。
final class BrowserDownloadTests: XCTestCase {

    // MARK: - 文件名净化

    func testPathTraversalIsReducedToLastSegment() {
        XCTAssertEqual(BrowserDownload.sanitizeFilename("../../etc/passwd"), "passwd")
        XCTAssertEqual(BrowserDownload.sanitizeFilename("..\\..\\Windows\\config.sys"), "config.sys")
        XCTAssertEqual(BrowserDownload.sanitizeFilename("/tmp/report.pdf"), "report.pdf")
    }

    func testControlCharactersAreRemoved() {
        XCTAssertEqual(BrowserDownload.sanitizeFilename("re\u{0000}port\u{001F}.csv"), "report.csv")
        XCTAssertEqual(BrowserDownload.sanitizeFilename("line\nbreak.txt"), "linebreak.txt")
    }

    func testEmptyAndDotNamesFallBack() {
        XCTAssertEqual(BrowserDownload.sanitizeFilename(""), "download")
        XCTAssertEqual(BrowserDownload.sanitizeFilename("   "), "download")
        XCTAssertEqual(BrowserDownload.sanitizeFilename(".."), "download")
        XCTAssertEqual(BrowserDownload.sanitizeFilename("."), "download")
        XCTAssertEqual(BrowserDownload.sanitizeFilename("..\\.."), "download")
    }

    func testTrailingDotsAndSpacesAreTrimmed() {
        XCTAssertEqual(BrowserDownload.sanitizeFilename("report.  "), "report")
        XCTAssertEqual(BrowserDownload.sanitizeFilename("  report.csv  "), "report.csv")
    }

    func testUnicodeNameIsPreserved() {
        XCTAssertEqual(BrowserDownload.sanitizeFilename("订单-2024.csv"), "订单-2024.csv")
        XCTAssertEqual(BrowserDownload.sanitizeFilename("报价单（终版）.xlsx"), "报价单（终版）.xlsx")
    }

    func testVeryLongNameIsTruncatedButKeepsExtension() {
        let long = String(repeating: "a", count: 300) + ".csv"
        let sanitized = BrowserDownload.sanitizeFilename(long)
        XCTAssertEqual(sanitized.count, 84, "80 字符主名 + `.csv`")
        XCTAssertTrue(sanitized.hasSuffix(".csv"))
    }

    // MARK: - 落盘目标（不覆盖已有文件）

    func testDestinationUsesDirectoryWhenFree() {
        let directory = URL(fileURLWithPath: "/授权目录")
        let destination = BrowserDownload.destination(
            suggestedFilename: "report.csv",
            directory: directory,
            fileExists: { _ in false }
        )
        XCTAssertEqual(destination.url?.path, "/授权目录/report.csv")
    }

    func testDestinationAvoidsOverwriting() {
        let directory = URL(fileURLWithPath: "/授权目录")
        let existing: Set<String> = ["/授权目录/report.csv", "/授权目录/report-1.csv"]
        let destination = BrowserDownload.destination(
            suggestedFilename: "report.csv",
            directory: directory,
            fileExists: { existing.contains($0.path) }
        )
        XCTAssertEqual(destination.url?.path, "/授权目录/report-2.csv", "同名时要自动加后缀，不能覆盖")
    }

    func testDestinationKeepsExtensionWhenDeduplicating() {
        let directory = URL(fileURLWithPath: "/授权目录")
        let destination = BrowserDownload.destination(
            suggestedFilename: "no-extension",
            directory: directory,
            fileExists: { $0.path == "/授权目录/no-extension" }
        )
        XCTAssertEqual(destination.url?.path, "/授权目录/no-extension-1")
    }

    func testDestinationRefusesWhenNoNameIsFree() {
        let directory = URL(fileURLWithPath: "/授权目录")
        let destination = BrowserDownload.destination(
            suggestedFilename: "report.csv",
            directory: directory,
            fileExists: { _ in true },
            maximumAttempts: 3
        )
        guard case .refused(let reason) = destination else {
            return XCTFail("同名太多时必须拒绝，而不是无限试或覆盖")
        }
        XCTAssertTrue(reason.contains("3"), reason)
    }

    // MARK: - 日志文案

    func testLogDetailOnlyCarriesNameAndOutcome() {
        let detail = BrowserDownload.logDetail(filename: "../secret/报价.xlsx", outcome: "完成")
        XCTAssertEqual(detail, "下载 报价.xlsx：完成")
        XCTAssertFalse(detail.contains(".."), "文件名也要净化后写进日志")
    }

    func testNoDirectoryReasonIsReadable() {
        XCTAssertTrue(BrowserDownload.noDirectoryReason.contains("授权目录"))
        XCTAssertTrue(BrowserDownload.noDirectoryReason.contains("指定"))
    }
}
