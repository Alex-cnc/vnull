import Foundation

// MARK: - 动作记录（NFR-AI-03）

/// 智能体发起的一次动作的留痕（FR-AI-09、NFR-AI-03）。
///
/// **没有密钥字段**：审计记录从类型上就装不下 API Key，
/// 导出时还会再过一遍 `AgentAudit.redacted` 作为兜底。
public struct AgentActionRecord: Codable, Equatable, Sendable, Identifiable {
    /// 结果状态。
    public enum Outcome: String, Codable, Equatable, Sendable, CaseIterable {
        /// 生成完成（**未执行**）。
        case generated
        /// 被护栏拒绝。
        case denied
        /// 等待人工批准。
        case pendingApproval
        /// 已批准（尚未执行）。
        case approved
        /// 人工拒绝。
        case rejected
        /// 审批超时失效。
        case expired
        /// 已执行。
        case executed
        /// 执行失败。
        case failed

        public var displayName: String {
            switch self {
            case .generated: return "已生成（未执行）"
            case .denied: return "被护栏拒绝"
            case .pendingApproval: return "待批准"
            case .approved: return "已批准"
            case .rejected: return "已拒绝"
            case .expired: return "已失效"
            case .executed: return "已执行"
            case .failed: return "执行失败"
            }
        }
    }

    public var id: UUID
    public var timestamp: Date
    /// 连接名（不记口令 / 不记完整连接串）。
    public var connectionName: String?
    public var database: String?
    /// 使用的模型名（NFR-AI-03 要求留存模型）。
    public var model: String?
    /// 动作对应的 SQL。
    public var sql: String
    public var statementKind: AgentStatementKind
    public var risk: AgentRiskLevel
    public var findings: [AgentGuardFinding]
    public var outcome: Outcome
    /// 附注：拒绝原因、失败信息等。
    public var detail: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        connectionName: String? = nil,
        database: String? = nil,
        model: String? = nil,
        sql: String,
        statementKind: AgentStatementKind,
        risk: AgentRiskLevel,
        findings: [AgentGuardFinding] = [],
        outcome: Outcome,
        detail: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.connectionName = connectionName
        self.database = database
        self.model = model
        self.sql = sql
        self.statementKind = statementKind
        self.risk = risk
        self.findings = findings
        self.outcome = outcome
        self.detail = detail
    }

    /// 动作所处的环境（连接 / 库 / 模型）。
    public struct Context: Codable, Equatable, Sendable {
        public var connectionName: String?
        public var database: String?
        public var model: String?

        public init(connectionName: String? = nil, database: String? = nil, model: String? = nil) {
            self.connectionName = connectionName
            self.database = database
            self.model = model
        }

        public static let none = Context()
    }

    /// 由护栏判定生成记录。
    public static func make(
        sql: String,
        assessment: AgentGuardAssessment,
        context: Context = .none,
        outcome: Outcome,
        detail: String? = nil,
        at date: Date = Date()
    ) -> AgentActionRecord {
        let statement = assessment.statements.first
        let findings = statement?.findings ?? assessment.documentFindings
        return AgentActionRecord(
            timestamp: date,
            connectionName: context.connectionName,
            database: context.database,
            model: context.model,
            sql: sql,
            statementKind: statement?.kind ?? .unknown,
            risk: statement?.risk ?? .low,
            findings: findings,
            outcome: outcome,
            detail: detail
        )
    }
}

// MARK: - 审批状态机（FR-AI-09）

/// 审批状态。
public enum AgentApprovalState: String, Codable, Equatable, Sendable, CaseIterable {
    case pending
    case approved
    case rejected
    case expired
    case executed
    case failed

    /// 是否还能继续流转。
    public var isTerminal: Bool {
        switch self {
        case .pending, .approved: return false
        case .rejected, .expired, .executed, .failed: return true
        }
    }

    public var displayName: String {
        switch self {
        case .pending: return "待批准"
        case .approved: return "已批准"
        case .rejected: return "已拒绝"
        case .expired: return "已失效"
        case .executed: return "已执行"
        case .failed: return "执行失败"
        }
    }
}

/// 审批流转错误。
public enum AgentApprovalError: Error, Equatable, LocalizedError {
    case invalidTransition(from: AgentApprovalState, to: AgentApprovalState)
    case notApproved(AgentApprovalState)

    public var errorDescription: String? {
        switch self {
        case .invalidTransition(let from, let to):
            return "非法状态流转：\(from.displayName) → \(to.displayName)。"
        case .notApproved(let state):
            return "未获批准（当前状态：\(state.displayName)），不能执行。"
        }
    }
}

/// 一次审批单（FR-AI-09）。
///
/// 状态机刻意做得严格：`pending → approved/rejected/expired`，
/// `approved → executed/failed`，其余一律拒绝。写操作**只能**沿这条路走，
/// 「黑箱自动执行」在状态机上就不成立（AC-AI-03）。
public struct AgentApproval: Equatable, Sendable, Identifiable {
    public let id: UUID
    public var record: AgentActionRecord
    public private(set) var state: AgentApprovalState
    public let createdAt: Date
    public private(set) var decidedAt: Date?
    /// 决策者标识（本机为登录用户名 /「本机用户」）。
    public private(set) var decidedBy: String?
    public private(set) var note: String?

    public init(
        id: UUID = UUID(),
        record: AgentActionRecord,
        state: AgentApprovalState = .pending,
        createdAt: Date = Date(),
        decidedAt: Date? = nil,
        decidedBy: String? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.record = record
        self.state = state
        self.createdAt = createdAt
        self.decidedAt = decidedAt
        self.decidedBy = decidedBy
        self.note = note
    }

    /// 当前是否处于「可执行」状态。
    public var canExecute: Bool { state == .approved }

    /// 是否需要人工确认。
    public var awaitsHumanDecision: Bool { state == .pending }

    // MARK: 工厂

    /// 依护栏判定创建审批单（FR-AI-09、AC-AI-02）。
    ///
    /// - 判定为 `.deny`：**不创建审批单**（连提出申请的机会都没有），返回 `nil`；
    /// - 判定为 `.requireApproval`：`.pending`，等人工决策；
    /// - 判定为 `.allow`：直接 `.approved`，附注「无需审批」。
    public static func request(
        sql: String,
        assessment: AgentGuardAssessment,
        context: AgentActionRecord.Context = .none,
        at date: Date = Date()
    ) -> AgentApproval? {
        switch assessment.verdict {
        case .deny:
            return nil
        case .requireApproval(let findings):
            let detail = findings.map(\.message).joined(separator: " ")
            let record = AgentActionRecord.make(
                sql: sql,
                assessment: assessment,
                context: context,
                outcome: .pendingApproval,
                detail: detail,
                at: date
            )
            return AgentApproval(record: record, state: .pending, createdAt: date)
        case .allow:
            let record = AgentActionRecord.make(
                sql: sql,
                assessment: assessment,
                context: context,
                outcome: .approved,
                detail: "无需审批（只读或无风险）",
                at: date
            )
            return AgentApproval(
                record: record,
                state: .approved,
                createdAt: date,
                decidedAt: date,
                decidedBy: "auto",
                note: "无需审批（只读或无风险）"
            )
        }
    }

    // MARK: 流转

    public mutating func approve(at date: Date = Date(), by decider: String? = nil, note: String? = nil) throws {
        try transition(to: .approved, at: date)
        decidedBy = decider
        self.note = note
        record.outcome = .approved
        record.detail = note
    }

    public mutating func reject(at date: Date = Date(), by decider: String? = nil, note: String? = nil) throws {
        try transition(to: .rejected, at: date)
        decidedBy = decider
        self.note = note
        record.outcome = .rejected
        record.detail = note ?? "人工拒绝"
    }

    /// 审批超时 / 被新请求取代时置为失效。
    public mutating func expire(at date: Date = Date(), note: String? = nil) throws {
        try transition(to: .expired, at: date)
        self.note = note
        record.outcome = .expired
        record.detail = note
    }

    public mutating func markExecuted(at date: Date = Date()) throws {
        try transition(to: .executed, at: date)
        record.outcome = .executed
        record.timestamp = date
    }

    public mutating func markFailed(at date: Date = Date(), detail: String? = nil) throws {
        try transition(to: .failed, at: date)
        record.outcome = .failed
        record.detail = detail
    }

    /// 所有流转的唯一入口：在这里集中校验合法性。
    private mutating func transition(to target: AgentApprovalState, at date: Date) throws {
        guard Self.allowedTransitions[state]?.contains(target) ?? false else {
            throw AgentApprovalError.invalidTransition(from: state, to: target)
        }
        state = target
        if target != .executed, target != .failed {
            decidedAt = date
        }
        if decidedAt == nil { decidedAt = date }
    }

    /// 合法流转表。
    public static let allowedTransitions: [AgentApprovalState: Set<AgentApprovalState>] = [
        .pending: [.approved, .rejected, .expired],
        .approved: [.executed, .failed],
        .rejected: [],
        .expired: [],
        .executed: [],
        .failed: []
    ]

    public static func canTransition(from: AgentApprovalState, to: AgentApprovalState) -> Bool {
        allowedTransitions[from]?.contains(to) ?? false
    }
}

// MARK: - 审计日志（NFR-AI-03）

/// 审计日志：追加式 JSONL，导出时脱敏。
///
/// 用 JSONL 而不是整体 JSON 数组：审计是**只追加**的，
/// 每来一条就重写整个文件既慢又有「写到一半」的风险。
public actor AgentAuditLog {
    public static let shared = AgentAuditLog()

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directoryURL: URL? = nil) {
        let baseURL: URL
        if let directoryURL {
            baseURL = directoryURL
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
            baseURL = applicationSupport.appendingPathComponent("PostgresClient", isDirectory: true)
        }

        self.fileURL = baseURL.appendingPathComponent("agent-audit.jsonl", isDirectory: false)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func fileLocation() -> URL {
        fileURL
    }

    /// 追加一条记录。
    public func append(_ record: AgentActionRecord) throws {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var line = try encoder.encode(record)
            line.append(0x0A)

            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: fileURL, options: [.atomic])
            }
        } catch {
            throw AppError.persistence(error.localizedDescription)
        }
    }

    /// 读取全部记录（按写入顺序）。
    public func entries() throws -> [AgentActionRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            return text
                .components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .compactMap { line in
                    guard let data = line.data(using: .utf8) else { return nil }
                    return try? decoder.decode(AgentActionRecord.self, from: data)
                }
        } catch {
            throw AppError.persistence(error.localizedDescription)
        }
    }

    public func removeAll() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            throw AppError.persistence(error.localizedDescription)
        }
    }

    // MARK: 导出

    /// 导出为 JSON 数组（**已脱敏**）。
    public func exportJSON() throws -> Data {
        let records = try entries()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(records)
        guard let text = String(data: data, encoding: .utf8) else { return data }
        return Data(AgentAudit.redacted(text).utf8)
    }

    /// 导出为 CSV（**已脱敏**）。
    public func exportCSV() throws -> String {
        let header = [
            "timestamp", "connection", "database", "model",
            "statement_kind", "risk", "findings", "outcome", "sql", "detail"
        ].joined(separator: ",")

        let formatter = ISO8601DateFormatter()
        var lines = [header]
        for record in try entries() {
            let fields = [
                formatter.string(from: record.timestamp),
                record.connectionName ?? "",
                record.database ?? "",
                record.model ?? "",
                record.statementKind.rawValue,
                record.risk.rawValue,
                record.findings.map(\.rawValue).joined(separator: "|"),
                record.outcome.rawValue,
                record.sql,
                record.detail ?? ""
            ]
            lines.append(fields.map { ResultExporter.escapeCSVField($0) }.joined(separator: ","))
        }
        return AgentAudit.redacted(lines.joined(separator: "\n") + "\n")
    }
}

/// 审计导出前的脱敏（NFR-AI-03）。
///
/// 审计模型里本来就没有密钥字段，这里是**兜底**：SQL 文本或失败信息里
/// 可能夹带 `sk-...`、`Bearer ...`、`api_key=...` 这类片段，导出前统一抹掉。
public enum AgentAudit {

    /// 脱敏占位符。
    public static let redactionPlaceholder = "[REDACTED]"

    /// 形似密钥的片段。
    static let secretPatterns: [String] = [
        // Bearer <token>
        "(?i)\\bbearer\\s+[A-Za-z0-9._\\-]{8,}",
        // sk-... / pk-... / rk-...
        "\\b[spr]k-[A-Za-z0-9._\\-]{8,}",
        // key = value 形式（api_key / apikey / password / secret / token），
        // 兼容 JSON 里 `"apiKey":"..."` 这种带引号的写法。
        "(?i)\\b(api[_-]?key|apikey|password|passwd|secret|access[_-]?token|token)[\"']?\\s*[:=]\\s*[\"']?[^\\s\"',;]{8,}"
    ]

    /// 把形似密钥的片段替换为占位符。
    public static func redacted(_ text: String) -> String {
        var output = text
        for pattern in secretPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = regex.stringByReplacingMatches(
                in: output,
                options: [],
                range: range,
                withTemplate: redactionPlaceholder
            )
        }
        return output
    }

    /// 文本里是否还能找到密钥痕迹（导出后的自检）。
    public static func containsSecretLikeText(_ text: String) -> Bool {
        redacted(text) != text
    }
}
