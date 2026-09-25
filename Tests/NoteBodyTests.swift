import XCTest
@testable import DoyahCore

/// Q8 选 C 后的核心问题：**Markdown ⇄ span 投影到底有损在哪**。
/// 这些用例就是"有损在哪"的清单（而不是纸面讨论）。
final class NoteBodyTests: XCTestCase {

    func testMarkdownSubsetProjectsToSpans() {
        let body = NoteBody(markdown: "普通 **加粗** 与 *斜体* 还有 `code`")
        let projection = NoteBodyProjection.toSpans(body)
        XCTAssertEqual(projection.spans.map(\.text), ["普通 ", "加粗", " 与 ", "斜体", " 还有 ", "code"])
        XCTAssertEqual(projection.spans[1].styles, [.bold])
        XCTAssertEqual(projection.spans[3].styles, [.italic])
        XCTAssertEqual(projection.spans[5].styles, [.code])
        XCTAssertTrue(projection.degradations.isEmpty)
    }

    /// **Round-trip 无损**：编辑器里改过再存，粗体/斜体/代码不该变形。
    func testRoundTripKeepsMarkdownSubset() {
        let original = NoteBody(markdown: "a **b** c *d* e `f`")
        let restored = NoteBodyProjection.fromSpans(NoteBodyProjection.toSpans(original).spans)
        XCTAssertEqual(restored.markdown, original.markdown)
        XCTAssertTrue(restored.sidecar.isEmpty)
    }

    /// **有损的第一处**：行内颜色/字号 Markdown 表达不了 → 必须落**旁挂**，不能悄悄丢。
    func testColorAndSizeGoToSidecarNotIntoMarkdown() {
        let spans = [
            NoteSpan(text: "红色字", styles: [.color], color: "#E53935", size: 18),
            NoteSpan(text: "普通字")
        ]
        let body = NoteBodyProjection.fromSpans(spans)
        XCTAssertEqual(body.markdown, "红色字普通字", "颜色与字号不进 Markdown 正文")
        XCTAssertEqual(body.sidecar, [NoteSidecarStyle(text: "红色字", occurrence: 0, color: "#E53935", size: 18)])
        // 再投影回来，样式还在
        let back = NoteBodyProjection.toSpans(body)
        XCTAssertEqual(back.spans[0].color, "#E53935")
        XCTAssertEqual(back.spans[0].size, 18)
        XCTAssertTrue(back.degradations.isEmpty)
    }

    /// **有损的第二处（也是最要紧的一处）**：AI 改过正文之后，旁挂按"文本+次序"可能定位不到 ——
    /// 那时**如实降级**，不猜、不静默丢。
    func testSidecarDegradesWhenTextWasRewritten() {
        let body = NoteBody(markdown: "改写后的新句子", sidecar: [NoteSidecarStyle(text: "原来的句子", color: "#1E88E5")])
        let projection = NoteBodyProjection.toSpans(body)
        XCTAssertEqual(projection.spans.map(\.text), ["改写后的新句子"])
        XCTAssertNil(projection.spans[0].color)
        XCTAssertEqual(projection.degradations.count, 1)
        XCTAssertTrue(projection.degradations[0].contains("原来的句子"), "降级要说清是哪一段")
    }

    /// **有损的第三处**：导出 .md 文件时颜色/字号必然丢 —— 必须给人一份降级报告。
    func testExportReportsWhatItLoses() {
        let body = NoteBody(markdown: "正文", sidecar: [NoteSidecarStyle(text: "正文", color: "#E53935", size: 20)])
        let export = NoteBodyProjection.exportMarkdown(body)
        XCTAssertEqual(export.markdown, "正文")
        XCTAssertEqual(export.degradations.count, 1)
        XCTAssertTrue(export.degradations[0].contains("颜色"))
        XCTAssertTrue(export.degradations[0].contains("字号"))
    }

    /// **不解析的语法原样搬运**：标题 / 列表 / 链接这些我们不解析，但**不许破坏**（AI 写的排版不能被改坏）。
    func testUnsupportedMarkdownIsPassedThroughUnchanged() {
        let markdown = "# 标题\n- 列表项\n[链接](https://example.com)"
        let projection = NoteBodyProjection.toSpans(NoteBody(markdown: markdown))
        XCTAssertEqual(projection.spans.map(\.text).joined(), markdown)
        XCTAssertTrue(projection.degradations.isEmpty, "不解析不等于降级")
    }

    /// **版本迁移**：更高的版本如实拒绝（不猜、不静默降级），同版本/低版本正常。
    func testVersionMigrationRefusesFutureVersions() throws {
        XCTAssertEqual(try NoteBody(version: 0, markdown: "x").migrated().version, NoteBodyFormat.currentVersion)
        XCTAssertEqual(try NoteBody(markdown: "x").migrated().version, NoteBodyFormat.currentVersion)
        XCTAssertThrowsError(try NoteBody(version: NoteBodyFormat.currentVersion + 1, markdown: "x").migrated()) { error in
            XCTAssertEqual(error as? NoteBody.MigrationError, .fromFuture(NoteBodyFormat.currentVersion + 1))
        }
    }

    /// 空文档与坏数据都不要抛错（与富文本模型"容错"那条需求一致）。
    func testEmptyAndOddInputsAreTolerated() {
        XCTAssertEqual(NoteBodyProjection.toSpans(NoteBody(markdown: "")).spans.map(\.text), [])
        // 未闭合的标记：整段当纯文本，不吞字
        let odd = NoteBodyProjection.toSpans(NoteBody(markdown: "未闭合 **粗体"))
        XCTAssertEqual(odd.spans.map(\.text).joined(), "未闭合 **粗体")
        XCTAssertEqual(NoteBodyProjection.fromSpans([]).markdown, "")
    }
}
