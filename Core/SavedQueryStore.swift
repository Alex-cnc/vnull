import Foundation

/// 用户保存的查询（SQL 片段）。
public struct SavedQuery: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    /// 保存时所在的连接（仅作记录，载入时可选择是否切换）。
    public var connectionID: UUID?
    /// 保存时所在的数据库。
    public var database: String?
    public var sql: String
    public var savedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        connectionID: UUID? = nil,
        database: String? = nil,
        sql: String,
        savedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.connectionID = connectionID
        self.database = database
        self.sql = sql
        self.savedAt = savedAt
    }
}

/// 保存查询的持久化（与连接配置分开存文件；**不含密码**）。
public actor SavedQueryStore {
    public static let shared = SavedQueryStore()

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

        self.fileURL = baseURL.appendingPathComponent("saved-queries.json", isDirectory: false)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func load() throws -> [SavedQuery] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode([SavedQuery].self, from: data)
        } catch {
            throw AppError.persistence(error.localizedDescription)
        }
    }

    public func save(_ queries: [SavedQuery]) throws {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(queries)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            throw AppError.persistence(error.localizedDescription)
        }
    }

    public func fileLocation() -> URL {
        fileURL
    }
}
