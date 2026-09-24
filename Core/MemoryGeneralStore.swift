import Foundation

/// 通用层的**落盘存储**（FR-AI-15 的验收④：通用层与环境层分离）。
///
/// 背景：通用层提升（`MemoryPromotion` + 脱敏闸）早就实现并单测过了，但**只打印不落盘** ——
/// 于是"跨连接的写法经验"这句话在实现上不成立：经验提出来就没了，下次还得重新提。
/// 这里把它落成一份可检视、可删除、可重复提升（去重计数）的文件。
///
/// 与 `MemoryDecisionsStore` 同一套纪律：
/// - 放在调用方给的目录里（与归档同目录，**一个 `--dir` 指定全部**，不可能对不上）；
/// - 读**不抛异常**：坏文件回退成空层并**报告**（一个坏文件不该让记忆层不可用，但也不能静默吞）；
/// - 写**原子**（磁盘上不留半截文件）；
/// - 文件内容**确定**（键排序 + 数组排序），跑两次逐字节一致，可 diff、可进版本库。
public struct GeneralMemory: Codable, Equatable, Sendable, Identifiable {
    /// 稳定 id = 通用写法的粗指纹（同一骨架的不同取值归并成一条）。
    public var id: String
    /// 通用写法（`‹标识符›` 占位 + `?` 字面量占位）。
    public var template: String
    /// 方言（"postgresql" / "gbase8a"）：同一句 SQL 在不同方言下的写法经验不该混在一起。
    public var dialect: String
    /// 提升过这条的来源记忆指纹（可多条：不同环境里的同一写法）。
    public var sourceFingerprints: [String]
    /// 首次提升时间。
    public var promotedAt: Date
    /// 最近一次提升时间。
    public var lastSeenAt: Date
    /// 被提升过多少次（> 1 说明这个写法在不同环境里反复出现 —— 它才是真正"通用"的）。
    public var useCount: Int

    public init(
        id: String,
        template: String,
        dialect: String,
        sourceFingerprints: [String],
        promotedAt: Date,
        lastSeenAt: Date,
        useCount: Int
    ) {
        self.id = id
        self.template = template
        self.dialect = dialect
        self.sourceFingerprints = Array(Set(sourceFingerprints)).sorted()
        self.promotedAt = promotedAt
        self.lastSeenAt = lastSeenAt
        self.useCount = useCount
    }
}

/// 通用层（一份集合 = 一个文件）。
public struct GeneralMemoryLayer: Codable, Equatable, Sendable {

    public static let fileName = "general-memory.json"

    public private(set) var memories: [GeneralMemory]

    public init(memories: [GeneralMemory] = []) {
        self.memories = memories.sorted { $0.id < $1.id }
    }

    // MARK: - Codable（手写解码：文件可能是人手改的 / 旧版本写的）

    private enum CodingKeys: String, CodingKey {
        case memories
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try container.decodeIfPresent([GeneralMemory].self, forKey: .memories) ?? []
        self.init(memories: decoded)
    }

    // MARK: - 提升 / 删除

    /// 提升一条通用写法：同 id 视为同一条（去重、计数 +1、合并来源）。
    ///
    /// 返回**落盘后的那条**，让调用方能把"这是第几次提升"如实说出来。
    @discardableResult
    public mutating func promote(
        template: String,
        dialect: String,
        sourceFingerprint: String?,
        at date: Date = Date()
    ) -> GeneralMemory {
        let id = GeneralMemoryLayer.identifier(for: template, dialect: dialect)
        var sources = sourceFingerprint.map { [$0] } ?? []
        if let index = memories.firstIndex(where: { $0.id == id }) {
            var existing = memories[index]
            existing.lastSeenAt = date
            existing.useCount += 1
            sources.append(contentsOf: existing.sourceFingerprints)
            existing.sourceFingerprints = Array(Set(sources)).sorted()
            memories[index] = existing
            memories.sort { $0.id < $1.id }
            return existing
        }
        let created = GeneralMemory(
            id: id,
            template: template,
            dialect: dialect,
            sourceFingerprints: sources,
            promotedAt: date,
            lastSeenAt: date,
            useCount: 1
        )
        memories.append(created)
        memories.sort { $0.id < $1.id }
        return created
    }

    public func memory(id: String) -> GeneralMemory? {
        memories.first { $0.id == id }
    }

    /// 按 id 删除；返回是否真的删掉了（没这条时为 `false`，调用方据此如实汇报）。
    @discardableResult
    public mutating func remove(id: String) -> Bool {
        let before = memories.count
        memories.removeAll { $0.id == id }
        return memories.count != before
    }

    public var isEmpty: Bool { memories.isEmpty }

    /// 稳定 id：通用写法的粗指纹 + 方言。
    ///
    /// 用**粗指纹**（同一个聚类口径）而不是整串哈希：日期间隔、空白差异不该让同一条经验变成两条。
    public static func identifier(for template: String, dialect: String) -> String {
        "\(dialect):\(QueryMemory.coarseFingerprint(template))"
    }
}

/// 通用层的落盘 / 读取。
public enum GeneralMemoryStore {

    public struct LoadResult: Equatable, Sendable {
        public var layer: GeneralMemoryLayer
        /// 读取失败 / 被跳过时的说明（空 = 一切正常）。
        public var warnings: [String]

        public init(layer: GeneralMemoryLayer = GeneralMemoryLayer(), warnings: [String] = []) {
            self.layer = layer
            self.warnings = warnings
        }
    }

    public static func fileURL(in directory: URL) -> URL {
        directory.appendingPathComponent(GeneralMemoryLayer.fileName, isDirectory: false)
    }

    /// 读通用层。文件不存在 = 空层（不是错误：大多数目录从来没提升过）。
    public static func load(from directory: URL, fileManager: FileManager = .default) -> LoadResult {
        let url = fileURL(in: directory)
        guard fileManager.fileExists(atPath: url.path) else { return LoadResult() }
        do {
            let data = try Data(contentsOf: url)
            return LoadResult(layer: try JSONDecoder().decode(GeneralMemoryLayer.self, from: data))
        } catch {
            return LoadResult(warnings: [
                "\(GeneralMemoryLayer.fileName) 读不了（\(error.localizedDescription)），本次按「通用层为空」继续"
            ])
        }
    }

    /// 原子写。
    @discardableResult
    public static func save(
        _ layer: GeneralMemoryLayer,
        to directory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(layer)
        let url = fileURL(in: directory)
        try data.write(to: url, options: [.atomic])
        return url
    }
}
