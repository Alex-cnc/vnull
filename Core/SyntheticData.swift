import Foundation

// MARK: - 确定性随机源

/// 可播种的确定性随机源（SplitMix64）（FR-AI-07）。
///
/// 系统随机源不可播种，而验收要点要求「同参数可复现」——同一个 seed 必须给出同一批行。
/// 因此这里自备一个纯函数式 PRNG：同一 seed 在任何机器、任何次数上都产生相同序列。
public struct SeededRandomGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - specs

/// 合成数据的一个列生成规则（FR-AI-07）。
public enum ColumnGenerator: Equatable, Sendable, Codable {
    /// 自增序列：天然满足唯一约束。
    case sequence(start: Int, step: Int)
    /// 区间内整数。
    case integer(min: Int, max: Int)
    /// 区间内小数，按 `precision` 位四舍五入。
    case decimal(min: Double, max: Double, precision: Int)
    /// 布尔，取真概率 `trueProbability`。
    case boolean(trueProbability: Double)
    /// 随机字母数字文本，长度在区间内。
    case text(minLength: Int, maxLength: Int)
    /// 从候选值中选择。
    case choice(values: [String])
    /// 带权选择。
    case weightedChoice(values: [WeightedValue])
    /// 形如 `user1234@example.com`。
    case email
    /// 形如 `张三`/`Alice` 的示例姓名。
    case fullName
    /// `lastDays` 天内的日期（相对固定基准日，保证可复现）。
    case date(lastDays: Int)
    /// `lastDays` 天内的时刻。
    case timestamp(lastDays: Int)
    /// 随机 UUID（版本 4 形状）。
    case uuid
    /// 常量。
    case constant(String)

    /// 带权候选值。
    public struct WeightedValue: Equatable, Sendable, Codable {
        public var value: String
        public var weight: Double

        public init(value: String, weight: Double) {
            self.value = value
            self.weight = weight
        }
    }

    /// 该规则是否天生唯一（序列）。
    var isInherentlyUnique: Bool {
        if case .sequence = self { return true }
        return false
    }
}

/// 一列的定义。
public struct ColumnSpec: Equatable, Sendable, Codable {
    public var name: String
    public var generator: ColumnGenerator
    /// 该列为 NULL 的概率（0...1）；0 表示永不为空，满足 NOT NULL 约束。
    public var nullProbability: Double
    /// 该列取值必须唯一（满足唯一约束）。
    public var isUnique: Bool

    public init(
        name: String,
        generator: ColumnGenerator,
        nullProbability: Double = 0,
        isUnique: Bool = false
    ) {
        self.name = name
        self.generator = generator
        self.nullProbability = nullProbability
        self.isUnique = isUnique
    }
}

/// 一张表的合成数据规格（FR-AI-07 的 specs）。
public struct SyntheticTableSpec: Equatable, Sendable, Codable {
    public var table: String
    public var schema: String?
    public var columns: [ColumnSpec]
    public var rowCount: Int
    /// 随机种子：**同 seed + 同 specs ⇒ 完全相同的行**。
    public var seed: UInt64

    public init(
        table: String,
        schema: String? = nil,
        columns: [ColumnSpec],
        rowCount: Int,
        seed: UInt64
    ) {
        self.table = table
        self.schema = schema
        self.columns = columns
        self.rowCount = rowCount
        self.seed = seed
    }

    /// 生成时使用的固定时间基准。
    ///
    /// 用常量而不是 `Date()`：否则同 seed 在昨天和今天会生成不同的日期列，「可复现」就名存实亡。
    public static let referenceDate = Date(timeIntervalSince1970: 1_577_836_800) // 2020-01-01T00:00:00Z
}

/// 生成失败的原因。
public enum SyntheticDataError: Error, Equatable, LocalizedError {
    case invalidSpec([String])
    /// 唯一约束在给定规则下无法满足（候选值不够 / 区间太窄）。
    case uniqueConstraintUnsatisfiable(column: String, rowCount: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidSpec(let issues):
            return "合成数据规格有误：" + issues.joined(separator: " ")
        case .uniqueConstraintUnsatisfiable(let column, let rowCount):
            return "列 \(column) 要求 \(rowCount) 个互不相同的值，但当前生成规则无法提供。"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .invalidSpec:
            return "请修正列定义或行数后重试。"
        case .uniqueConstraintUnsatisfiable:
            return "请放宽取值范围、改用序列规则，或减少行数。"
        }
    }
}

// MARK: - 生成

/// 合成数据生成（FR-AI-07）。
///
/// - **可复现**：一切随机都走 `SeededRandomGenerator`，日期也相对固定基准日计算；
///   生成过程不读时钟、不读系统随机源，因此同 specs + 同 seed 必然给出同一批行；
/// - **约束满足**：`nullProbability = 0` 保证非空，`isUnique` 保证列内不重复，
///   区间 / 精度 / 候选集都严格生效；唯一性无法满足时**报错**而不是悄悄产生重复值；
/// - **写库走审批**：本类型只生成文本与语句，写入前必须经 `AgentApproval`（FR-AI-07 / FR-AI-09）。
public enum SyntheticDataGenerator {

    /// 规格校验（生成前拦一道）。
    public static func issues(in spec: SyntheticTableSpec) -> [String] {
        var issues: [String] = []

        if spec.table.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("表名不能为空。")
        }
        if spec.columns.isEmpty {
            issues.append("至少要定义一列。")
        }
        if spec.rowCount < 0 {
            issues.append("行数不能为负。")
        }

        var seen: Set<String> = []
        for column in spec.columns {
            let name = column.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                issues.append("列名不能为空。")
            } else if !seen.insert(name).inserted {
                issues.append("列名重复：\(name)。")
            }
            if !(0...1).contains(column.nullProbability) {
                issues.append("列 \(name) 的 NULL 概率必须在 0 到 1 之间。")
            }
            issues.append(contentsOf: generatorIssues(column.generator, column: name))
        }

        return issues
    }

    private static func generatorIssues(_ generator: ColumnGenerator, column: String) -> [String] {
        switch generator {
        case .sequence(_, let step):
            return step == 0 ? ["列 \(column) 的序列步长不能为 0。"] : []
        case .integer(let min, let max):
            return min > max ? ["列 \(column) 的整数区间上下界颠倒。"] : []
        case .decimal(let min, let max, let precision):
            var issues: [String] = []
            if min > max { issues.append("列 \(column) 的小数区间上下界颠倒。") }
            if precision < 0 || precision > 12 { issues.append("列 \(column) 的小数位数必须在 0 到 12 之间。") }
            return issues
        case .boolean(let probability):
            return (0...1).contains(probability) ? [] : ["列 \(column) 的真值概率必须在 0 到 1 之间。"]
        case .text(let minLength, let maxLength):
            var issues: [String] = []
            if minLength < 0 || maxLength < 0 { issues.append("列 \(column) 的文本长度不能为负。") }
            if minLength > maxLength { issues.append("列 \(column) 的文本长度区间上下界颠倒。") }
            return issues
        case .choice(let values):
            return values.isEmpty ? ["列 \(column) 的候选值不能为空。"] : []
        case .weightedChoice(let values):
            if values.isEmpty { return ["列 \(column) 的候选值不能为空。"] }
            if values.contains(where: { $0.weight < 0 }) { return ["列 \(column) 的权重不能为负。"] }
            if values.allSatisfy({ $0.weight == 0 }) { return ["列 \(column) 的权重不能全为 0。"] }
            return []
        case .date(let lastDays), .timestamp(let lastDays):
            return lastDays < 0 ? ["列 \(column) 的天数不能为负。"] : []
        case .email, .fullName, .uuid, .constant:
            return []
        }
    }

    public static func isValid(_ spec: SyntheticTableSpec) -> Bool {
        issues(in: spec).isEmpty
    }

    /// 生成行（FR-AI-07）。
    ///
    /// - Returns: 每行按 `spec.columns` 顺序给出字符串值；NULL 用 `nil` 表示。
    /// - Throws: 规格非法，或唯一约束无法满足。
    public static func generate(_ spec: SyntheticTableSpec) throws -> [[String?]] {
        let issues = issues(in: spec)
        guard issues.isEmpty else {
            throw SyntheticDataError.invalidSpec(issues)
        }

        var generator = SeededRandomGenerator(seed: spec.seed)
        var sequenceCounters: [String: Int] = [:]
        var seenValues: [String: Set<String>] = [:]

        var rows: [[String?]] = []
        rows.reserveCapacity(spec.rowCount)

        for _ in 0..<spec.rowCount {
            var row: [String?] = []
            row.reserveCapacity(spec.columns.count)

            for column in spec.columns {
                // 先决定是否 NULL：`nullProbability = 0` 时永不为空（满足 NOT NULL）。
                if column.nullProbability > 0, Double.random(in: 0..<1, using: &generator) < column.nullProbability {
                    row.append(nil)
                    continue
                }
                row.append(
                    try value(
                        for: column,
                        generator: &generator,
                        sequenceCounters: &sequenceCounters,
                        seenValues: &seenValues
                    )
                )
            }
            rows.append(row)
        }

        return rows
    }

    private static func value(
        for column: ColumnSpec,
        generator: inout SeededRandomGenerator,
        sequenceCounters: inout [String: Int],
        seenValues: inout [String: Set<String>]
    ) throws -> String {
        // 唯一列最多重试若干次；仍失败则报错，绝不静默产生重复值。
        let maxAttempts = column.isUnique ? 64 : 1
        var attempt = 0

        while attempt < maxAttempts {
            attempt += 1
            let value = rawValue(
                for: column.generator,
                generator: &generator,
                sequenceCounters: &sequenceCounters,
                columnName: column.name
            )
            guard column.isUnique else { return value }

            if seenValues[column.name, default: []].insert(value).inserted {
                return value
            }
        }

        throw SyntheticDataError.uniqueConstraintUnsatisfiable(column: column.name, rowCount: maxAttempts)
    }

    private static func rawValue(
        for generator: ColumnGenerator,
        generator random: inout SeededRandomGenerator,
        sequenceCounters: inout [String: Int],
        columnName: String
    ) -> String {
        switch generator {
        case .sequence(let start, let step):
            let index = sequenceCounters[columnName, default: 0]
            sequenceCounters[columnName] = index + 1
            return String(start + index * step)

        case .integer(let min, let max):
            return String(Int.random(in: min...max, using: &random))

        case .decimal(let min, let max, let precision):
            let value = Double.random(in: min...max, using: &random)
            return String(format: "%.\(precision)f", value)

        case .boolean(let trueProbability):
            return Double.random(in: 0..<1, using: &random) < trueProbability ? "true" : "false"

        case .text(let minLength, let maxLength):
            let length = Int.random(in: minLength...maxLength, using: &random)
            let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
            return String((0..<length).map { _ in alphabet.randomElement(using: &random)! })

        case .choice(let values):
            return values.randomElement(using: &random)!

        case .weightedChoice(let values):
            let total = values.reduce(0.0) { $0 + $1.weight }
            var threshold = Double.random(in: 0..<total, using: &random)
            for candidate in values {
                threshold -= candidate.weight
                if threshold < 0 { return candidate.value }
            }
            return values.last!.value

        case .email:
            let suffix = Int.random(in: 1000...999_999, using: &random)
            return "user\(suffix)@example.com"

        case .fullName:
            let names = ["张伟", "李娜", "王强", "刘洋", "Alice", "Bob", "Carol", "David"]
            return names.randomElement(using: &random)!

        case .date(let lastDays):
            let offset = lastDays == 0 ? 0 : Int.random(in: 0...lastDays, using: &random)
            return Self.isoDate(secondsFromReference: -Double(offset) * 86_400).date

        case .timestamp(let lastDays):
            let offset = lastDays == 0 ? 0 : Int.random(in: 0...(lastDays * 86_400), using: &random)
            let parts = Self.isoDate(secondsFromReference: -Double(offset))
            return "\(parts.date) \(parts.time)"

        case .uuid:
            var bytes = [UInt8](repeating: 0, count: 16)
            for index in 0..<16 {
                bytes[index] = UInt8(truncatingIfNeeded: random.next())
            }
            bytes[6] = (bytes[6] & 0x0F) | 0x40 // 版本 4
            bytes[8] = (bytes[8] & 0x3F) | 0x80 // 变体
            let hex = bytes.map { String(format: "%02x", $0) }.joined()
            return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))"
                + "-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"

        case .constant(let value):
            return value
        }
    }

    // MARK: - 确定性时间格式化

    /// 把「相对基准日的秒数」格式化成 `yyyy-MM-dd HH:mm:ss`。
    ///
    /// 刻意不用 `DateFormatter`：它依赖 locale / 时区，且是类实例（在 Core 里做静态常量不安全）。
    /// 这里用纯整数运算（Howard Hinnant 的 civil_from_days），结果与语言环境无关、完全可复现。
    static func isoDate(secondsFromReference seconds: Double) -> (date: String, time: String) {
        let total = Int(seconds.rounded())
        let days = floorDiv(total, 86_400)
        let remainder = total - days * 86_400
        let hour = remainder / 3_600
        let minute = (remainder % 3_600) / 60
        let second = remainder % 60

        return (
            civilDate(daysSinceUnixEpoch: days + 18_262), // 2020-01-01 距 Unix 纪元的天数
            String(format: "%02d:%02d:%02d", hour, minute, second)
        )
    }

    /// 向下取整的整除（Swift 的 `/` 向零截断，负数会算错）。
    static func floorDiv(_ lhs: Int, _ rhs: Int) -> Int {
        let quotient = lhs / rhs
        return (lhs % rhs != 0 && ((lhs < 0) != (rhs < 0))) ? quotient - 1 : quotient
    }

    /// 自 Unix 纪元起的天数 → `yyyy-MM-dd`。
    static func civilDate(daysSinceUnixEpoch days: Int) -> String {
        let z = days + 719_468
        let era = floorDiv(z, 146_097)
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let year = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthPrime = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthPrime + 2) / 5 + 1
        let month = monthPrime < 10 ? monthPrime + 3 : monthPrime - 9
        let normalizedYear = month <= 2 ? year + 1 : year
        return String(format: "%04d-%02d-%02d", normalizedYear, month, day)
    }

    // MARK: - 写入路径（走审批）

    /// 生成 `INSERT` 语句（复用 `ResultExporter`，保证与导出格式一致）。
    public static func insertStatements(
        rows: [[String?]],
        spec: SyntheticTableSpec,
        writeMode: DataTaskDefinition.Target.WriteMode = .append,
        dialect: any SQLDialect = PostgresDialect()
    ) -> String? {
        guard !rows.isEmpty, !spec.columns.isEmpty else { return nil }

        let columns = spec.columns.enumerated().map { index, column in
            ColumnMeta(id: index, name: column.name, typeName: sqlTypeName(for: column.generator))
        }
        let result = QueryResult(columns: columns, rows: rows)
        let inserts = ResultExporter.insertStatements(
            for: result,
            tableName: spec.table,
            schema: spec.schema,
            dialect: dialect
        )
        guard !inserts.isEmpty else { return nil }

        guard writeMode == .overwrite else { return inserts }
        let target = qualifiedName(for: spec, dialect: dialect)
        return "TRUNCATE TABLE \(target);\n" + inserts
    }

    /// `COPY ... FROM STDIN` 语句（FR-AI-07「支持 `COPY` 路径」）。
    public static func copyFromStdinStatement(
        spec: SyntheticTableSpec,
        dialect: any SQLDialect = PostgresDialect()
    ) -> String? {
        guard !spec.columns.isEmpty, dialect.databaseType == .postgresql else { return nil }
        let target = qualifiedName(for: spec, dialect: dialect)
        let columns = spec.columns.map { dialect.quoteIdentifier($0.name) }.joined(separator: ", ")
        return "COPY \(target) (\(columns)) FROM STDIN WITH (FORMAT csv);"
    }

    /// `COPY` 的数据载荷（CSV，含表头）。
    public static func copyPayload(rows: [[String?]], spec: SyntheticTableSpec) -> String {
        let columns = spec.columns.enumerated().map { index, column in
            ColumnMeta(id: index, name: column.name, typeName: "text")
        }
        return ResultExporter.csv(
            for: QueryResult(columns: columns, rows: rows),
            includeByteOrderMark: false
        )
    }

    /// 为「写入目标表」建立审批单（FR-AI-07：写入走审批；只读模式下直接拒绝）。
    public static func writeApproval(
        sql: String,
        policy: AgentGuardPolicy = .approvalRequired,
        context: AgentActionRecord.Context = .none,
        at date: Date = Date()
    ) -> AgentApproval? {
        let assessment = AgentGuardrail.evaluate(sql: sql, databaseType: .postgresql, policy: policy)
        return AgentApproval.request(sql: sql, assessment: assessment, context: context, at: date)
    }

    /// 依据生成规则推断一个便于建表的 SQL 类型名。
    static func sqlTypeName(for generator: ColumnGenerator) -> String {
        switch generator {
        case .sequence, .integer: return "int8"
        case .decimal: return "numeric"
        case .boolean: return "bool"
        case .date: return "date"
        case .timestamp: return "timestamp"
        case .uuid: return "uuid"
        case .text, .choice, .weightedChoice, .email, .fullName, .constant: return "text"
        }
    }

    private static func qualifiedName(for spec: SyntheticTableSpec, dialect: any SQLDialect) -> String {
        guard let schema = spec.schema, !schema.isEmpty, dialect.featureSet.contains(.supportsSchemas) else {
            return dialect.quoteIdentifier(spec.table)
        }
        return "\(dialect.quoteIdentifier(schema)).\(dialect.quoteIdentifier(spec.table))"
    }
}
