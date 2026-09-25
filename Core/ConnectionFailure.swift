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
        let detail = serverMessage.map {
            "\(psqlError)" + " · " + readableServerText($0)
        } ?? "\(psqlError)"

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
                summary: "SSL 协商失败：服务端没有启用 SSL（或拒绝了这个模式）",
                suggestion: "2026-09-25 实测到的典型情形：服务端 `postgresql.conf` 里 `ssl = off`，"
                    + "而连接选了「require / verify-ca / verify-full」—— 服务端会直接说不支持。"
                    + "把 SSL 模式改成「prefer」或「disable」即可；若必须加密，得先在服务端开 `ssl = on` 并配证书，"
                    + "再把 pg_hba.conf 的规则换成 `hostssl`",
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
            // 28000 有**两种完全不同的原因**，混在一起说会把用户引到错路上去：
            //   ① 口令 / 用户名不对；
            //   ② 服务端 `pg_hba.conf` **没有放行本机**（2026-09-25 需求提出者实测：这条以前被
            //      说成「用户名或口令不对」，而他的口令从来没变过 —— 真正的原因是服务端没有匹配
            //      `(客户端地址, 库, 用户)` 的记录）。
            // 判据只能用**服务端消息里的 ASCII 部分**：中文部分可能是 GBK 乱码
            // （见 `readableServerText`），但 `no pg_hba.conf entry` 这种关键字一定还在。
            if let rejection = describePGHBARejection(message: message, target: target) {
                return rejection
            }
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


    // MARK: - 服务端消息的可读化 / pg_hba 拒绝

    /// 服务端消息的**可读化**（2026-09-25 实测的一个真实坑）。
    ///
    /// 场景：中文 Windows 上的 PostgreSQL，`lc_messages` 是中文区域设置，消息按 **GBK 字节**发过来，
    /// 而驱动按 UTF-8 解 —— 中文变成 `û���������� "192.168.5.223" …`，用户看到的就是一串乱码。
    /// **原始字节拿不回来**（驱动已经做过一次有损解码，坏字节变成了替换字符 U+FFFD），
    /// 所以这里不假装能"修好"，只做两件诚实的事：
    ///   ① 把**能看懂的 ASCII 片段**抽出来 —— 诊断信息几乎都在那儿
    ///      （`no pg_hba.conf entry for host "192.168.5.223", user "zxvmax", database "zxvmax", no encryption`）；
    ///   ② 明说中文部分读不出来、以及为什么（服务端 `lc_messages` 不是 UTF-8）。
    public static func readableServerText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        // 干净就原样返回 —— 不许给正常消息套一层"乱码"的帽子。
        guard trimmed.unicodeScalars.contains(where: { $0.value == 0xFFFD }) else { return trimmed }

        // 抽出连续 ASCII 片段（≥3 个可见字符）：太短的（单个引号 / 逗号）只会变成噪音。
        var runs: [String] = []
        var current = ""
        for scalar in trimmed.unicodeScalars {
            let isPlainASCII = scalar.value >= 0x20 && scalar.value < 0x7F
            if isPlainASCII {
                current.unicodeScalars.append(scalar)
            } else {
                if current.trimmingCharacters(in: .whitespaces).count >= 3 { runs.append(current) }
                current = ""
            }
        }
        if current.trimmingCharacters(in: .whitespaces).count >= 3 { runs.append(current) }

        let skeleton = runs.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " … ")
        let note = "（服务端消息里含非 UTF-8 的中文，读不出来；上面是能看懂的原文片段 —— "
            + "服务端的 lc_messages 多半是中文区域设置，而客户端编码是 UTF-8）"
        return skeleton.isEmpty ? note : skeleton + " " + note
    }

    /// `pg_hba.conf` 拒绝（SQLSTATE 28000 的一个子类）。
    ///
    /// **必须与"口令不对"分开**：两者的用户动作完全不同 —— 一个是去核对口令，另一个是让 DBA
    /// 改服务端配置。判据取自服务端消息的 ASCII 部分（见 `readableServerText`）。
    static func describePGHBARejection(message: String, target: Target?) -> Description? {
        guard message.contains("pg_hba.conf") || message.contains("no pg_hba") else { return nil }
        let address = target.map { $0.displayName } ?? ""
        // 服务端消息里有它视角看到的客户端地址，抽出来，建议才好照抄。
        let clientHost = firstQuotedASCIIValue(in: message)

        var suggestion = "这**不是口令问题**，是服务端的连接规则没放行本机。让 DBA 在 pg_hba.conf 里加一条"
        if let clientHost {
            let db = target?.database.flatMap { $0.isEmpty ? nil : $0 } ?? "你的库"
            let user = target?.username.flatMap { $0.isEmpty ? nil : $0 } ?? "你的用户"
            suggestion += "：`host \(db) \(user) \(clientHost)/32 scram-sha-256`"
        } else {
            suggestion += "：`host 你的库 你的用户 <本机地址>/32 scram-sha-256`"
        }

        // 服务端消息会点明这次是加密还是明文 —— 那决定"该改客户端还是该改服务端"。
        if message.contains("no encryption") {
            suggestion += "，然后 `SELECT pg_reload_conf();`。本次连接是**不加密**的："
                + "也可以先把 SSL 模式改成 `prefer` / `require` 再试 —— 但服务端得先开了 `ssl`"
                + "（若服务端 ssl 关着，`require` 会直接报「SSL 协商失败」）。"
        } else if message.contains("SSL encryption") {
            suggestion += "（要用 `hostssl` 这一种），然后 `SELECT pg_reload_conf();`。"
                + "本次连接是**加密**的，所以规则得写 `hostssl`；若服务端不打算开 SSL，那就改用不加密连接。"
        } else {
            suggestion += "，然后 `SELECT pg_reload_conf();`。"
        }

        return Description(
            summary: "服务端的 pg_hba.conf 没有放行本次连接"
                + (address.isEmpty ? "" : "（\(address)）")
                + (target?.userSuffix ?? ""),
            suggestion: suggestion,
            code: "28000"
        )
    }

    /// 取消息里**第一个带引号的纯 ASCII 值**。
    ///
    /// 为什么不按关键字（`host "…"`）取：服务端消息会被本地化成中文，
    /// "host" 那个词在乱码里根本不存在 —— 但**引号与地址是 ASCII，一定还在**。
    /// PostgreSQL 这条消息的格式固定是 `… "主机", 用户 "…", 数据库 "…" …`，所以第一个引号串就是客户端地址。
    static func firstQuotedASCIIValue(in message: String) -> String? {
        var values: [String] = []
        var current: String?
        for character in message {
            if character == "\"" {
                if let open = current {
                    values.append(open)
                    current = nil
                } else {
                    current = ""
                }
                continue
            }
            current?.append(character)
        }
        return values.first { value in
            !value.isEmpty && value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F }
        }
    }

    // MARK: - 「服务端在要口令吗」

    /// 服务端是不是因为**要口令**而拒绝。
    ///
    /// 为什么要单独一个判据：客户端在连接前**无法知道**服务端需不需要口令 ——
    /// `trust` / `peer` / 证书 / IAM 这些认证方式本来就不需要，替服务端先拒绝，
    /// 代价是这类库**永远连不上**（实测：本机 `trust` 集群报「缺少口令」，而 psql 直接连得上）。
    /// 所以策略改成「没存口令也照连」，只有服务端真的开口要、而本地又确实没有时，
    /// 才把「口令读不到 + 找过哪些位置」这条更具体的诊断推给用户 —— 这条判据就是那个开关。
    public static func requiresPassword(sqlState: String?) -> Bool {
        // 28P01 invalid_password / 28000 invalid_authorization_specification。
        guard let sqlState else { return false }
        return sqlState == "28P01" || sqlState == "28000"
    }

    /// 从驱动错误里判断「服务端在要口令而本地没有」。
    public static func requiresPassword(_ error: any Error) -> Bool {
        guard let psql = error as? PSQLError else { return false }
        // 驱动自己就知道"服务端要求口令、但本次没提供"——这是最准的一档。
        switch psql.code {
        case .authMechanismRequiresPassword:
            return true
        default:
            break
        }
        return requiresPassword(sqlState: psql.serverInfo?[.sqlState])
    }
}
