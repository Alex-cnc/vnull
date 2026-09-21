import XCTest
@testable import PostgresClientCore

/// 中文输入法光标缺陷（BUG-005）的判定逻辑回归。
///
/// 用 `evaluateUpdate` 模拟 `updateNSView` 的真实调用序列：
/// 每次渲染都会调用一次，并记录本次观察到的绑定值。
final class EditorTextSyncTests: XCTestCase {

    /// 组字期间：即使绑定值有变化，也绝不回写编辑器（否则打断输入法）。
    func testMarkedTextNeverAppliesBack() {
        var sync = EditorTextSync()
        sync.notePublished("你好ni hao")

        let shouldApply = sync.evaluateUpdate(
            "你好",                       // 绑定值与编辑器不同
            editorText: "你好ni hao",
            hasMarkedText: true
        )

        XCTAssertFalse(shouldApply)
    }

    /// 回车提交后：绑定还拿着组字期间的旧值，不得把已提交内容覆盖回去。
    func testStaleComposingTextIsNotAppliedBack() {
        var sync = EditorTextSync()

        // 组字期间发布未提交文本 → 该值已经渲染过一次
        sync.notePublished("你好ni hao")
        _ = sync.evaluateUpdate("你好ni hao", editorText: "你好ni hao", hasMarkedText: true)

        // 回车提交：编辑器发布最终文本
        sync.notePublished("你好")

        // 滞后的一次渲染又送来组字时的旧值
        let shouldApply = sync.evaluateUpdate("你好ni hao", editorText: "你好", hasMarkedText: false)

        XCTAssertFalse(
            shouldApply,
            "组字期间发布过的旧值不得回写编辑器，否则内容与光标会被重置"
        )
    }

    /// 编辑器自己产生的内容（等于最近发布值）不回写。
    func testEditorOriginatedTextIsNotAppliedBack() {
        var sync = EditorTextSync()
        sync.notePublished("SELECT 1")

        XCTAssertFalse(
            sync.evaluateUpdate("SELECT 1", editorText: "SELECT 1", hasMarkedText: false)
        )
    }

    /// 真正的外部改动（载入文件 / 切换页签 / 载入已保存查询）必须回写。
    func testExternalChangeIsApplied() {
        var sync = EditorTextSync()
        sync.notePublished("SELECT 1")
        _ = sync.evaluateUpdate("SELECT 1", editorText: "SELECT 1", hasMarkedText: false)

        XCTAssertTrue(
            sync.evaluateUpdate("SELECT * FROM t;", editorText: "SELECT 1", hasMarkedText: false)
        )
    }

    /// 回写之后：同一值不再重复回写，换一个外部值仍然回写。
    func testApplyingExternalChangeUpdatesBaseline() {
        var sync = EditorTextSync()
        _ = sync.evaluateUpdate("SELECT 1", editorText: "", hasMarkedText: false)
        sync.noteAppliedExternal("SELECT 1")

        XCTAssertEqual(sync.lastPublishedText, "SELECT 1")
        XCTAssertFalse(
            sync.evaluateUpdate("SELECT 1", editorText: "SELECT 1", hasMarkedText: false)
        )
        XCTAssertTrue(
            sync.evaluateUpdate("SELECT 2", editorText: "SELECT 1", hasMarkedText: false)
        )
    }

    /// 首次渲染：编辑器内容与绑定一致，不回写。
    func testFirstRenderWithSameTextDoesNotApply() {
        var sync = EditorTextSync()

        XCTAssertFalse(
            sync.evaluateUpdate("SELECT 1", editorText: "SELECT 1", hasMarkedText: false)
        )
    }

    /// 空内容页签载入文件（初始绑定为空串）应被视为外部改动。
    func testLoadingIntoEmptyEditorIsApplied() {
        var sync = EditorTextSync()

        XCTAssertTrue(
            sync.evaluateUpdate("SELECT * FROM t;", editorText: "", hasMarkedText: false)
        )
    }

    /// 连续输入：每次发布后渲染同一内容，不应产生任何回写。
    func testContinuousTypingNeverAppliesBack() {
        var sync = EditorTextSync()

        for text in ["S", "SE", "SEL", "SELE", "SELECT", "SELECT 1"] {
            sync.notePublished(text)
            XCTAssertFalse(
                sync.evaluateUpdate(text, editorText: text, hasMarkedText: false),
                "普通输入不应触发回写：\(text)"
            )
        }
    }
}
