import Foundation

/// 出网类别（NFR-SEC-08）。
///
/// **新增任何出网入口时都要在这里加一档** —— 否则日志会漏，而"漏掉的出网"正是这份日志
/// 要防的事。目前只有智能体模型调用是一等公民；浏览器与外部程序按需求书 FR-EDIT-34 /
/// NFR-SEC-08 登记在案，实现时接入。
public enum EgressKind: String, Codable, CaseIterable, Sendable {
    /// 智能体模型调用（自然语言生成 SQL / 数据任务规格）。
    case agentModel
    /// 内嵌浏览器导航与子资源（FR-EDIT-34，待实现）。
    case browser
    /// 外部程序调用（`pg_dump` / `pg_restore` / `ssh` 等）。
    case externalProgram
    /// 更新检查。
    case updateCheck
}

/// 一次出网的结局。
///
/// **`denied` 必须存在**：被闸门拦下的请求同样要留痕 ——「想发但没发出去」与「根本没想发」
/// 是两件事，只记后者会让"零外发"这句话无法被审计。
public enum EgressOutcome: String, Codable, Sendable {
    /// 已向目标发出（是否成功另见 `failed`）。
    case allowed
    /// 被本机的闸门/策略拦下，**数据并未离开本机**。
    case denied
    /// 发出但失败（网络错误、超时、非 2xx…）。
    case failed
}

/// 一条外发记录。字段与需求书 NFR-SEC-08 一一对应：时间 / 目标 / 触发来源 / 结果（+ 可读补充）。
public struct EgressEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let kind: EgressKind
    /// 目标：主机或 `scheme://host/path`（**已去掉 query / fragment**，见 `EgressTarget.sanitize`）。
    public let target: String
    /// 触发来源：哪个功能、哪个页签或会话。例如「智能体 · 自然语言生成 SQL」。
    public let origin: String
    public let outcome: EgressOutcome
    /// 可读补充（失败原因等）。**不得包含密钥或结果集行数据**（写入前统一脱敏）。
    public let detail: String?
    /// 这条出网属于哪个**浏览器页签**（FR-EDIT-34）。非浏览器来源为 nil。
    ///
    /// 为什么要它：一个窗口里可能同时开着好几个页签，日志只有"浏览器 · 页签"这句来源时，
    /// 根本分不清是哪一次浏览发出的请求 —— 而"这条外发是谁发起的"正是审计要回答的第一个问题。
    public let tabID: UUID?
    /// 页签的显示名（页面标题或地址），用于日志筛选与阅读；同样可空。
    public let tabTitle: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        kind: EgressKind,
        target: String,
        origin: String,
        outcome: EgressOutcome,
        detail: String? = nil,
        tabID: UUID? = nil,
        tabTitle: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.target = target
        self.origin = origin
        self.outcome = outcome
        self.detail = detail
        self.tabID = tabID
        self.tabTitle = tabTitle
    }
}

/// 目标净化：**只保留 scheme 与 host + path**。
///
/// 为什么必须去掉 query 与 fragment：那两处最常见地带着密钥与令牌
/// （`…/chat/completions?api_key=sk-…`、`#access_token=…`）。日志要能长期保存，
/// 就不能把密钥顺手抄进去 —— 这是"审计日志自身不能成为泄漏源"的底线。
public enum EgressTarget {
    public static func sanitize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // 非 URL 形态（例如外部程序名 `pg_dump`）：原样返回，但同样走一次脱敏。
        guard var components = URLComponents(string: trimmed), components.host != nil else {
            return AgentAudit.redacted(trimmed)
        }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        let rendered = components.string ?? trimmed
        return AgentAudit.redacted(rendered)
    }
}

/// 统一外发日志（NFR-SEC-08）。
///
/// **一句话契约**：所有离开本机的网络请求，写进**同一份**可查看 / 可导出 / 可清空的日志。
///
/// 为什么要有它：产品对外最核心的承诺是"默认零外发、最小外发"。在只有智能体一个出网入口时，
/// 这条承诺可以靠"总开关默认关闭"来保证；一旦能加载任意网页（FR-EDIT-34），
/// 承诺就必须**可观测**才成立 —— 先装计量表，再开门。
///
/// 与 `AgentAuditLog` 的分工（**故意不合并**）：
///   · 审计日志记的是**动作与审批**（谁批准了什么语句）；
///   · 外发日志记的是**出网请求**（数据去了哪里）。
/// 一次动作可能产生零次或多次出网请求，粒度不同，硬合并会让两边都变含糊。
public actor EgressLog {
    public static let shared = EgressLog()

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directoryURL: URL? = nil) {
        let baseURL: URL
        if let directoryURL {
            baseURL = directoryURL
        } else if let override = ProcessInfo.processInfo.environment["DOYAH_EGRESS_LOG_DIR"],
                  !override.trimmingCharacters(in: .whitespaces).isEmpty {
            // 目录可覆盖（与口令文件同一思路）：**沙箱 / 受限环境里要能验证"日志真的写下来了"**。
            // 本轮实测踩到过：CLI 在受限 shell 里写 `~/Library/Application Support` 被拒，
            // 于是"外发日志"这条证据拿不到 —— 日志写入失败本身只打一行警告（不该让主流程失败），
            // 但**验证脚本必须能指定一个可写目录**。
            baseURL = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
            baseURL = applicationSupport.appendingPathComponent(
                DoyahIdentity.applicationSupportDirectoryName,
                isDirectory: true
            )
        }

        self.fileURL = baseURL.appendingPathComponent("egress-log.jsonl", isDirectory: false)

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

    /// 追加一条记录（写入前统一脱敏，落盘失败不抛给调用方 —— 记日志失败不该打断用户的操作）。
    public func append(_ entry: EgressEntry) {
        let sanitized = EgressEntry(
            id: entry.id,
            timestamp: entry.timestamp,
            kind: entry.kind,
            target: EgressTarget.sanitize(entry.target),
            origin: AgentAudit.redacted(entry.origin),
            outcome: entry.outcome,
            detail: entry.detail.map { AgentAudit.redacted($0) }
        )

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard let data = try? encoder.encode(sanitized) else { return }
            var line = data
            line.append(0x0A)

            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: fileURL, options: .atomic)
            }
        } catch {
            EgressDiagnostics.warning("外发日志写入失败：\(error.localizedDescription)")
        }
    }

    /// 记一条并把它返回（便于调用方断言/展示）。
    @discardableResult
    public func record(
        kind: EgressKind,
        target: String,
        origin: String,
        outcome: EgressOutcome,
        detail: String? = nil,
        tabID: UUID? = nil,
        tabTitle: String? = nil
    ) -> EgressEntry {
        let entry = EgressEntry(
            kind: kind,
            target: target,
            origin: origin,
            outcome: outcome,
            detail: detail,
            tabID: tabID,
            tabTitle: tabTitle
        )
        append(entry)
        return entry
    }

    /// 读取记录（新的在前）。
    public func entries(limit: Int? = nil) throws -> [EgressEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let parsed: [EgressEntry] = text
            .split(separator: "\n")
            .compactMap { line in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(EgressEntry.self, from: data)
            }
        let ordered = parsed.sorted { $0.timestamp > $1.timestamp }
        guard let limit, limit > 0 else { return ordered }
        return Array(ordered.prefix(limit))
    }

    public func count() throws -> Int {
        try entries().count
    }

    /// 清空日志。**文件保留为空**（不留"曾经有过记录"的歧义）。
    public func clear() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    public func exportJSON() throws -> Data {
        let entries = try entries()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entries)
        // 双保险：导出内容再过一次脱敏（防止历史文件里已有旧格式的敏感内容）。
        guard let text = String(data: data, encoding: .utf8) else { return data }
        return Data(AgentAudit.redacted(text).utf8)
    }

    public func exportCSV() throws -> String {
        let formatter = ISO8601DateFormatter()
        var lines = [Self.csvColumns.joined(separator: ",")]
        for entry in try entries() {
            let fields = [
                formatter.string(from: entry.timestamp),
                entry.kind.rawValue,
                entry.target,
                entry.origin,
                entry.outcome.rawValue,
                entry.detail ?? ""
            ]
            lines.append(fields.map { ResultExporter.escapeCSVField($0) }.joined(separator: ","))
        }
        return AgentAudit.redacted(lines.joined(separator: "\n") + "\n")
    }

    static let csvColumns = ["时间", "类别", "目标", "触发来源", "结果", "补充"]
}

/// HTTP 出网装饰器：**所有走 `HTTPTransport` 的出网都从这里过**。
///
/// 为什么包在传输层而不是在各个调用点：调用点会越加越多（生成 SQL、数据任务规格、
/// 将来还有诊断与摘要），漏掉一个就是一个"没有记录的出网"。包在唯一的缝上，
/// 新调用方默认就被记录。
public struct EgressRecordingTransport: HTTPTransport {
    private let origin: String
    private let kind: EgressKind
    private let wrapped: any HTTPTransport
    private let log: EgressLog

    public init(
        origin: String,
        kind: EgressKind = .agentModel,
        wrapped: any HTTPTransport,
        log: EgressLog = .shared
    ) {
        self.origin = origin
        self.kind = kind
        self.wrapped = wrapped
        self.log = log
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let target = EgressTarget.sanitize(request.url?.absoluteString ?? "")

        // 先记「即将发出」：进程若在请求途中被杀（或超时挂住），记录也已经落盘 ——
        // 出网日志最该抓住的恰恰是这种时刻。
        await log.record(
            kind: kind,
            target: target,
            origin: origin,
            outcome: .allowed,
            detail: request.httpMethod
        )

        do {
            return try await wrapped.send(request)
        } catch {
            await log.record(
                kind: kind,
                target: target,
                origin: origin,
                outcome: .failed,
                detail: error.localizedDescription
            )
            throw error
        }
    }
}

/// 诊断出口。
///
/// **刻意不叫 `Logger`**：Core 里 `Logger` 是 swift-log 的类型（`PostgresService` 在用），
/// 同名会直接编译冲突。这里只需要"写一行到 stderr"，不值得为一个诊断引一层抽象。
enum EgressDiagnostics {
    static func warning(_ message: String) {
        FileHandle.standardError.write(Data("[egress] \(message)\n".utf8))
    }
}

/// 外发日志的筛选条件（纯值类型，便于单测）。
///
/// 为什么筛选要放在 Core：面板、导出、"只看被拦下的请求"这些入口将来会有多个，
/// 各写一份筛选就会出现"同一个条件在不同地方结果不同"。放这里只有一份实现。
public struct EgressFilter: Equatable, Sendable {
    /// `nil` = 不限类别。
    public var kind: EgressKind?
    /// `nil` = 不限结果。
    public var outcome: EgressOutcome?
    /// 关键词：匹配目标 / 触发来源 / 补充说明（不区分大小写）。
    public var keyword: String
    /// 只看某个浏览器页签的出网（`nil` = 不限页签）。
    public var tabID: UUID?

    public init(
        kind: EgressKind? = nil,
        outcome: EgressOutcome? = nil,
        keyword: String = "",
        tabID: UUID? = nil
    ) {
        self.kind = kind
        self.outcome = outcome
        self.keyword = keyword
        self.tabID = tabID
    }

    public var isActive: Bool {
        kind != nil || outcome != nil || tabID != nil || !keyword.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public func apply(to entries: [EgressEntry]) -> [EgressEntry] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return entries.filter { entry in
            if let kind, entry.kind != kind { return false }
            if let outcome, entry.outcome != outcome { return false }
            if let tabID, entry.tabID != tabID { return false }
            guard !trimmed.isEmpty else { return true }
            let haystack = [entry.target, entry.origin, entry.detail ?? ""]
                .joined(separator: " ")
                .lowercased()
            return haystack.contains(trimmed)
        }
    }
}
