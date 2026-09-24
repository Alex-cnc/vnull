import Foundation

/// 连接 URL 的导入 / 导出（FR-CONN-19）：`postgres://user@host:port/db?sslmode=…` 一行建连。
///
/// 两条纪律：
/// 1. **密码不进配置包**（需求原文点名：密码只进本项目自己的密钥文件，DR-02）。
///    导出的 URL 里**不含密码**；导入时 URL 里若带了密码，只用于**本次**连接、不写进配置 ——
///    但会把"这里有一个密码"如实告诉调用方，由它决定放到哪里（本项目走 `FileSecretStore`）。
/// 2. **解析失败说清哪里不对**，不返回一个字段半空的配置：半个配置比没有配置更难查。
public enum ConnectionURL {

    public enum ParseError: Error, Equatable, LocalizedError {
        case empty
        case unsupportedScheme(String)
        case missingHost
        case missingDatabase
        case invalidPort(String)
        case invalidPercentEncoding(String)
        case invalidIPv6Host(String)

        public var errorDescription: String? {
            switch self {
            case .empty: return "URL 是空的"
            case .unsupportedScheme(let scheme): return "不支持的协议：\(scheme)（支持 postgres / postgresql，以及 gbase）"
            case .missingHost: return "缺少主机名"
            case .missingDatabase: return "缺少数据库名（URL 里的路径部分）"
            case .invalidPort(let text): return "端口不是数字：\(text)"
            case .invalidPercentEncoding(let text): return "百分号编码不合法：\(text)"
            case .invalidIPv6Host(let text): return "IPv6 主机要加方括号：[\(text)]"
            }
        }
    }

    /// 解析结果：一份配置 + **可选的**密码（密码不进配置）。
    public struct Imported: Equatable, Sendable {
        public var configuration: ConnectionConfig
        /// URL 里带的密码（若有）。调用方负责把它放进密钥存储；**不写进配置文件**。
        public var password: String?
        /// 原始 URL 里出现过但不认识的查询参数（如实列出，别静默丢）。
        public var ignoredParameters: [String]

        public init(configuration: ConnectionConfig, password: String?, ignoredParameters: [String]) {
            self.configuration = configuration
            self.password = password
            self.ignoredParameters = ignoredParameters
        }
    }

    /// 「从 URL 导入」并进**用户已经填了一半的表单**时的两条合并规则（FR-CONN-19）。
    ///
    /// 为什么抽成纯函数：这两条恰恰是"做错了也没人立刻发现"的地方 ——
    /// 覆盖掉用户手写的连接名、把"URL 里没写密码"当成"把密码清空"，
    /// 都属于"导入一下，我填的东西没了"。放进 Core 才能用单测钉住。
    public enum FormMerge {

        /// 连接名：用户写了就**保留用户写的**；空着才采用 URL 推断出的名字。
        public static func resolvedName(current: String, imported: String) -> String {
            current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? imported : current
        }

        /// 密码：URL 里带了才覆盖；没带就保持用户已输入的（**不静默清空**）。
        public static func resolvedPassword(current: String, imported: String?) -> String {
            guard let imported else { return current }
            return imported
        }
    }

    /// 解析连接 URL。
    ///
    /// - Parameter name: 连接名；不给就用"主机/库"拼一个可读的默认名。
    public static func parse(
        _ raw: String,
        name: String? = nil,
        id: UUID = UUID()
    ) -> Result<Imported, ParseError> {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        guard let schemeEnd = text.range(of: "://") else { return .failure(.unsupportedScheme(text)) }
        let scheme = String(text[text.startIndex..<schemeEnd.lowerBound]).lowercased()
        let databaseType: DatabaseType
        switch scheme {
        case "postgres", "postgresql": databaseType = .postgresql
        case "gbase", "gbase8a": databaseType = .gbase8a
        default: return .failure(.unsupportedScheme(scheme))
        }

        var remainder = String(text[schemeEnd.upperBound...])
        // 查询参数与 fragment 先摘掉（它们不影响主机/库的解析）
        var queryItems: [String: String] = [:]
        var ignored: [String] = []
        if let questionMark = remainder.firstIndex(of: "?") {
            let query = String(remainder[remainder.index(after: questionMark)...])
            remainder = String(remainder[remainder.startIndex..<questionMark])
            for pair in query.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { ignored.append(String(pair)); continue }
                let key = parts[0].lowercased()
                let value = String(parts[1])
                if key == "sslmode" { queryItems["sslmode"] = value } else { ignored.append(String(pair)) }
            }
        }
        if let hash = remainder.firstIndex(of: "#") {
            remainder = String(remainder[remainder.startIndex..<hash])
        }

        // 凭据部分
        var user: String?
        var password: String?
        if let at = remainder.lastIndex(of: "@") {
            let credentials = String(remainder[remainder.startIndex..<at])
            remainder = String(remainder[remainder.index(after: at)...])
            let parts = credentials.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            if let first = parts.first, !first.isEmpty {
                guard let decoded = first.removingPercentEncoding else {
                    return .failure(.invalidPercentEncoding(String(first)))
                }
                user = decoded
            }
            if parts.count == 2 {
                guard let decoded = String(parts[1]).removingPercentEncoding else {
                    return .failure(.invalidPercentEncoding(String(parts[1])))
                }
                password = decoded
            }
        }

        // 主机 / 端口 / 库
        var hostPart = remainder
        var database = ""
        if let slash = remainder.firstIndex(of: "/") {
            hostPart = String(remainder[remainder.startIndex..<slash])
            database = String(remainder[remainder.index(after: slash)...])
        }
        guard !hostPart.isEmpty else { return .failure(.missingHost) }
        guard !database.isEmpty else { return .failure(.missingDatabase) }
        guard let decodedDatabase = database.removingPercentEncoding else {
            return .failure(.invalidPercentEncoding(database))
        }

        var host = hostPart
        var port = databaseType.defaultPort
        if hostPart.hasPrefix("[") {
            // IPv6：`[::1]:5432`
            guard let close = hostPart.firstIndex(of: "]") else { return .failure(.missingHost) }
            host = String(hostPart[hostPart.index(after: hostPart.startIndex)..<close])
            let tail = String(hostPart[hostPart.index(after: close)...])
            if tail.hasPrefix(":") {
                let portText = String(tail.dropFirst())
                guard let value = Int(portText) else { return .failure(.invalidPort(portText)) }
                port = value
            }
        } else if hostPart.filter({ $0 == ":" }).count > 1 {
            // 裸 IPv6（`::1`）在 URL 里**必须加方括号**才不歧义。这里明确拒绝，
            // 而不是按"最后一个冒号是端口"去切 —— 那会把 `::1` 切成 host `:`（实测如此）。
            return .failure(.invalidIPv6Host(hostPart))
        } else if let colon = hostPart.lastIndex(of: ":") {
            host = String(hostPart[hostPart.startIndex..<colon])
            let portText = String(hostPart[hostPart.index(after: colon)...])
            guard let value = Int(portText) else { return .failure(.invalidPort(portText)) }
            port = value
        }
        guard !host.isEmpty else { return .failure(.missingHost) }

        let sslMode = queryItems["sslmode"].flatMap { SSLMode(rawValue: $0.lowercased()) }

        let configuration = ConnectionConfig(
            id: id,
            name: name ?? "\(host)/\(decodedDatabase)",
            dbType: databaseType,
            host: host,
            port: port,
            database: decodedDatabase,
            username: user ?? "",
            sslMode: sslMode ?? databaseType.defaultSSLMode,
            timeout: 5
        )
        return .success(Imported(configuration: configuration, password: password, ignoredParameters: ignored.sorted()))
    }

    /// 导出成 URL。**不含密码**（需求原文 + DR-02）。
    public static func url(for configuration: ConnectionConfig) -> String {
        var text = configuration.dbType == .gbase8a ? "gbase://" : "postgres://"
        if !configuration.username.isEmpty {
            text += encode(configuration.username)
            text += "@"
        }
        let host = configuration.host.contains(":") ? "[\(configuration.host)]" : configuration.host
        text += host
        text += ":\(configuration.port)"
        text += "/" + encode(configuration.database)
        text += "?sslmode=\(configuration.sslMode.rawValue)"
        return text
    }

    private static func encode(_ text: String) -> String {
        // 只对会破坏 URL 结构的字符编码（`@` `:` `/` `?` `#` `%` 与空白）
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "@:/?#%")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}

/// 连接配置包（换机迁移用）：**只有配置，没有密码**。
public struct ConnectionBundle: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var exportedAt: Date
    public var connections: [ConnectionConfig]
    /// 包里**故意不含**密码的说明（写给打开文件的人看）。
    public var note: String

    public init(
        formatVersion: Int = ConnectionBundle.currentFormatVersion,
        exportedAt: Date = Date(),
        connections: [ConnectionConfig],
        note: String = "本文件只含连接配置，不含任何密码；密码请在新机器上重新输入。"
    ) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.connections = connections
        self.note = note
    }

    /// 编码成 JSON（供写文件）。
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// 解析配置包。**版本比当前新时拒绝**（避免把读不懂的字段悄悄丢掉）。
    public static func decode(from data: Data) throws -> ConnectionBundle {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundle = try decoder.decode(ConnectionBundle.self, from: data)
        guard bundle.formatVersion <= currentFormatVersion else {
            throw BundleError.tooNew(bundle.formatVersion)
        }
        return bundle
    }

    public enum BundleError: Error, Equatable, LocalizedError {
        case tooNew(Int)

        public var errorDescription: String? {
            switch self {
            case .tooNew(let version):
                return "配置包版本 \(version) 比本客户端支持的 \(ConnectionBundle.currentFormatVersion) 更新，请升级客户端"
            }
        }
    }
}
