import Foundation

/// 笔记（DOYAH-01 的最小 Core 模型）+ **AI 产物→笔记的桥**（DOYAH-10）。
///
/// 三条口径按 SRS §4.13 的安全边界写进类型里，而不是靠调用方自觉：
///   ① **默认不存结果集行数据**（NFR-SEC-05 的更严版本）：来源里带 `rowCount` 只是"当时查了多少行"的元信息，
///      正文要装行数据必须**显式**调 `NoteDraft.withRowData()`，且笔记上会永久留痕（`containsRowData`）；
///   ② **口令与连接串永不入库**：`NoteSource` 只允许连接**名字**；
///   ③ 来源可追溯：类型 + 连接名 + 指纹 + 时间 —— 半年后能回答"这条是怎么来的"。
public struct NoteSource: Codable, Equatable, Sendable {

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case manual
        /// 对话式诊断的结论（FR-AI-03）
        case diagnosis
        /// 维护任务计划（FR-AI-04）
        case maintenance
        /// 生成的 / 收藏的 SQL
        case sql
        /// AI 攒出来的 skill / 提示词（DOYAH-10 的核心场景）
        case skill

        public var displayName: String { rawValue }
    }

    public var kind: Kind
    /// **只记连接的名字**，绝不记连接串与口令。
    public var connectionName: String?
    /// 内容指纹（同一份产物重复保存时可去重）。
    public var fingerprint: String?
    public var capturedAt: Date

    public init(kind: Kind = .manual, connectionName: String? = nil, fingerprint: String? = nil, capturedAt: Date = Date()) {
        self.kind = kind
        self.connectionName = connectionName
        self.fingerprint = fingerprint
        self.capturedAt = capturedAt
    }
}

public struct Note: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var body: String
    public var tags: [String]
    public var source: NoteSource
    public var createdAt: Date
    public var updatedAt: Date
    /// **这条笔记里含结果集行数据**（默认 false）。存进去就永久留痕 —— 因为一旦同步到云端，
    /// "含不含数据"是用户必须能自己查出来的事实。
    public var containsRowData: Bool

    public init(
        id: UUID = UUID(),
        title: String,
        body: String = "",
        tags: [String] = [],
        source: NoteSource = NoteSource(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        containsRowData: Bool = false
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.tags = tags
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.containsRowData = containsRowData
    }
}

/// 保存前的草稿：唯一能造出 `Note` 的入口，于是"显式确认含数据"这件事无法绕过。
public struct NoteDraft: Sendable {
    public var title: String
    public var body: String
    public var tags: [String]
    public var source: NoteSource
    private var rowDataConfirmed = false

    public init(title: String, body: String = "", tags: [String] = [], source: NoteSource = NoteSource()) {
        self.title = title
        self.body = body
        self.tags = tags
        self.source = source
    }

    /// 显式确认"这条要带结果集行数据"——调用方必须是人点过勾选的地方。
    public func withRowData() -> NoteDraft {
        var copy = self
        copy.rowDataConfirmed = true
        return copy
    }

    public func makeNote(now: Date = Date()) -> Note {
        Note(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            body: body,
            tags: tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            source: source,
            createdAt: now,
            updatedAt: now,
            containsRowData: rowDataConfirmed
        )
    }
}

/// 本地笔记库（DOYAH-01 / 07：本地优先，离线照常写）。
///
/// **数据家与工程分开**（FR-PLUG-04）：笔记落在 `<Application Support>/DoyahNotes/notes.json`，
/// **不在** `<Application Support>/DoyahStudio/` 之下 —— 插件的数据不跟宿主的连接凭据 / 查询历史 /
/// 审计日志混放，备份与清理策略各自独立。整改前的位置由 `legacyFileURL()` 给出，
/// 一次性迁移见 `NoteStoreMigration`（原子写 + 坏文件回退报告）。
///
/// 与工程里其它存储同一条纪律：**原子写 + 坏文件回退并报告**（不静默丢整库）。
/// 报告走 `loadOutcome()`：`load()` 保持「读不出来就当空库」的既有行为（调用方不必改），
/// 想区分「还没有这份文件」与「文件坏了」的调用方读 `loadOutcome()`。
public actor NoteStore {

    /// 文件名（数据家换了，文件名不变 —— 迁移因此是一次**字节搬运**，可以逐字节核对）。
    public static let fileName = "notes.json"

    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    // MARK: - 位置

    /// Application Support 根；取不到就退回临时目录（与工程其它存储同一兜底）。
    static func applicationSupportBase() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    /// **笔记的数据家**（FR-PLUG-04）：与工程数据家**平级的独立目录**。
    ///
    /// 环境变量 `DOYAH_NOTES_DIR` 可整体改掉它（与 `MCPApprovalStore.defaultStore(environment:)`
    /// 同一路数）：探针与脚本用它把笔记库挪到临时目录，免得在真实数据目录里留下测试痕迹。
    public static func defaultDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["DOYAH_NOTES_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return applicationSupportBase()
            .appendingPathComponent(DoyahIdentity.notesDataDirectoryName, isDirectory: true)
    }

    public static func defaultFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        defaultDirectory(environment: environment)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    public static func defaultStore(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> NoteStore {
        NoteStore(fileURL: defaultFileURL(environment: environment))
    }

    /// **整改前的位置**（FR-PLUG-04 之前）：与工程数据家同目录。
    /// 只有一次性迁移会读它 —— 留着是为了「老用户的笔记还搬得动」。
    public static func legacyFileURL() -> URL {
        applicationSupportBase()
            .appendingPathComponent(DoyahIdentity.applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    // MARK: - 读

    /// 读盘结果 —— 把「还没有这份文件」与「文件读不出来」分开（前者不是错误，后者要如实报）。
    public enum LoadOutcome: Equatable, Sendable {
        /// 还没有这份文件（第一次用）。
        case absent
        case loaded([Note])
        /// 文件在、但读不出来（坏 JSON / 编码不对 / 没权限）：**回退空列表并如实报告，不删原文件**。
        case unreadable(failure: String)
    }

    public func loadOutcome() -> LoadOutcome {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .absent }
        guard let data = try? Data(contentsOf: fileURL) else {
            return .unreadable(failure: "the notes file exists but cannot be read")
        }
        // **编解码的日期策略必须成对**：`save` 用 `.iso8601`，这里若用默认策略就解不回来 ——
        // 症状是「刚存进去的笔记读出来是空的」（而且不报错，直接回退成空数组）。
        // 本轮实测踩到：更新路径因此走了新建分支、`createdAt` 被改写。
        // 所以解码失败**如实报出来**，不再静默回退。
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return .loaded(try decoder.decode([Note].self, from: data))
        } catch {
            return .unreadable(failure: String(describing: error))
        }
    }

    public func load() throws -> [Note] {
        switch loadOutcome() {
        case .loaded(let notes): return notes
        case .absent, .unreadable: return []
        }
    }

    public func save(_ notes: [Note]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try Self.write(try encoder.encode(notes), to: fileURL)
    }

    /// 原子写（临时文件 + rename，由 `Data.write(options: .atomic)` 保证）：写到一半崩了不会留下
    /// 半截文件 —— 那正是「整库消失」的经典成因。迁移也走这一条，于是「写入」只有一份实现。
    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    /// 保存草稿（新建或按 id 覆盖），返回落库后的笔记。
    @discardableResult
    public func upsert(_ draft: NoteDraft, id: UUID? = nil, now: Date = Date()) throws -> Note {
        var notes = try load()
        if let id, let index = notes.firstIndex(where: { $0.id == id }) {
            var note = draft.makeNote(now: notes[index].createdAt)
            note.id = id
            note.updatedAt = now
            notes[index] = note
            try save(notes)
            return note
        }
        let note = draft.makeNote(now: now)
        notes.append(note)
        try save(notes)
        return note
    }

    public func delete(id: UUID) throws {
        var notes = try load()
        notes.removeAll { $0.id == id }
        try save(notes)
    }
}

/// `FR-PLUG-04` 的**一次性数据边界迁移**：把笔记库从**工程数据家**搬进**笔记自己的数据家**。
///
/// 口径（与工程里其它迁移一致，都是「不猜、不留事故」）：
/// 1. **只搬一次、幂等**：目标已有文件时**一个字节都不动**（那是更新的那一份），如实报 `skippedTargetExists`；
/// 2. **原子写 + 读回核对**：先原子写完目标、再读回来逐字段核对，核对过了才动旧文件；
/// 3. **坏文件回退并报告**：旧文件读不出来时**原地保留**、目标不建、如实报 `legacyUnreadable`
///    —— 读不懂就别搬，绝不能把用户唯一的笔记库覆盖掉；
/// 4. **旧文件不删**：搬完把它移到新数据家里改名为 `notes.json.migrated`（留一份可回溯的备份）；
///    搬不动也只如实报告 —— 目标已经写好了，数据不丢；
/// 5. **有 `DOYAH_NOTES_DIR` 覆盖时不迁**：那是脚本把数据挪到临时目录用的，而「旧位置」仍是真实用户目录，
///    照迁就会把真实笔记搬进临时目录 —— 宁可不动。
public enum NoteStoreMigration {

    public enum Outcome: String, Equatable, Sendable {
        /// 旧文件不存在（或两边指到同一个文件）：没有要搬的东西。
        case nothingToMigrate
        /// 目标已有文件 —— 不动任何一个字节。
        case skippedTargetExists
        /// 生效的 `DOYAH_NOTES_DIR` 覆盖把数据指到了别处，迁移主动让路。
        case skippedOverridden
        case migrated
        /// 旧文件读不出来：原地保留、目标不建。
        case legacyUnreadable
        /// 写目标失败（或写后核对不一致）：旧文件仍在原处。
        case writeFailed
    }

    public struct Report: Equatable, Sendable {
        public var outcome: Outcome
        public var legacyURL: URL
        public var targetURL: URL
        /// 搬过去的条数（只有 `migrated` 非零）。
        public var noteCount: Int
        /// 旧文件搬完后的落点（没能搬走时为 nil）。
        public var backupURL: URL?
        /// 未能迁移的原因（机器可读的原文，**不翻译** —— 界面文案由调用方按 `outcome` 组织）。
        public var failure: String?

        public var didMigrate: Bool { outcome == .migrated }

        /// 需要如实告诉用户：旧文件读不出来 / 写不进去。
        public var needsAttention: Bool {
            outcome == .legacyUnreadable || outcome == .writeFailed
        }
    }

    /// 搬完后的旧文件在新数据家里的名字。
    public static let backupFileName = NoteStore.fileName + ".migrated"

    /// 按**默认位置**迁移（界面打开笔记时调一次）。
    ///
    /// 生效的 `DOYAH_NOTES_DIR` 覆盖会让本方法**主动让路**（见类型注释第 5 条）。
    public static func migrateIfNeeded(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Report {
        let targetURL = NoteStore.defaultFileURL(environment: environment)
        if let override = environment["DOYAH_NOTES_DIR"], !override.isEmpty {
            return Report(
                outcome: .skippedOverridden,
                legacyURL: NoteStore.legacyFileURL(),
                targetURL: targetURL,
                noteCount: 0
            )
        }
        return migrateIfNeeded(legacyURL: NoteStore.legacyFileURL(), targetURL: targetURL)
    }

    public static func migrateIfNeeded(
        legacyURL: URL,
        targetURL: URL,
        fileManager: FileManager = .default
    ) -> Report {
        var report = Report(
            outcome: .nothingToMigrate,
            legacyURL: legacyURL,
            targetURL: targetURL,
            noteCount: 0
        )

        // 两边指到同一个文件（环境变量拼出来的情形）：没有「搬」这回事。
        guard legacyURL.standardizedFileURL != targetURL.standardizedFileURL else { return report }
        guard fileManager.fileExists(atPath: legacyURL.path) else { return report }
        // 目标已有文件：那是更新的那一份，**一个字节都不动**（幂等的落点）。
        guard !fileManager.fileExists(atPath: targetURL.path) else {
            report.outcome = .skippedTargetExists
            return report
        }

        // 读旧文件：**直接搬字节**，不重新编码 —— 搬完能逐字节比对，也不会因为编码策略变化而改内容。
        guard let data = try? Data(contentsOf: legacyURL) else {
            report.outcome = .legacyUnreadable
            report.failure = "the legacy notes file exists but cannot be read"
            return report
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let expected: [Note]
        do {
            expected = try decoder.decode([Note].self, from: data)
        } catch {
            report.outcome = .legacyUnreadable
            report.failure = String(describing: error)
            return report
        }

        // 原子写 + 读回来核对：核对不过就当没搬（旧文件仍在原处，数据不丢）。
        do {
            try NoteStore.write(data, to: targetURL)
            let written = try decoder.decode([Note].self, from: Data(contentsOf: targetURL))
            guard written == expected else {
                report.outcome = .writeFailed
                report.failure = "the file written to the new location did not read back the same"
                return report
            }
        } catch {
            report.outcome = .writeFailed
            report.failure = String(describing: error)
            return report
        }

        report.outcome = .migrated
        report.noteCount = expected.count
        // 旧文件移到新数据家留一份备份（**不删**）：搬不动就如实说，目标已经好了，数据不丢。
        report.backupURL = try? moveAside(legacyURL, into: targetURL.deletingLastPathComponent(), fileManager: fileManager)
        return report
    }

    /// 把旧文件移进新数据家；同名时顺延 `notes.json.migrated-2` …（**绝不覆盖已有备份**）。
    static func moveAside(
        _ source: URL,
        into directory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        var candidate = directory.appendingPathComponent(backupFileName, isDirectory: false)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(backupFileName)-\(suffix)", isDirectory: false)
            suffix += 1
        }
        try fileManager.moveItem(at: source, to: candidate)
        return candidate
    }
}

/// 检索（DOYAH-06 的骨架）：标题 / 正文 / 标签，大小写与首尾空白不敏感，**结果稳定有序**。
public enum NoteSearch {
    public static func match(_ notes: [Note], query: String) -> [Note] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else {
            return notes.sorted { $0.updatedAt > $1.updatedAt }
        }
        return notes
            .filter { note in
                note.title.lowercased().contains(needle)
                    || note.body.lowercased().contains(needle)
                    || note.tags.contains { $0.lowercased().contains(needle) }
            }
            .sorted { left, right in
                if left.updatedAt != right.updatedAt { return left.updatedAt > right.updatedAt }
                return left.title < right.title
            }
    }

    /// 标签汇总（按出现次数降序、同次数字典序）。
    public static func tagCounts(_ notes: [Note]) -> [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for note in notes {
            for tag in Set(note.tags) { counts[tag, default: 0] += 1 }
        }
        return counts
            .sorted { left, right in
                if left.value != right.value { return left.value > right.value }
                return left.key < right.key
            }
            .map { (tag: $0.key, count: $0.value) }
    }
}
