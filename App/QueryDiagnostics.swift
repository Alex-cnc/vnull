import Foundation
import DoyahCore

/// 查询页签的实时语法诊断。
///
/// 抽成独立入口是因为它有**两个消费方**：编辑器（下划线标记 + 底部提示条）与
/// 下方面板的「问题」页签。最大化面板时编辑器会被整块盖住，问题页签仍要能算出诊断，
/// 所以不能再由 `QueryEditorView` 算好再传下去。
enum QueryDiagnostics {

    /// 超过这个长度就先不做全量扫描（避免每次按键都卡）。
    static let maximumScannedLength = 20_000

    static func analyze(tab: QueryTab, databaseType: DatabaseType?) -> [SQLDiagnostic] {
        guard let databaseType else { return [] }
        guard tab.sql.count <= maximumScannedLength else { return [] }
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
