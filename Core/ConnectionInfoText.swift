import Foundation

/// 上下文栏右侧那个「连接信息」tooltip 的**文本组成**（FR-CONN-12 / FR-EDIT-08）。
///
/// 为什么要有这一层：这段文字有两个"随连接变"的来源，随手拼很容易拼错或拼漏 ——
/// ① 类型名来自 `DatabaseType.displayName`（PostgreSQL / GBase 8a…）；
/// ② 分隔符来自**方言** `SQLDialect.statementDelimiter`，不是界面写死的 `;`
///    （目前两种方言恰好都是 `;`，以后加方言时这里自动跟着变）。
/// 做成纯函数就能单测"少了哪一项、顺序对不对、缺项会不会多出一个分隔符"。
///
/// 2026-09-24 需求提出者的两条界面口径决定了它的**位置**：
///   · 「工具条上就应该是干干净净的一堆按钮…不应该在这里留一长串文本 tooltip」→ 查询工具条右侧清空；
///   · 「这个 tooltip 放到上面数据库连接的那个工具条最右侧更合理」→ 落到**上下文栏最右侧**，
///     只在悬停时出现，不占版面。
public enum ConnectionInfoText {

    /// 「PostgreSQL · 分隔符 ; · doyah_manual_test · postgres · 127.0.0.1:55433」
    ///
    /// 缺项（库 / 用户还没拿到、地址为空）自动跳过 —— **不会留下多余的分隔符**。
    public static func summary(
        databaseType: DatabaseType,
        database: String?,
        username: String?,
        endpoint: String,
        language: AppLanguage
    ) -> String {
        var parts = [databaseType.displayName]
        let delimiter = SQLDialectFactory.make(for: databaseType).statementDelimiter
        let template = LocalizedStrings.text(.workspaceDelimiter, language: language)
        parts.append(String(format: template, locale: language.locale, delimiter))
        if let database, !database.isEmpty { parts.append(database) }
        if let username, !username.isEmpty { parts.append(username) }
        if !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(endpoint) }
        return parts.joined(separator: " · ")
    }
}
