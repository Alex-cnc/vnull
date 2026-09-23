import Foundation

/// 连接配置的**格式迁移**（FR-CONN-10 / DR-03）。
///
/// 目的只有一个：**格式升级时有路可走**。今天只有 v1，但"以后加字段怎么办"必须在
/// 加字段之前就定下来 —— 否则第一次升级就是一次数据事故。
///
/// 三条口径：
/// 1. **幂等**：已是当前版本的配置原样返回，反复加载不会来回改；
/// 2. **正常化而非猜测**：迁移只做能确定的事（字段缺失 / 零值补默认），不臆造用户意图；
/// 3. **不碰更高版本**：文件来自更新版本时**原样保留并如实报告** —— 用旧代码重写
///    会让新字段在下次保存时消失（见需求书 R-40）。
public enum ConnectionConfigMigrator {

    /// 当前版本（与 `ConnectionConfig.currentSchemaVersion` 同一处定义，避免两处漂移）。
    public static var currentVersion: Int { ConnectionConfig.currentSchemaVersion }

    /// 单条迁移结果。
    public enum Outcome: Equatable, Sendable {
        /// 已是当前版本。
        case unchanged
        /// 从旧版本迁上来。
        case migrated(from: Int)
        /// 比当前版本新：原样保留（不迁移、不降级）。
        case skippedNewerVersion(found: Int)
    }

    /// 迁移一批配置，并给出可汇报的摘要。
    public struct Summary: Equatable, Sendable {
        /// 发生迁移的连接 id。
        public var migrated: [UUID] = []
        /// 迁移前的版本号 → 条数（只统计发生迁移的）。
        public var migratedFromVersions: [Int: Int] = [:]
        /// 来自更新版本的版本号 → 条数（原样保留）。
        public var skippedNewerVersions: [Int: Int] = [:]

        public var didMigrate: Bool { !migrated.isEmpty }
        public var didSkipNewer: Bool { !skippedNewerVersions.isEmpty }

        /// 无需打扰用户（没迁移也没跳过更新版本）。
        public var isNoop: Bool { !didMigrate && !didSkipNewer }
    }

    public static func migrate(_ config: ConnectionConfig) -> (config: ConnectionConfig, outcome: Outcome) {
        // 更高版本：不迁移、不降级 —— 原样交回。
        guard config.schemaVersion <= currentVersion else {
            return (config, .skippedNewerVersion(found: config.schemaVersion))
        }
        guard config.schemaVersion < currentVersion else {
            return (config, .unchanged)
        }

        let from = config.schemaVersion
        var migrated = config

        // v0 / 缺字段时代 → v1：补齐当时没有或为零的字段。
        // 只做**能确定**的正常化：端口落回该类型的默认端口、超时零值落回默认。
        // 不动主机名、用户名、库名 —— 猜这些没有依据，只会把错误藏起来。
        if migrated.port <= 0 || migrated.port > 65535 {
            migrated.port = migrated.dbType.defaultPort
        }
        if migrated.timeout <= 0 {
            migrated.timeout = 5
        }
        migrated.schemaVersion = currentVersion

        return (migrated, .migrated(from: from))
    }

    public static func migrate(_ configs: [ConnectionConfig]) -> (configs: [ConnectionConfig], summary: Summary) {
        var summary = Summary()
        let migrated = configs.map { config -> ConnectionConfig in
            let (updated, outcome) = migrate(config)
            switch outcome {
            case .unchanged:
                break
            case .migrated(let from):
                summary.migrated.append(config.id)
                summary.migratedFromVersions[from, default: 0] += 1
            case .skippedNewerVersion(let found):
                summary.skippedNewerVersions[found, default: 0] += 1
            }
            return updated
        }
        return (migrated, summary)
    }
}

/// 解码容忍度：缺少 `schemaVersion` 的老文件按 **v0** 处理，而不是整个文件读不出来。
///
/// 这一点很关键：老文件里没有这个字段，如果按"必须有"解码，用户升级应用后
/// 连接列表会直接变成打不开 —— 而这正是"预留迁移能力"要避免的事。
extension ConnectionConfig {
    enum CodingKeys: String, CodingKey {
        case id, name, dbType, host, port, database, username, sslMode, timeout, schemaVersion
        case environment, colorTag
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        dbType = try container.decodeIfPresent(DatabaseType.self, forKey: .dbType) ?? .postgresql
        host = try container.decode(String.self, forKey: .host)
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? dbType.defaultPort
        database = try container.decode(String.self, forKey: .database)
        username = try container.decode(String.self, forKey: .username)
        sslMode = try container.decodeIfPresent(SSLMode.self, forKey: .sslMode) ?? dbType.defaultSSLMode
        timeout = try container.decodeIfPresent(Int.self, forKey: .timeout) ?? 5
        // 缺失 = v0：交给迁移器走 0 → 1 的路径，而不是这里假装已经是当前版本。
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        // FR-CONN-16 的两个字段是**纯新增且可选**，老文件读出来自然是 nil。
        // 因此**不提升 schemaVersion** —— 版本号留给"读不懂的破坏性变更"用；
        // 给可选字段升版本只会让老版本应用把文件误判成"来自更新版本"而拒绝改写。
        environment = try container.decodeIfPresent(ConnectionEnvironment.self, forKey: .environment)
        colorTag = try container.decodeIfPresent(CategoricalTone.self, forKey: .colorTag)
    }
}
