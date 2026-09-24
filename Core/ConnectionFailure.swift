import Foundation
import PostgresNIO

/// 连接失败的**可读化**（R-46 / FR-META-10）。
///
/// 解决的问题很具体：连不上库时，界面与命令行原本直接把驱动的 `PSQLError` 抛给用户 ——
/// 那是一句 `PSQLError(code: server, serverInfo: […])` 或 `The operation couldn't be completed…`，
/// 既看不出"是密码错了、库不存在、还是网络不通"，也不知道下一步该查什么。
///
/// 两条设计原则：
/// 1. **不丢原始信息**：人话在前，`code`（SQLSTATE 或驱动错误类别）与原始串仍然保留 ——
///    排查时"到底是哪个码"往往才是关键，把它换掉等于帮倒忙；
/// 2. **不抢别的错误**：只有识别得出是连接类失败时才给结论，其余返回 `nil` 让调用方走原路
///    （否则会把 SQL 语法错误也"翻译"成连接问题）。
public enum ConnectionFailure {

    /// 连接目标（只用于组织文案，不参与判断）。
    public struct Target: Equatable, Sendable {
        public var host: String
        public var port: Int
        public var database: String?
        public var username: String?

        public init(host: String, port: Int, database: String? = nil, username: String? = nil) {
            self.host = host
            self.port = port
            self.database = database
            self.username = username
        }

        /// 主展示名：`host:port/db`（**不带用户** —— 嵌在括号里会变成"（…（用户 x））"这种套娃）。
        public var displayName: String {
            var text = "\(host):\(port)"
            if let database, !database.isEmpty { text += "/\(database)" }
            return text
        }

        /// 用户单独一句，只在需要区分"用哪个账号连的"时拼上。
        public var userSuffix: String {
            guard let username, !username.isEmpty else { return "" }
            return "（用户 \(username)）"
        }
    }

    public struct Description: Equatable, Sendable {
        /// 一句话人话（界面/命令行的主文案）。
        public var summary: String
        /// 排查建议（可空）。
        public var suggestion: String?
        /// SQLSTATE（如 `28P01`）或驱动错误类别（如 `sslUnsupported`）。
        public var code: String?
        /// 原始错误串 —— **保留**，排查与上报都用得上。
        public var technicalDetail: String?

        public init(summary: String, suggestion: String? = nil, code: String? = nil, technicalDetail: String? = nil) {
            self.summary = summary
            self.suggestion = suggestion
            self.code = code
            self.technicalDetail = technicalDetail
        }

        /// 命令行/日志用的一整段。
        public var fullText: String {
            var lines = [summary]
            if let suggestion { lines.append("建议：\(suggestion)") }
            if let code { lines.append("错误码：\(code)") }
            return lines.joined(separator: "\n")
        }
    }

    /// 从任意错误提炼可读说明；**不是连接类失败时返回 `nil`**。
    public static func describe(_ error: any Error, target: Target? = nil) -> Description? {
        if let psql = error as? PSQLError {
            return describe(psqlError: psql, target: target)
        }
        // 网络层错误（NIO / POSIX）常常包在驱动错误里，也可能是裸的。
        let message = "\(error) \(error.localizedDescription)"
        if let network = describeNetworkMessage(message, target: target) { return network }
        return nil
    }

    static func describe(psqlError: PSQLError, target: Target?) -> Description {
        let sqlState = psqlError.serverInfo?[.sqlState]
        let serverMessage = psqlError.serverInfo?[.message]
        let detail = serverMessage.map { "\(psqlError)" + " · \($0)" } ?? "\(psqlError)"

        // 服务端给出 SQLSTATE：按码说话（这是最准的一档）。
        if let sqlState, let mapped = describe(sqlState: sqlState, message: serverMessage ?? "", target: target) {
            return Description(
                summary: mapped.summary,
                suggestion: mapped.suggestion,
                code: sqlState,
                technicalDetail: detail
            )
        }

        // 没有 SQLSTATE：按驱动错误类别说。
        switch psqlError.code {
        case .sslUnsupported, .failedToAddSSLHandler, .receivedUnencryptedDataAfterSSLRequest:
            return Description(
                summary: "SSL 协商失败：服务端不支持或拒绝了这个 SSL 模式",
                suggestion: "把连接的 SSL 模式改成「prefer」或「disable」再试；若服务端强制 SSL，请改用「require」并确认证书链",
                code: psqlError.code.description,
                technicalDetail: detail
            )
        case .authMechanismRequiresPassword, .unsupportedAuthMechanism, .saslError:
            return Description(
                summary: "认证没能通过：服务端要求的认证方式与本次提供的凭据对不上",
                suggestion: "确认用户名 / 口令是否正确且已保存；若服务端用 SCRAM，请清掉旧口令重新输入一次",
                code: psqlError.code.description,
                technicalDetail: detail
            )
        case .connectionError, .serverClosedConnection, .uncleanShutdown:
            let address = target.map { "（\($0.displayName)）" } ?? ""
            if let underlying = psqlError.underlying,
               let network = describeNetworkMessage("\(underlying) \(underlying.localizedDescription)", target: target) {
                return Description(
                    summary: network.summary,
                    suggestion: network.suggestion,
                    code: psqlError.code.description,
                    technicalDetail: detail
                )
            }
            return Description(
                summary: "与数据库的连接中断了\(address)",
                suggestion: "确认服务在运行、网络可达、没有被防火墙或中间件掐断（本机的保活心跳能缓解空闲断连）",
                code: psqlError.code.description,
                technicalDetail: detail
            )
        default:
            return Description(
                summary: "连接数据库失败",
                suggestion: "确认主机 / 端口 / 库名 / 用户名，以及服务端是否在运行",
                code: psqlError.code.description,
                technicalDetail: detail
            )
        }
    }

    /// 纯函数：SQLSTATE → 人话（单测入口；不依赖驱动类型）。
    public static func describe(sqlState rawState: String, message: String, target: Target? = nil) -> Description? {
        let state = rawState.uppercased()
        let address = target.map { $0.displayName }
        let where_ = address.map { "（\($0)）" } ?? ""

        switch state {
        case "28P01", "28000":
            return Description(
                summary: "认证失败：用户名或口令不对\(where_)\(target?.userSuffix ?? "")",
                suggestion: "确认用户名拼写与口令；口令若改过，请在连接里重新保存一次"
            )
        case "3D000":
            let name = target?.database.map { "「\($0)」" } ?? "目标库"
            return Description(
                summary: "数据库不存在或无权连接：\(name)\(where_)",
                suggestion: "确认库名拼写；也可能是当前用户看不到这个库（权限 / 连接限制）"
            )
        case "53300":
            return Description(
                summary: "服务端连接数已满\(where_)",
                suggestion: "稍后重试，或在服务端释放空闲连接 / 调大 max_connections"
            )
        case "57P03":
            return Description(
                summary: "数据库正在启动或暂不接受连接\(where_)",
                suggestion: "稍等几秒再试；若是刚重启的实例，这是正常现象"
            )
        case "42501":
            return Description(
                summary: "权限不足：当前用户不允许做这件事\(where_)",
                suggestion: "换有权限的账号，或让 DBA 授予所需权限"
            )
        case "08001", "08004", "08006", "08003":
            return Description(
                summary: "连不上数据库服务\(where_)",
                suggestion: "确认服务在运行、端口正确、网络与防火墙放行"
            )
        case "08P01":
            return Description(
                summary: "协议不匹配：服务端不接受这次会话的协议\(where_)",
                suggestion: "确认连的是 PostgreSQL 兼容服务且版本受支持"
            )
        case "42P01":
            // 表不存在属于**查询**错误，不是连接问题 —— 别把这类错误也说成连接失败。
            return nil
        default:
            if state.hasPrefix("08") {
                return Description(
                    summary: "连接被拒绝或中断（SQLSTATE \(state)）\(where_)",
                    suggestion: "确认服务在运行、网络可达；若偶发，检查中间件 / 防火墙的空闲超时"
                )
            }
            if state.hasPrefix("28") {
                return Description(
                    summary: "认证相关失败（SQLSTATE \(state)）\(where_)",
                    suggestion: "确认用户名与口令、以及服务端的 pg_hba.conf 是否允许这个来源"
                )
            }
            // 服务端给了别的码：交给调用方（可能是 SQL 错误，不该被翻译成连接问题）。
            _ = message
            return nil
        }
    }

    /// 纯函数：网络层错误串 → 人话（NIO / POSIX 的英文串在这里被翻译）。
    public static func describeNetworkMessage(_ raw: String, target: Target? = nil) -> Description? {
        let message = raw.lowercased()
        let where_ = target.map { "（\($0.displayName)）" } ?? ""

        func has(_ needles: [String]) -> Bool { needles.contains { message.contains($0) } }

        if has(["connection refused", "econnrefused"]) {
            return Description(
                summary: "目标主机拒绝了连接\(where_)",
                suggestion: "服务可能没在跑、端口不是这个，或只监听在本机（检查 listen_addresses 与防火墙）"
            )
        }
        if has(["nodename nor servname", "name or service not known", "host not found", "getaddrinfo"]) {
            return Description(
                summary: "主机名解析不了\(where_)",
                suggestion: "检查主机名拼写与 DNS；内网机器请确认 VPN / hosts"
            )
        }
        if has(["timed out", "timeout", "etimedout"]) {
            return Description(
                // 超时**不一定是网络不通**：主机名解析不了、走错网段、被防火墙丢包，
                // 在本机看来都可能是"连不上直到超时"。所以建议里两条都要提，
                // 否则用户会按"网络不通"查半天，而问题只是主机名打错。
                summary: "连接超时：\(target.map(\.displayName) ?? "目标主机")没有响应",
                suggestion: "先确认主机名能解析（拼写 / DNS / hosts），再确认端口放行（防火墙 / 安全组 / 服务是否在监听）"
            )
        }
        if has(["network is unreachable", "no route to host", "ehostunreach", "enetunreach"]) {
            return Description(
                summary: "网络不可达\(where_)",
                suggestion: "确认与本机在同一网络（VPN / 跳板机 / 网段）"
            )
        }
        if has(["connection reset", "broken pipe", "econnreset"]) {
            return Description(
                summary: "连接被对端重置\(where_)",
                suggestion: "常见于中间件超时或服务端重启；开启保活心跳可以减少空闲断连"
            )
        }
        if has(["ssl", "certificate", "tls"]) {
            return Description(
                summary: "SSL/TLS 协商失败\(where_)",
                suggestion: "换一个 SSL 模式试试（prefer / require / disable），并确认证书有效"
            )
        }
        return nil
    }
}
