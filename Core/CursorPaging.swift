import Foundation

/// 服务端游标分页（FR-RES-13 的「取」那一半）。
///
/// 为什么需要它：导出超大结果集时，「一次查询取回全部行」会把整个结果驻留在内存里 ——
/// 而 `LIMIT n OFFSET m` 翻页对**大表**同样是坑：每翻一页数据库都要从头扫过前面所有行（O(n²)）。
/// 服务端游标是唯一**顺序**取数的方式：`DECLARE` 一次，之后 `FETCH` 只往前走。
///
/// 两条与数据库语义绑定的约束写在明处：
/// 1. PostgreSQL 的游标**必须在事务里**（`DECLARE` 需要 `BEGIN`），所以计划里包含事务语句；
/// 2. 因此导出会**开启并结束自己的事务** —— 如果调用方（或用户）已经在手工事务里，
///    调它就会把那个事务提交掉。调用方有责任先结束手工事务（界面侧应在入口提示）。
public struct CursorPagingPlan: Equatable, Sendable {

    public var cursorName: String
    public var pageSize: Int
    public var beginStatement: String
    public var commitStatement: String
    public var rollbackStatement: String
    public var declareStatement: String
    public var closeStatement: String

    /// 取下一页的语句（页大小可变：最后一页可能是 0 行）。
    public func fetchStatement(pageSize: Int) -> String {
        "FETCH FORWARD \(max(0, pageSize)) FROM \(CursorPaging.quoteIdentifier(cursorName))"
    }
}

public enum CursorPagingError: Error, Equatable, LocalizedError {
    /// 只能对**单条查询**开游标。给出可读原因（不是"输入非法"这种没法排查的话）。
    case notASingleQuery(reason: String)
    case invalidPageSize

    public var errorDescription: String? {
        switch self {
        case .notASingleQuery(let reason): return "游标分页只支持单条查询：\(reason)"
        case .invalidPageSize: return "每页行数必须大于 0"
        }
    }
}

/// **按需取页**的游标驱动器。
///
/// 为什么不是 `AsyncThrowingStream`：流的生产者会**抢在消费者前面**把页面一页页取完
/// （本轮实测：消费方只取了一页就退出，生产者仍取了三页并 `COMMIT`）—— 那既毁掉
/// 「内存与总行数无关」这个目标，也会在用户中途取消时把事务提交掉。
/// 这里改成显式拉取：**消费者不取，就不去数据库拿**。
///
/// 用法（务必 `defer` 或 `do/catch` 里调用 `close()`）：
/// ```swift
/// let fetcher = CursorFetcher(plan: plan, execute: run)
/// try await fetcher.open()          // BEGIN + DECLARE
/// while let page = try await fetcher.nextPage() { ... }
/// // 正常走到 nil 时已自动 CLOSE + COMMIT；提前退出请调用 close()（CLOSE + ROLLBACK）
/// ```
public actor CursorFetcher {

    private let plan: CursorPagingPlan
    private let execute: (String) async throws -> QueryResult
    private var isOpen = false
    private var isFinished = false

    /// 已成功取回的行数（不含尚未取的部分）。
    public private(set) var rowCount = 0
    /// 已取页数。
    public private(set) var pageCount = 0

    public init(plan: CursorPagingPlan, execute: @escaping (String) async throws -> QueryResult) {
        self.plan = plan
        self.execute = execute
    }

    /// `BEGIN` + `DECLARE`。失败时不留下任何东西（尽力回滚）。
    public func open() async throws {
        guard !isOpen else { return }
        do {
            _ = try await execute(plan.beginStatement)
            _ = try await execute(plan.declareStatement)
            isOpen = true
        } catch {
            _ = try? await execute(plan.rollbackStatement)
            throw error
        }
    }

    /// 取下一页。返回 `nil` 表示**已经取完**（此时已 `CLOSE` + `COMMIT`）。
    ///
    /// 页大小由计划固定；某一页不足 `pageSize`（含 0 行）即视为最后一页 ——
    /// 因此不会出现"最后一页还去多问一次"的浪费。
    public func nextPage() async throws -> QueryResult? {
        guard isOpen, !isFinished else { return nil }
        do {
            let page = try await execute(plan.fetchStatement(pageSize: plan.pageSize))
            rowCount += page.rows.count
            pageCount += 1

            if page.rows.count < plan.pageSize {
                // 最后一页：正常收尾（提交）。
                _ = try await execute(plan.closeStatement)
                _ = try await execute(plan.commitStatement)
                isFinished = true
            }
            return page
        } catch {
            // 出错：关游标 + 回滚，然后抛原来的错（清理失败不覆盖真错误）。
            _ = try? await execute(plan.closeStatement)
            _ = try? await execute(plan.rollbackStatement)
            isFinished = true
            throw error
        }
    }

    /// 提前结束（写盘失败 / 用户取消）：`CLOSE` + **`ROLLBACK`**，可重复调用。
    ///
    /// 为什么回滚而不是提交：导出没走完，这个事务本来就没有"要提交的东西"；
    /// 提交一个半途而废的事务，比回滚更危险。
    public func close() async {
        guard isOpen, !isFinished else { return }
        isFinished = true
        _ = try? await execute(plan.closeStatement)
        _ = try? await execute(plan.rollbackStatement)
    }
}

public enum CursorPaging {

    /// 默认游标名（每个导出连接独立，名字固定便于在 `pg_cursors` 里认出来）。
    public static let defaultCursorName = "doyah_export_cursor"
    public static let defaultPageSize = 1_000

    /// 生成执行计划。**只做能确定的事**：单条查询、页大小为正。
    public static func plan(
        query: String,
        cursorName: String = CursorPaging.defaultCursorName,
        pageSize: Int = CursorPaging.defaultPageSize
    ) -> Result<CursorPagingPlan, CursorPagingError> {
        guard pageSize > 0 else { return .failure(.invalidPageSize) }

        guard let statement = singleStatement(query) else {
            return .failure(.notASingleQuery(reason: "语句里有多条命令（出现了分号分隔）"))
        }
        guard let firstWord = leadingKeyword(statement) else {
            return .failure(.notASingleQuery(reason: "语句为空"))
        }
        let allowed: Set<String> = ["select", "with", "table", "values", "("]
        guard allowed.contains(firstWord) else {
            return .failure(.notASingleQuery(reason: "以 \(firstWord.uppercased()) 开头 —— 游标只能用于查询"))
        }

        return .success(CursorPagingPlan(
            cursorName: cursorName,
            pageSize: pageSize,
            beginStatement: "BEGIN",
            commitStatement: "COMMIT",
            rollbackStatement: "ROLLBACK",
            declareStatement: "DECLARE \(quoteIdentifier(cursorName)) CURSOR FOR \(statement)",
            closeStatement: "CLOSE \(quoteIdentifier(cursorName))"
        ))
    }

    // MARK: - 内部

    /// 去掉一个结尾分号；若还有分号 → nil（多条语句）。
    static func singleStatement(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(";") {
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty, !text.contains(";") else { return nil }
        return text
    }

    /// 首个关键字（跳过开头的注释与空白）。
    static func leadingKeyword(_ statement: String) -> String? {
        var index = statement.startIndex
        while index < statement.endIndex {
            let character = statement[index]

            if character.isWhitespace {
                index = statement.index(after: index)
                continue
            }
            // 行注释
            if character == "-", statement.index(after: index) < statement.endIndex,
               statement[statement.index(after: index)] == "-" {
                while index < statement.endIndex, statement[index] != "\n" {
                    index = statement.index(after: index)
                }
                continue
            }
            // 块注释
            if character == "/", statement.index(after: index) < statement.endIndex,
               statement[statement.index(after: index)] == "*" {
                index = statement.index(index, offsetBy: 2)
                while index < statement.endIndex {
                    if statement[index] == "*", statement.index(after: index) < statement.endIndex,
                       statement[statement.index(after: index)] == "/" {
                        index = statement.index(index, offsetBy: 2)
                        break
                    }
                    index = statement.index(after: index)
                }
                continue
            }

            // 括号开头的查询 `(SELECT …)` 也要放行：把 `(` 当成一个独立关键字返回，
            // 不要把后面的字母一起吞进来（本轮实测：`(SELECT 1)` 曾被判成"(select 不是查询"）。
            if character == "(" { return "(" }

            let start = index
            while index < statement.endIndex,
                  statement[index].isLetter || statement[index] == "_" {
                index = statement.index(after: index)
            }
            return String(statement[start..<index]).lowercased()
        }
        return nil
    }

    /// 游标名走标识符加引号（异常字符不会变成语法）。
    public static func quoteIdentifier(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
