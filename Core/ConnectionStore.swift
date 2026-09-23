import Foundation

public actor ConnectionStore {
    public static let shared = ConnectionStore()

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
            baseURL = applicationSupport.appendingPathComponent(DoyahIdentity.applicationSupportDirectoryName, isDirectory: true)
        }

        self.fileURL = baseURL.appendingPathComponent("connections.json", isDirectory: false)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func load() throws -> [ConnectionConfig] {
        try loadWithReport().configs
    }

    /// 读取并把老格式迁到当前版本（FR-CONN-10 / DR-03）。
    ///
    /// **落盘策略**：只发生迁移（且没有"更新版本"的配置）时立刻写回一次，把文件升级到位；
    /// 一旦发现来自更新版本的配置就**不写回** —— 本版本不认识那些新字段，
    /// 用旧代码重写会让它们消失（见需求书 R-40）。
    @discardableResult
    public func loadWithReport(persistMigrated: Bool = true) throws -> (
        configs: [ConnectionConfig],
        summary: ConnectionConfigMigrator.Summary
    ) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ([], ConnectionConfigMigrator.Summary())
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try decoder.decode([ConnectionConfig].self, from: data)
            let (configs, summary) = ConnectionConfigMigrator.migrate(decoded)

            if persistMigrated, summary.didMigrate, !summary.didSkipNewer {
                try? save(configs)
            }
            return (configs, summary)
        } catch {
            throw AppError.persistence(error.localizedDescription)
        }
    }

    public func save(_ configurations: [ConnectionConfig]) throws {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(configurations)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            throw AppError.persistence(error.localizedDescription)
        }
    }

    public func fileLocation() -> URL {
        fileURL
    }
}
