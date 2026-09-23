import Foundation

/// SQL 里的**查询参数**（FR-EXEC-17）。
///
/// 解决什么问题：手写 `WHERE name = '" + input + "'` 是 SQL 注入与"引号地狱"的根源。
/// 参数化让使用者写 `WHERE name = :name`，执行前填值，由这里做**类型化转义**。
///
/// 三条纪律：
/// 1. **不提供"原样插入"类型** —— 那是把注入入口重新打开。只有文本 / 数字 / 布尔 / NULL 四种，
///    每种都有明确的转义或校验规则。
/// 2. **识别占位符要跳过字符串、注释与 dollar-quote** —— `SELECT 'a :name b'` 里的 `:name`
///    是数据不是占位符。这条错了会把用户的数据悄悄改掉，比报错严重得多。
/// 3. **缺值就报错并说清缺哪个** —— 绝不"没填就当成空串"。
public enum SQLParameters {

    /// 参数类型。**故意没有 raw / 原样**。
    public enum ValueType: String, Sendable, CaseIterable {
        case text
        case number
        case boolean
        case null

        public var displayName: String {
            switch self {
            case .text: return "text"
            case .number: return "number"
            case .boolean: return "boolean"
            case .null: return "null"
            }
        }
    }

    /// 一个待填参数。
    public struct Parameter: Equatable, Sendable, Hashable {
        /// `:name` 的名字（不含冒号）；位置参数（`$1`）时为 nil。
        public var name: String?
        /// 位置参数的序号（1 起）；命名参数时为 nil。
        public var position: Int?

        /// 界面上的标识：`name` 或 `$1`。
        public var identifier: String {
            if let name { return name }
            if let position { return "$\(position)" }
            return "?"
        }

        /// 是否是位置参数。
        public var isPositional: Bool { position != nil }
    }

    /// 绑定失败的原因（都带可读信息，界面直接展示）。
    public enum BindError: Error, Equatable, LocalizedError {
        case missingValues([String])
        case invalidNumber(name: String, value: String)
        case invalidBoolean(name: String, value: String)
        case emptyTextNotAllowed(name: String)

        public var errorDescription: String? {
            switch self {
            case .missingValues(let names):
                return "还有参数没填值：\(names.joined(separator: "、"))"
            case .invalidNumber(let name, let value):
                return "参数 \(name) 声明为 number，但值是「\(value)」——不是合法数字"
            case .invalidBoolean(let name, let value):
                return "参数 \(name) 声明为 boolean，但值是「\(value)」——只能是 true / false"
            case .emptyTextNotAllowed(let name):
                return "参数 \(name) 不允许为空"
            }
        }
    }

    /// 绑定结果。
    public struct Bound: Equatable, Sendable {
        /// 替换后的 SQL。
        public var sql: String
        /// 填了值但 SQL 里没用到（多半是拼错名字）—— 提示用，不报错。
        public var unusedNames: [String]
    }

    // MARK: - 提取

    /// 提取 SQL 里的参数（按出现顺序，重复的合并）。
    ///
    /// 只认**代码区**里的占位符：字符串、注释、dollar-quote 里的 `:name` 一律不认。
    public static func extract(from sql: String) -> [Parameter] {
        let codeRanges = SQLLexer.codeRanges(in: sql)
        var named: [String] = []
        var positional: [Int] = []

        for range in codeRanges {
            let segment = String(sql[range])
            for token in tokens(in: segment) {
                switch token {
                case .named(let name):
                    if !named.contains(name) { named.append(name) }
                case .positional(let index):
                    if !positional.contains(index) { positional.append(index) }
                }
            }
        }

        return named.map { Parameter(name: $0, position: nil) }
            + positional.sorted().map { Parameter(name: nil, position: $0) }
    }

    /// 该 SQL 是否需要填参数。
    public static func hasParameters(_ sql: String) -> Bool { !extract(from: sql).isEmpty }

    // MARK: - 绑定

    /// 把值绑进 SQL。`values` 的键是 `Parameter.identifier`（`name` 或 `$1`）。
    ///
    /// 文本走 `'…'` 包裹 + 单引号双写；数字**先校验再原样写**；布尔写 TRUE/FALSE；null 写 NULL。
    public static func bind(
        sql: String,
        values: [String: (type: ValueType, raw: String)],
        unknownValue: ValueType = .text
    ) -> Result<Bound, BindError> {
        let parameters = extract(from: sql)
        guard !parameters.isEmpty else {
            return .success(Bound(sql: sql, unusedNames: values.keys.sorted()))
        }

        // 缺值先报错：一次把所有缺的都说出来，避免"填一个报一个"。
        let missing = parameters
            .filter { values[$0.identifier] == nil }
            .map(\.identifier)
        guard missing.isEmpty else { return .failure(.missingValues(missing)) }

        var rendered: [String: String] = [:]
        for parameter in parameters {
            guard let entry = values[parameter.identifier] else { continue }
            switch render(entry, name: parameter.identifier) {
            case .failure(let error): return .failure(error)
            case .success(let text): rendered[parameter.identifier] = text
            }
        }

        // 替换只发生在**代码区**：逐段处理，字符串与注释原样保留。
        var output = ""
        var cursor = sql.startIndex
        for range in SQLLexer.codeRanges(in: sql) {
            output += sql[cursor..<range.lowerBound]
            var segment = ""
            var index = range.lowerBound
            while index < range.upperBound {
                if let match = matchToken(in: sql, at: index, limit: range.upperBound) {
                    segment += rendered[match.identifier] ?? match.raw
                    index = match.end
                } else {
                    segment.append(sql[index])
                    index = sql.index(after: index)
                }
            }
            output += segment
            cursor = range.upperBound
        }
        output += sql[cursor...]

        let used = Set(parameters.map(\.identifier))
        let unused = values.keys.filter { !used.contains($0) }.sorted()
        return .success(Bound(sql: output, unusedNames: unused))
    }

    /// 便捷入口：全部按文本类型绑定（界面上的默认）。
    public static func bind(sql: String, textValues: [String: String]) -> Result<Bound, BindError> {
        bind(sql: sql, values: textValues.mapValues { (type: ValueType.text, raw: $0) })
    }

    // MARK: - 渲染

    private static func render(
        _ entry: (type: ValueType, raw: String),
        name: String
    ) -> Result<String, BindError> {
        switch entry.type {
        case .text:
            // 空串是合法文本（`= ''` 有意义），这里不拦；留这个分支是为将来"必填"标记。
            return .success("'" + entry.raw.replacingOccurrences(of: "'", with: "''") + "'")

        case .number:
            // 先校验再原样写：**不做字符串包裹**，否则数据库会把数字当文本比较（索引失效）。
            guard isNumericLiteral(entry.raw) else {
                return .failure(.invalidNumber(name: name, value: entry.raw))
            }
            return .success(entry.raw.trimmingCharacters(in: .whitespaces))

        case .boolean:
            switch entry.raw.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "t", "1", "yes": return .success("TRUE")
            case "false", "f", "0", "no": return .success("FALSE")
            default: return .failure(.invalidBoolean(name: name, value: entry.raw))
            }

        case .null:
            return .success("NULL")
        }
    }

    /// 合法数字字面量（可带正负号与小数点，不接受空串与 `1,000` 这类）。
    static func isNumericLiteral(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return Double(trimmed) != nil
    }

    // MARK: - 词法

    enum Token: Equatable {
        case named(String)
        case positional(Int)
    }

    /// 在**纯代码片段**里找占位符（不含字符串 / 注释）。
    static func tokens(in segment: String) -> [Token] {
        var result: [Token] = []
        var index = segment.startIndex
        while index < segment.endIndex {
            let character = segment[index]

            if character == ":" {
                let next = segment.index(after: index)
                // `::` 是类型转换（`x::text`），不是参数。
                if next < segment.endIndex, segment[next] == ":" {
                    index = segment.index(after: next)
                    continue
                }
                var cursor = next
                var name = ""
                while cursor < segment.endIndex,
                      segment[cursor].isLetter || segment[cursor].isNumber || segment[cursor] == "_" {
                    name.append(segment[cursor])
                    cursor = segment.index(after: cursor)
                }
                if !name.isEmpty {
                    result.append(.named(name))
                    index = cursor
                    continue
                }
            }

            if character == "$" {
                var cursor = segment.index(after: index)
                var digits = ""
                while cursor < segment.endIndex, segment[cursor].isNumber {
                    digits.append(segment[cursor])
                    cursor = segment.index(after: cursor)
                }
                if !digits.isEmpty, let value = Int(digits) {
                    result.append(.positional(value))
                    index = cursor
                    continue
                }
            }

            index = segment.index(after: index)
        }
        return result
    }

    struct Match {
        var identifier: String
        var raw: String
        var end: String.Index
    }

    /// 在 `index` 处匹配一个占位符（用于替换阶段）。
    static func matchToken(in sql: String, at index: String.Index, limit: String.Index) -> Match? {
        let character = sql[index]
        guard character == ":" || character == "$" else { return nil }

        if character == ":" {
            let next = sql.index(after: index)
            guard next < limit, sql[next] != ":" else { return nil }
            var cursor = next
            var name = ""
            while cursor < limit, sql[cursor].isLetter || sql[cursor].isNumber || sql[cursor] == "_" {
                name.append(sql[cursor])
                cursor = sql.index(after: cursor)
            }
            guard !name.isEmpty else { return nil }
            return Match(identifier: name, raw: String(sql[index..<cursor]), end: cursor)
        }

        var cursor = sql.index(after: index)
        var digits = ""
        while cursor < limit, sql[cursor].isNumber {
            digits.append(sql[cursor])
            cursor = sql.index(after: cursor)
        }
        guard !digits.isEmpty else { return nil }
        return Match(identifier: "$\(digits)", raw: String(sql[index..<cursor]), end: cursor)
    }
}
