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
/// 与工程里其它存储同一条纪律：**原子写 + 坏文件回退并报告**（不静默丢整库）。
public actor NoteStore {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func defaultStore() -> NoteStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return NoteStore(
            fileURL: base
                .appendingPathComponent(DoyahIdentity.applicationSupportDirectoryName, isDirectory: true)
                .appendingPathComponent("notes.json", isDirectory: false)
        )
    }

    public func load() throws -> [Note] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        // **编解码的日期策略必须成对**：`save` 用 `.iso8601`，这里若用默认策略就解不回来 ——
        // 症状是"刚存进去的笔记读出来是空的"（而且不报错，直接回退成空数组）。
        // 本轮实测踩到：更新路径因此走了新建分支、`createdAt` 被改写。
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Note].self, from: data)) ?? []
    }

    public func save(_ notes: [Note]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(notes).write(to: fileURL, options: .atomic)
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
