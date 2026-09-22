import Foundation

/// 运行范围控制（FR-EXEC-14）：决定「这次到底跑哪一段」。
///
/// 三种范围：
/// - `all`：整篇（原有行为）；
/// - `currentStatement`：光标所在的那一条语句；
/// - `selection`：编辑器里选中的片段。
///
/// **不静默降级**：如果用户选了「选中片段」却没选内容、或选了「光标所在语句」而光标不在
/// 任何语句上，这里**不**偷偷改成「跑整篇」——那等于把一次小操作放大成整篇脚本，风险方向是错的。
/// 此时返回空 SQL + 可读原因，由界面明确提示。
///
/// 语句边界复用 `StatementSplitter`：它把每条语句存成**原文的逐字子串**且按顺序输出，
/// 因此这里只要按顺序在原文里往后定位即可拿到 UTF-16 范围，无需改动既有拆分逻辑。
public enum ExecutionScope {

    /// 运行范围模式。
    public enum Mode: String, Codable, Sendable, CaseIterable {
        case all
        case currentStatement
        case selection
    }

    /// 解析结果。
    public struct Resolution: Equatable, Sendable {
        /// 将要执行的 SQL；为空表示**没有可执行内容**（见 `issue`）。
        public var sql: String
        public var mode: Mode
        /// 命中的语句序号（1 起）；`all` 为 `nil`。
        public var statementNumber: Int?
        /// 没有可执行内容时的可读原因。
        public var issue: Issue?

        public init(sql: String, mode: Mode, statementNumber: Int? = nil, issue: Issue? = nil) {
            self.sql = sql
            self.mode = mode
            self.statementNumber = statementNumber
            self.issue = issue
        }

        /// 无法按请求范围执行的原因。
        public enum Issue: String, Equatable, Sendable {
            /// 选了「选中片段」但没有选中内容。
            case emptySelection
            /// 光标不在任何语句上（空文件 / 只有空白）。
            case noStatementAtCursor
            /// 整篇为空。
            case emptyText
        }
    }

    /// 解析出将要执行的 SQL。
    ///
    /// - Parameters:
    ///   - selection: 编辑器的选区（UTF-16，`NSRange` 语义）；`length == 0` 视为「没有选中内容」。
    public static func resolve(
        text: String,
        mode: Mode,
        selection: NSRange? = nil,
        databaseType: DatabaseType = .postgresql
    ) -> Resolution {
        switch mode {
        case .all:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return Resolution(sql: "", mode: .all, issue: .emptyText)
            }
            return Resolution(sql: text, mode: .all)

        case .selection:
            guard let selection, selection.length > 0 else {
                return Resolution(sql: "", mode: .selection, issue: .emptySelection)
            }
            guard let range = clamp(selection, to: text) else {
                return Resolution(sql: "", mode: .selection, issue: .emptySelection)
            }
            let selected = substring(text, range).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !selected.isEmpty else {
                return Resolution(sql: "", mode: .selection, issue: .emptySelection)
            }
            return Resolution(sql: selected, mode: .selection)

        case .currentStatement:
            let cursor = selection?.location ?? 0
            guard let hit = statement(containing: cursor, in: text, databaseType: databaseType) else {
                return Resolution(sql: "", mode: .currentStatement, issue: .noStatementAtCursor)
            }
            let sql = substring(text, hit.range).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sql.isEmpty else {
                return Resolution(sql: "", mode: .currentStatement, issue: .noStatementAtCursor)
            }
            return Resolution(sql: sql, mode: .currentStatement, statementNumber: hit.index + 1)
        }
    }

    /// 光标所在的语句范围（UTF-16）与序号（0 起）。
    ///
    /// 实现要点：`StatementSplitter` 返回的 `sql` 是原文的逐字子串且按出现顺序排列，
    /// 所以从上一个语句的结尾往后做**顺序查找**即可稳定定位；找不到（理论上不该发生）
    /// 则返回 `nil`，由调用方给出可读提示，而不是猜一个位置。
    public static func statement(
        containing location: Int,
        in text: String,
        databaseType: DatabaseType = .postgresql
    ) -> (range: NSRange, index: Int)? {
        let statements = StatementSplitter(databaseType: databaseType).split(text)
        guard !statements.isEmpty else { return nil }

        let nsText = text as NSString
        var searchStart = 0

        for (index, statement) in statements.enumerated() {
            guard !statement.sql.isEmpty else { continue }

            let found = nsText.range(
                of: statement.sql,
                options: [],
                range: NSRange(location: searchStart, length: nsText.length - searchStart)
            )
            guard found.location != NSNotFound else { continue }

            // 光标落在该语句范围内（含起点、含紧跟的分号位置）即算命中。
            let end = found.location + found.length
            if location >= found.location, location <= end {
                return (found, index)
            }
            if location < found.location {
                // 光标在两条语句之间的空白 / 注释里：归给**后面**那条更符合直觉。
                return (found, index)
            }
            searchStart = end
        }

        // 光标在最后一条语句之后（尾部空白）：归给最后一条。
        if let last = statements.last {
            let range = nsText.range(of: last.sql, options: [.backwards])
            if range.location != NSNotFound {
                return (range, statements.count - 1)
            }
        }
        return nil
    }

    // MARK: - 内部

    static func clamp(_ range: NSRange, to text: String) -> NSRange? {
        let length = (text as NSString).length
        guard range.location <= length else { return nil }
        let usable = min(range.length, length - range.location)
        guard usable > 0 else { return nil }
        return NSRange(location: range.location, length: usable)
    }

    static func substring(_ text: String, _ range: NSRange) -> String {
        (text as NSString).substring(with: range)
    }
}
