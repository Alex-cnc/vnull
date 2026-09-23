import Foundation

/// 编辑器补全的**候选合并策略**（FR-AI-13 S4 的落地接口）。
///
/// 为什么把策略放在 Core 而不是直接在 `NSTextView` 回调里拼：
/// 补全列表的**顺序**与**准入条件**是这套功能里唯一能被用户直接感知的部分，
/// 却藏在 AppKit 回调里、只能靠手点验证。抽成纯函数后，"记忆会不会顶掉关键字"、
/// "空前缀会不会被记忆刷屏"、"同一条出现两次吗"这些问题都能用单测钉住。
///
/// 三条规则（都是**刻意的选择**，不是默认行为）：
///
/// 1. **方言候选在前，记忆在后**：`SELECT` / `COUNT` 的位置不能因为用户跑过什么查询而漂移；
///    肌肉记忆（盲打 F5 选第一个）比"更懂我"更值钱。
/// 2. **记忆只在有前缀时出现**：`QueryMemory.suggestions` 对空输入本来就返回空 ——
///    这里把它写成规则而不是巧合：打开补全先看到的是关键字，不是历史。
/// 3. **方言候选占满就不塞记忆**：候选上限是固定的，若关键字已经填满，
///    强行插入记忆等于**顶掉**关键字。记忆是补充，不是替代。
public enum QueryCompletion {

    /// 候选总数上限（与既有编辑器行为一致：一屏能看完）。
    public static let totalLimit = 20

    /// 记忆候选的**取数上限**：一次补全最多带几条历史。
    public static let memoryLimit = 5

    /// 可插入长度上限。
    ///
    /// 补全的动作是"**替换光标处的半个词**"。把一条 2 KB 的报表 SQL 灌进去，
    /// 用户得到的是满屏文本和一个要自己撤销的局面 —— 那不该叫补全。
    /// 超长的记忆仍可从归档、CLI `memory` 取用，只是不参与补全。
    public static let maxInsertableSQLLength = 500

    /// 编辑器补全候选。
    ///
    /// - Parameters:
    ///   - prefix: 光标处正在输入的词（可为空）。
    ///   - dialect: 当前方言（关键字 + 内置函数来自它，与语法高亮共用同一份定义）。
    ///   - memory: 查询记忆索引（FR-AI-13 S2；为空则行为与旧路径完全一致）。
    ///   - connection: 当前连接名；传了就只看这个连接的记忆（按连接隔离）。
    public static func suggestions(
        prefix: String,
        dialect: SQLDialect,
        memory: QueryMemory.Index = QueryMemory.Index(),
        connection: String? = nil
    ) -> [String] {
        let dialectCandidates = dialectMatches(prefix: prefix, dialect: dialect)
        let memoryCandidates = memoryMatches(prefix: prefix, in: memory, connection: connection)
        return merge(dialect: dialectCandidates, memory: memoryCandidates)
    }

    /// 方言层候选：空前缀给开头一批（保持原行为），有前缀按前缀过滤。
    public static func dialectMatches(prefix: String, dialect: SQLDialect) -> [String] {
        let candidates = dialect.keywords + dialect.builtinFunctions
        let normalized = prefix.uppercased()
        guard !normalized.isEmpty else { return Array(candidates.prefix(totalLimit)) }
        return candidates
            .filter { $0.uppercased().hasPrefix(normalized) }
            .sorted()
    }

    /// 记忆层候选：已经是"最有用在前"的顺序（见 `QueryMemory.suggestions`），
    /// 这里只做**可插入性**过滤与取数上限。
    public static func memoryMatches(
        prefix: String,
        in index: QueryMemory.Index,
        connection: String? = nil
    ) -> [String] {
        QueryMemory
            .suggestions(prefix: prefix, in: index, connection: connection, limit: memoryLimit * 2)
            .map(\.sql)
            .filter(isInsertable)
            .prefix(memoryLimit)
            .map { $0 }
    }

    /// 一条 SQL 是否适合当成补全项插入。
    ///
    /// 只有长度这一条判据：空白串与超长串都不合适，其余交给用户判断。
    public static func isInsertable(_ sql: String) -> Bool {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.count <= maxInsertableSQLLength
    }

    /// 合并并去重（**大小写不敏感**：`select` 与 `SELECT` 是同一条）。
    ///
    /// 先出现的胜出 —— 方言优先，于是记忆永远不会把关键字挤成重复项。
    /// 超出总上限的按顺序截断：方言在前，所以**只有方言没填满时记忆才进得来**。
    public static func merge(dialect: [String], memory: [String]) -> [String] {
        var seen = Set<String>()
        var merged: [String] = []
        for candidate in dialect + memory {
            let key = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            merged.append(candidate)
            if merged.count == totalLimit { break }
        }
        return merged
    }
}
