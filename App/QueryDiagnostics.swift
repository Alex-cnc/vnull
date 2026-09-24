import Foundation
import DoyahCore

/// 查询页签的实时语法诊断。
///
/// 抽成独立入口是因为它有**两个消费方**：编辑器（下划线标记 + 底部提示条）与
/// 下方面板的「问题」页签。最大化面板时编辑器会被整块盖住，问题页签仍要能算出诊断，
/// 所以不能再由 `QueryEditorView` 算好再传下去。
enum QueryDiagnostics {

    /// 本次输入是否**因为太长而跳过了**实时检查（判据在 Core，两处消费方共用）。
    ///
    /// 为什么要单独问一句：跳过时 `analyze` 返回空，界面只看得到"没有问题"的空态 ——
    /// 用户会以为"检查过了，没问题"。跳过必须说出来（FR 的阻塞条件里承诺过这句提示，
    /// 但在此之前它并不存在）。
    static func isRealtimeAnalysisSkipped(sql: String) -> Bool {
        sqlExceedsRealtimeScanLimit(sql)
    }

    static func analyze(tab: QueryTab, databaseType: DatabaseType?) -> [SQLDiagnostic] {
        guard let databaseType else { return [] }
        guard !isRealtimeAnalysisSkipped(sql: tab.sql) else { return [] }
        return SQLLinter(
            databaseType: databaseType,
            language: LocalizationManager.shared.language
        ).analyze(tab.sql)
    }

    /// `AppState` 是主 actor 隔离的，所以这个重载也标上；调用方都在 SwiftUI 视图里。
    @MainActor
    static func analyze(tab: QueryTab, in appState: AppState) -> [SQLDiagnostic] {
        analyze(tab: tab, databaseType: appState.connection(for: tab)?.dbType)
    }
}
