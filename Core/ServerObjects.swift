import Foundation

// MARK: - 对象模型

/// 服务器级对象的三类（FR-SESS-03）：角色 / 表空间 / 扩展。
///
/// 为什么三类放进**同一个**枚举：需求要的是一个「服务器级对象」视图，三类的浏览 / 增删改 /
/// 风险分级走的是同一套流程（预览 → 确认 → 执行），分成三套类型只会让上层把同一段确认逻辑写三遍。
public enum ServerObjectKind: String, CaseIterable, Codable, Sendable {
    case role
    case tablespace
    /// 扩展（`extension` 是 Swift 关键字，故加反引号；`rawValue` 仍是 `"extension"`）。
    case `extension` = "extension"

    public var displayName: String {
        switch self {
        case .role: return "角色"
        case .tablespace: return "表空间"
        case .extension: return "扩展"
        }
    }
}

/// 一个服务器级对象的统一模型。
///
/// 字段除名称外**全部可选**：三类对象的属性互不相同（角色没有大小、表空间没有版本），
/// 缺失即「该类对象没有这个属性」，不是「没查到」—— 界面按「有就显示」处理。
/// 这也是解析函数能容忍 NULL / 缺列的前提：没有哪一列是必需的。
public struct ServerObject: Identifiable, Equatable, Hashable, Sendable {
    public var kind: ServerObjectKind
    public var name: String
    /// 属主（PG 的 `pg_get_userbyid`）；MySQL 协议族的账号则放**来源主机**（`User@Host` 的 Host）。
    public var owner: String?
    /// 对象注释（PG 的 `COMMENT ON`）。
    public var comment: String?
    /// 表空间的磁盘路径。
    public var location: String?
    /// 表空间占用字节数。
    public var sizeBytes: Int64?
    /// 扩展版本。
    public var version: String?
    /// 扩展所在的 schema。
    public var schema: String?
    /// 角色能否登录。
    public var canLogin: Bool?
    /// 角色是否超级用户。
    public var isSuperuser: Bool?
    /// 附加状态文本（GBase 的 `PLUGIN_STATUS` 等）。
    public var status: String?

    public init(
        kind: ServerObjectKind,
        name: String,
        owner: String? = nil,
        comment: String? = nil,
        location: String? = nil,
        sizeBytes: Int64? = nil,
        version: String? = nil,
        schema: String? = nil,
        canLogin: Bool? = nil,
        isSuperuser: Bool? = nil,
        status: String? = nil
    ) {
        self.kind = kind
        self.name = name
        self.owner = owner
        self.comment = comment
        self.location = location
        self.sizeBytes = sizeBytes
        self.version = version
        self.schema = schema
        self.canLogin = canLogin
        self.isSuperuser = isSuperuser
        self.status = status
    }

    /// 同类对象内唯一（名字 + 类型）—— 列表刷新时用它保持选中行。
    public var id: String { "\(kind.rawValue):\(name)" }

    /// 人话摘要（列表第二列 / 确认弹窗用）。
    public var displaySummary: String {
        var parts: [String] = []
        if let owner, !owner.isEmpty { parts.append("属主 \(owner)") }
        if let canLogin { parts.append(canLogin ? "可登录" : "不可登录") }
        if isSuperuser == true { parts.append("超级用户") }
        if let version, !version.isEmpty { parts.append("版本 \(version)") }
        if let schema, !schema.isEmpty { parts.append("schema \(schema)") }
        if let location, !location.isEmpty { parts.append("目录 \(location)") }
        if let sizeBytes { parts.append("大小 \(ServerObjects.formatBytes(sizeBytes))") }
        if let status, !status.isEmpty { parts.append(status) }
        if let comment, !comment.isEmpty { parts.append(comment) }
        return parts.isEmpty ? kind.displayName : parts.joined(separator: " · ")
    }
}

/// 三类对象的**分组容器**：一次浏览的结果，外加「哪类在这个连接上不可用、为什么」。
///
/// `unsupportedReasons` 是一等字段而不是靠空数组暗示：需求点名「GBase 没有表空间概念，
/// 必须显式返回『该方言不支持』」——空数组会被界面显示成「一个表空间都没有」，
/// 那是把「没有这个概念」说成了「恰好为空」。
public struct ServerObjectInventory: Equatable, Sendable {
    public var roles: [ServerObject]
    public var tablespaces: [ServerObject]
    public var extensions: [ServerObject]
    /// 不可用的类别 → 可读中文说明。
    public var unsupportedReasons: [ServerObjectKind: String]

    public init(
        roles: [ServerObject] = [],
        tablespaces: [ServerObject] = [],
        extensions: [ServerObject] = [],
        unsupportedReasons: [ServerObjectKind: String] = [:]
    ) {
        self.roles = roles
        self.tablespaces = tablespaces
        self.extensions = extensions
        self.unsupportedReasons = unsupportedReasons
    }

    public func objects(for kind: ServerObjectKind) -> [ServerObject] {
        switch kind {
        case .role: return roles
        case .tablespace: return tablespaces
        case .extension: return extensions
        }
    }

    public func count(for kind: ServerObjectKind) -> Int { objects(for: kind).count }

    /// 该类为什么不显示；支持时为 nil。
    public func unsupportedReason(for kind: ServerObjectKind) -> String? {
        unsupportedReasons[kind]
    }

    public func isUnsupported(_ kind: ServerObjectKind) -> Bool {
        unsupportedReasons[kind] != nil
    }

    public var totalCount: Int { roles.count + tablespaces.count + extensions.count }

    /// 三类都空**且**都没有「不支持」说明时才算真的空。
    public var isEmpty: Bool { totalCount == 0 && unsupportedReasons.isEmpty }
}

// MARK: - 写操作

/// 服务器级对象的写操作种类。分级的依据照 `ExecutionSafety` / `AgentRiskLevel` 的既有口径：
/// DROP 不可逆 → `destructive`；CREATE / ALTER / RENAME 改变服务器状态 → `elevated`。
public enum ServerObjectAction: String, CaseIterable, Codable, Sendable {
    case createRole
    case alterRole
    case renameRole
    case dropRole
    case createTablespace
    case dropTablespace
    case createExtension
    case dropExtension

    public var kind: ServerObjectKind {
        switch self {
        case .createRole, .alterRole, .renameRole, .dropRole: return .role
        case .createTablespace, .dropTablespace: return .tablespace
        case .createExtension, .dropExtension: return .extension
        }
    }

    public var displayName: String {
        switch self {
        case .createRole: return "新建角色"
        case .alterRole: return "修改角色"
        case .renameRole: return "重命名角色"
        case .dropRole: return "删除角色"
        case .createTablespace: return "新建表空间"
        case .dropTablespace: return "删除表空间"
        case .createExtension: return "安装扩展"
        case .dropExtension: return "卸载扩展"
        }
    }

    /// 破坏性等级（供上层审批 / 二次确认用）。
    public var risk: AgentRiskLevel {
        switch self {
        case .dropRole, .dropTablespace, .dropExtension:
            return .destructive
        case .createRole, .alterRole, .renameRole, .createTablespace, .createExtension:
            return .elevated
        }
    }

    public var isDestructive: Bool { risk == .destructive }

    /// 是否一律要确认：本轮所有写操作都不是 `low`，所以全部要（浏览类操作不生成语句，不在此列）。
    public var requiresConfirmation: Bool { risk >= .elevated }
}

/// 一条**待确认**的写操作：预览文本就是将要执行的那一句 SQL。
///
/// 「预览与拒绝」是需求原话：所以这里既给 `statement`（做什么），
/// 也给 `risk` 与 `warnings`（代价是什么），两者一起交给上层弹窗。
public struct ServerObjectCommand: Equatable, Sendable {
    public var kind: ServerObjectKind
    public var action: ServerObjectAction
    /// 操作目标名（角色名 / 表空间名 / 扩展名）。
    public var targetName: String
    public var statement: String
    public var risk: AgentRiskLevel
    /// 人话提醒（权限、级联、不可逆等）。
    public var warnings: [String]

    public init(
        kind: ServerObjectKind,
        action: ServerObjectAction,
        targetName: String,
        statement: String,
        risk: AgentRiskLevel,
        warnings: [String] = []
    ) {
        self.kind = kind
        self.action = action
        self.targetName = targetName
        self.statement = statement
        self.risk = risk
        self.warnings = warnings
    }

    public var requiresConfirmation: Bool { risk >= .elevated }

    /// 是否不可逆（DROP 类）—— 上层审批文案要按它分档。
    public var isDestructive: Bool { risk == .destructive }

    /// 预览文本（与要执行的语句逐字一致 —— 预览里"美化"过的 SQL 不是将要执行的那句）。
    public var preview: String { statement }

    /// 一行中文摘要，例如「删除角色「probe」· 不可逆」。
    public var summary: String {
        "\(action.displayName)「\(targetName)」· \(ServerObjects.riskText(risk))"
    }
}

/// 写操作的规划结果：可直接执行 / 方言不支持 / 输入非法被拒。
///
/// 拒绝与不支持**分开**：前者是用户能改的（改个名字重来），后者是环境决定的
/// （GBase 没有表空间，改多少次名字都一样）。混成一个"失败"会让界面给错建议。
public enum ServerObjectWritePlan: Equatable, Sendable {
    case ready(ServerObjectCommand)
    /// 该方言没有这个概念 / 这个操作：`reason` 是可读中文说明，**不生成任何 SQL**。
    case unsupported(reason: String)
    /// 输入校验没过：`reason` 是可读理由。
    case rejected(reason: String)

    public var command: ServerObjectCommand? {
        if case .ready(let command) = self { return command }
        return nil
    }

    /// 将要执行的 SQL；不支持或被拒时为 nil。
    public var sql: String? { command?.statement }

    public var isReady: Bool { command != nil }

    public var risk: AgentRiskLevel? { command?.risk }

    /// 预览 / 报错文案（拒绝与不支持时就是那条中文理由）。
    public var preview: String {
        switch self {
        case .ready(let command): return command.preview
        case .unsupported(let reason), .rejected(let reason): return reason
        }
    }

    public var rejectionReason: String? {
        if case .rejected(let reason) = self { return reason }
        return nil
    }

    public var unsupportedReason: String? {
        if case .unsupported(let reason) = self { return reason }
        return nil
    }
}

// MARK: - 浏览结果

/// 浏览（只读）的计划：查询 / 近似查询 / 不支持。
///
/// 为什么要有 `approximation` 这一档：GBase 8a 没有 PostgreSQL 意义上的「扩展」，
/// 但 `information_schema.PLUGINS` 能列出已加载插件 —— 那是**近似物**。
/// 直接说「不支持」会丢掉有用的信息，直接说「支持」又是骗人；所以单列一档，
/// 查询照发、说明一并呈现。
public enum ServerObjectQueryPlan: Equatable, Sendable {
    case query(sql: String)
    /// 有近似物，但语义不完全等价：`note` 必须一并呈现。
    case approximation(sql: String, note: String)
    /// 该方言没有这个概念：`reason` 是可读中文说明，**一条 SQL 都不生成**。
    case unsupported(reason: String)

    /// 要执行的 SQL；不支持时 nil（上层据此不发查询）。
    public var sql: String? {
        switch self {
        case .query(let sql): return sql
        case .approximation(let sql, _): return sql
        case .unsupported: return nil
        }
    }

    public var isSupported: Bool { sql != nil }

    public var note: String? {
        if case .approximation(_, let note) = self { return note }
        return nil
    }

    public var unsupportedReason: String? {
        if case .unsupported(let reason) = self { return reason }
        return nil
    }
}

// MARK: - 方言能力

/// 服务器级对象的方言能力（FR-SESS-03）。
///
/// 为什么**另立**协议而不是往 `SQLDialect` 上加方法：本轮任务限定只新建文件、不改既有协议。
/// 做法与 `DatabaseStats` 的 `databaseStatsQuery(_:limit:)` 完全一致 —— 这是一条「能力开口」：
/// - 支持的方言返回 SQL；
/// - 不支持的方言返回 `nil` + 一句可读中文（`unsupportedReason(for:)`），由上层翻成人话。
///
/// 关键纪律：**不支持就是不发 SQL**。发一条必定报错的 `CREATE TABLESPACE` 过去，
/// 用户看到的是数据库报的语法 / 权限错误 —— 那会把「这个功能对你不可用」误报成「你的库坏了」。
public protocol ServerObjectDialect: Sendable {
    var databaseType: DatabaseType { get }
    var identifierQuote: String { get }
    func quoteIdentifier(_ identifier: String) -> String
    /// 字符串字面量（口令 / 目录路径）。转义规则**按方言走**：PG 只需把 `'` 翻倍，
    /// MySQL 协议族还要把反斜杠转义（否则 `\` 会被当成转义前缀吃掉）。
    func stringLiteral(_ value: String) -> String

    /// 列出某类对象的查询；nil = 该方言没有这个概念。
    func listQuery(for kind: ServerObjectKind, limit: Int) -> String?
    /// 该查询是否只是**近似物**（例如 MySQL 协议族用 `mysql.user` 近似角色）；返回说明即为近似。
    func approximationNote(for kind: ServerObjectKind) -> String?
    /// 不支持时的可读中文说明；支持时返回 nil。
    func unsupportedReason(for kind: ServerObjectKind) -> String?

    // 写操作（DCL / DDL）。返回 nil = 该方言不支持这个操作。
    func createRoleStatement(_ spec: RoleSpec) -> String?
    func alterRoleStatement(name: String, host: String, password: String?, canLogin: Bool?, isSuperuser: Bool?) -> String?
    func renameRoleStatement(name: String, host: String, newName: String) -> String?
    func dropRoleStatement(name: String, host: String) -> String?

    func createTablespaceStatement(_ spec: TablespaceSpec) -> String?
    func dropTablespaceStatement(name: String) -> String?

    func createExtensionStatement(_ spec: ExtensionSpec) -> String?
    func dropExtensionStatement(name: String) -> String?

    // 能力开关：让通用层能在**发 SQL 之前**给出准确的拒绝理由，而不是等数据库报错。
    /// 建账号是否必须给初始口令（MySQL 协议族 `CREATE USER … IDENTIFIED BY` 必须）。
    var requiresPasswordForRoleCreation: Bool { get }
    /// 是否支持「不可登录」的角色（MySQL 协议族的账号一律可登录）。
    var supportsNoLoginRole: Bool { get }
    /// 是否支持在 CREATE ROLE 里直接给超级用户开关（MySQL 协议族没有）。
    var supportsRoleSuperuserFlag: Bool { get }
}

public extension ServerObjectDialect {
    var requiresPasswordForRoleCreation: Bool { false }
    var supportsNoLoginRole: Bool { true }
    var supportsRoleSuperuserFlag: Bool { true }
    func approximationNote(for kind: ServerObjectKind) -> String? { nil }
    func unsupportedReason(for kind: ServerObjectKind) -> String? { nil }
}

/// 建角色 / 账号的参数（GBase 的账号带来源主机，故单列 `host`）。
public struct RoleSpec: Equatable, Sendable {
    public var name: String
    public var password: String?
    public var canLogin: Bool
    public var isSuperuser: Bool
    /// MySQL 协议族的账号主机（默认 `%`，即任意主机）；PG 忽略此字段。
    public var host: String

    public init(
        name: String,
        password: String? = nil,
        canLogin: Bool = true,
        isSuperuser: Bool = false,
        host: String = "%"
    ) {
        self.name = name
        self.password = password
        self.canLogin = canLogin
        self.isSuperuser = isSuperuser
        self.host = host
    }
}

/// 建表空间的参数。
public struct TablespaceSpec: Equatable, Sendable {
    public var name: String
    public var location: String

    public init(name: String, location: String) {
        self.name = name
        self.location = location
    }
}

/// 安装扩展的参数。
public struct ExtensionSpec: Equatable, Sendable {
    public var name: String
    public var schema: String?
    public var version: String?

    public init(name: String, schema: String? = nil, version: String? = nil) {
        self.name = name
        self.schema = schema
        self.version = version
    }
}

/// PostgreSQL 方言：角色走 `pg_roles`，表空间走 `pg_tablespace`，扩展走 `pg_extension`。
public struct PostgresServerObjectDialect: ServerObjectDialect {
    public let databaseType: DatabaseType = .postgresql
    public let identifierQuote = "\""

    public init() {}

    public func quoteIdentifier(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// PG 的 `standard_conforming_strings` 默认开启：反斜杠是普通字符，只有 `'` 需要翻倍。
    public func stringLiteral(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    /// 只读浏览查询。
    ///
    /// 三处细节：
    /// 1. 角色注释在**共享**目录 `pg_shdescription` 里，故用 `shobj_description`；
    ///    扩展注释在库内目录 `pg_description`，用 `obj_description` —— 用错函数只会拿到 NULL。
    /// 2. 表空间的 `location` 用 `pg_tablespace_location(oid)`（9.2+），
    ///    `pg_default` / `pg_global` 会返回空串（解析层把空串当"没有这个属性"）。
    /// 3. 全部 `ORDER BY` + `LIMIT`：服务器级对象通常不多，但排序是"顺序稳定"的前提，
    ///    上限则防止某个实例上几千个角色把列表撑爆。
    public func listQuery(for kind: ServerObjectKind, limit: Int) -> String? {
        let bounded = max(1, limit)
        switch kind {
        case .role:
            return """
            SELECT r.rolname AS name,
                   r.rolcanlogin AS can_login,
                   r.rolsuper AS is_superuser,
                   pg_catalog.shobj_description(r.oid, 'pg_authid') AS comment
            FROM pg_catalog.pg_roles r
            ORDER BY r.rolname
            LIMIT \(bounded)
            """
        case .tablespace:
            return """
            SELECT t.spcname AS name,
                   pg_catalog.pg_get_userbyid(t.spcowner) AS owner,
                   pg_catalog.pg_tablespace_location(t.oid) AS location,
                   pg_catalog.pg_tablespace_size(t.oid) AS bytes,
                   pg_catalog.shobj_description(t.oid, 'pg_tablespace') AS comment
            FROM pg_catalog.pg_tablespace t
            ORDER BY t.spcname
            LIMIT \(bounded)
            """
        case .extension:
            return """
            SELECT e.extname AS name,
                   e.extversion AS version,
                   n.nspname AS schema,
                   pg_catalog.pg_get_userbyid(e.extowner) AS owner,
                   pg_catalog.obj_description(e.oid, 'pg_extension') AS comment
            FROM pg_catalog.pg_extension e
            LEFT JOIN pg_catalog.pg_namespace n ON n.oid = e.extnamespace
            ORDER BY e.extname
            LIMIT \(bounded)
            """
        }
    }

    public func createRoleStatement(_ spec: RoleSpec) -> String? {
        var options = [spec.canLogin ? "LOGIN" : "NOLOGIN"]
        if spec.isSuperuser { options.append("SUPERUSER") }
        if let password = spec.password, !password.isEmpty {
            options.append("PASSWORD \(stringLiteral(password))")
        }
        return "CREATE ROLE \(quoteIdentifier(spec.name)) WITH \(options.joined(separator: " "))"
    }

    public func alterRoleStatement(
        name: String,
        host: String,
        password: String?,
        canLogin: Bool?,
        isSuperuser: Bool?
    ) -> String? {
        var options: [String] = []
        if let canLogin { options.append(canLogin ? "LOGIN" : "NOLOGIN") }
        if let isSuperuser { options.append(isSuperuser ? "SUPERUSER" : "NOSUPERUSER") }
        if let password, !password.isEmpty {
            options.append("PASSWORD \(stringLiteral(password))")
        }
        guard !options.isEmpty else { return nil }
        return "ALTER ROLE \(quoteIdentifier(name)) WITH \(options.joined(separator: " "))"
    }

    public func renameRoleStatement(name: String, host: String, newName: String) -> String? {
        "ALTER ROLE \(quoteIdentifier(name)) RENAME TO \(quoteIdentifier(newName))"
    }

    public func dropRoleStatement(name: String, host: String) -> String? {
        "DROP ROLE \(quoteIdentifier(name))"
    }

    public func createTablespaceStatement(_ spec: TablespaceSpec) -> String? {
        "CREATE TABLESPACE \(quoteIdentifier(spec.name)) LOCATION \(stringLiteral(spec.location))"
    }

    public func dropTablespaceStatement(name: String) -> String? {
        "DROP TABLESPACE \(quoteIdentifier(name))"
    }

    public func createExtensionStatement(_ spec: ExtensionSpec) -> String? {
        var sql = "CREATE EXTENSION \(quoteIdentifier(spec.name))"
        if let schema = spec.schema, !schema.isEmpty {
            sql += " WITH SCHEMA \(quoteIdentifier(schema))"
        }
        if let version = spec.version, !version.isEmpty {
            sql += " VERSION \(stringLiteral(version))"
        }
        return sql
    }

    public func dropExtensionStatement(name: String) -> String? {
        "DROP EXTENSION \(quoteIdentifier(name))"
    }
}

/// GBase 8a 方言（MySQL 协议族）。
///
/// 三条明确的取舍：
/// 1. **表空间：不支持**。GBase 8a 没有表空间概念，数据文件由实例自行管理 ——
///    这里返回 nil + 一句中文说明，绝不发 `CREATE TABLESPACE`（发了必报错）。
/// 2. **扩展：不支持**（浏览用 `information_schema.PLUGINS` 作近似物）。
///    插件的装载由实例启动参数决定，不能在会话里 CREATE / DROP。
/// 3. **角色：用 `mysql.user` 近似**。GBase 8a 没有独立的「角色」对象，
///    只有账号；写操作走 `CREATE USER 'x'@'%'` 这套 MySQL 语法。
///
/// ⚠️ 待真实 GBase 8a 实例验证：`mysql.user` 的可见性与列名、
/// `information_schema.PLUGINS` 是否存在（本机没有 GBase 实例，结论来自 MySQL 5.x 协议族推断）。
public struct GBaseServerObjectDialect: ServerObjectDialect {
    public let databaseType: DatabaseType = .gbase8a
    public let identifierQuote = "`"

    /// MySQL 协议族的反斜杠是转义前缀，必须与 `'` 一起转义。
    public var requiresPasswordForRoleCreation: Bool { true }
    public var supportsNoLoginRole: Bool { false }
    public var supportsRoleSuperuserFlag: Bool { false }

    public init() {}

    /// 账号名在 `'x'@'%'` 里是**字符串字面量**，不是标识符 —— 这里仍按字面量转义，
    /// 避免调用方误以为可以用 `quoteIdentifier` 拼账号。
    public func quoteIdentifier(_ identifier: String) -> String {
        "`\(identifier.replacingOccurrences(of: "`", with: "``"))`"
    }

    public func stringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "''")
        return "'\(escaped)'"
    }

    public func listQuery(for kind: ServerObjectKind, limit: Int) -> String? {
        let bounded = max(1, limit)
        switch kind {
        case .role:
            return """
            SELECT User AS name,
                   Host AS host
            FROM mysql.user
            ORDER BY User, Host
            LIMIT \(bounded)
            """
        case .tablespace:
            // 没有对应物：返回 nil，由 `unsupportedReason` 给可读说明。
            return nil
        case .extension:
            // 近似物：已加载插件清单（只读，且不能在这里增删）。
            return """
            SELECT PLUGIN_NAME AS name,
                   PLUGIN_VERSION AS version,
                   PLUGIN_STATUS AS status
            FROM information_schema.PLUGINS
            ORDER BY PLUGIN_NAME
            LIMIT \(bounded)
            """
        }
    }

    public func approximationNote(for kind: ServerObjectKind) -> String? {
        switch kind {
        case .role:
            return "GBase 8a 没有独立的「角色」对象：这里列出的是账号（mysql.user，含来源主机），"
                + "其权限模型与 PostgreSQL 的角色不同 —— 同名对象不代表同一套语义。"
        case .extension:
            return "GBase 8a 没有 PostgreSQL 意义上的扩展：这里列出的是实例已加载的插件"
                + "（information_schema.PLUGINS），它们由实例启动参数决定，不能在会话里安装 / 卸载。"
        case .tablespace:
            return nil
        }
    }

    public func unsupportedReason(for kind: ServerObjectKind) -> String? {
        switch kind {
        case .tablespace:
            return "GBase 8a 没有表空间概念：数据文件由实例自行管理，"
                + "不存在用户可创建 / 删除的表空间对象，因此既不能浏览也不能增删改。"
        case .extension:
            return "GBase 8a 不支持在会话里安装 / 卸载扩展（插件）："
                + "插件由实例启动参数决定，只能在服务端配置后重启生效。"
        case .role:
            return nil
        }
    }

    /// `CREATE USER '名'@'主机' IDENTIFIED BY '口令'`（MySQL 语法；账号不是标识符）。
    public func createRoleStatement(_ spec: RoleSpec) -> String? {
        guard let password = spec.password, !password.isEmpty else { return nil }
        return "CREATE USER \(account(spec.name, host: spec.host)) IDENTIFIED BY \(stringLiteral(password))"
    }

    /// GBase 8a 只支持改口令（没有 LOGIN / SUPERUSER 开关）。
    public func alterRoleStatement(
        name: String,
        host: String,
        password: String?,
        canLogin: Bool?,
        isSuperuser: Bool?
    ) -> String? {
        guard canLogin == nil, isSuperuser == nil else { return nil }
        guard let password, !password.isEmpty else { return nil }
        return "ALTER USER \(account(name, host: host)) IDENTIFIED BY \(stringLiteral(password))"
    }

    public func renameRoleStatement(name: String, host: String, newName: String) -> String? {
        "RENAME USER \(account(name, host: host)) TO \(account(newName, host: host))"
    }

    public func dropRoleStatement(name: String, host: String) -> String? {
        "DROP USER \(account(name, host: host))"
    }

    /// 表空间：不支持 —— **一条 SQL 都不生成**。
    public func createTablespaceStatement(_ spec: TablespaceSpec) -> String? { nil }
    public func dropTablespaceStatement(name: String) -> String? { nil }

    /// 扩展：不支持 —— 同上。
    public func createExtensionStatement(_ spec: ExtensionSpec) -> String? { nil }
    public func dropExtensionStatement(name: String) -> String? { nil }

    /// `'用户'@'主机'`。
    private func account(_ name: String, host: String) -> String {
        "\(stringLiteral(name))@\(stringLiteral(host))"
    }
}

/// 按连接类型取方言实现（与 `SQLDialectFactory` 同形）。
public enum ServerObjectDialectFactory {
    public static func make(for databaseType: DatabaseType) -> any ServerObjectDialect {
        switch databaseType {
        case .postgresql: return PostgresServerObjectDialect()
        case .gbase8a: return GBaseServerObjectDialect()
        }
    }
}

// MARK: - 请求

/// 一次写操作的请求（供上层「预览 → 确认 → 执行」三步走用）。
///
/// 做成一个枚举是为了让上层只写**一遍**确认逻辑：预览拿 `plan(_:dialect:)` 的结果，
/// 确认后执行 `command.statement` —— 不存在"某类对象忘了走确认"的缝。
public enum ServerObjectRequest: Equatable, Sendable {
    case createRole(RoleSpec)
    case alterRole(name: String, host: String, password: String?, canLogin: Bool?, isSuperuser: Bool?)
    case renameRole(name: String, host: String, newName: String)
    case dropRole(name: String, host: String)
    case createTablespace(TablespaceSpec)
    case dropTablespace(name: String)
    case createExtension(ExtensionSpec)
    case dropExtension(name: String)

    public var kind: ServerObjectKind {
        switch self {
        case .createRole, .alterRole, .renameRole, .dropRole: return .role
        case .createTablespace, .dropTablespace: return .tablespace
        case .createExtension, .dropExtension: return .extension
        }
    }

    public var action: ServerObjectAction {
        switch self {
        case .createRole: return .createRole
        case .alterRole: return .alterRole
        case .renameRole: return .renameRole
        case .dropRole: return .dropRole
        case .createTablespace: return .createTablespace
        case .dropTablespace: return .dropTablespace
        case .createExtension: return .createExtension
        case .dropExtension: return .dropExtension
        }
    }

    public var targetName: String {
        switch self {
        case .createRole(let spec): return spec.name
        case .alterRole(let name, _, _, _, _): return name
        case .renameRole(let name, _, _): return name
        case .dropRole(let name, _): return name
        case .createTablespace(let spec): return spec.name
        case .dropTablespace(let name): return name
        case .createExtension(let spec): return spec.name
        case .dropExtension(let name): return name
        }
    }
}

// MARK: - 纯逻辑入口

/// 服务器级对象管理（FR-SESS-03）：浏览查询构造 + 结果解析 + 增删改语句生成 + 风险标注。
///
/// 与 `DatabaseStats` / `SessionMonitor` 同一分工：**这里只有纯逻辑**
/// （不连库、不发请求、不落盘），SQL 由方言层给、执行仍走 `DatabaseService`。
/// 因此全部逻辑都能脱离数据库单测，也正是需求「每个写操作都要能预览与拒绝」的落点。
public enum ServerObjects {

    /// 浏览上限的默认值。
    public static let defaultLimit = 200

    // MARK: 浏览

    /// 某类对象的浏览计划（不发 SQL 也能先问"这个方言支持吗"）。
    public static func browsePlan(
        _ kind: ServerObjectKind,
        dialect: any ServerObjectDialect,
        limit: Int = ServerObjects.defaultLimit
    ) -> ServerObjectQueryPlan {
        guard let sql = dialect.listQuery(for: kind, limit: max(1, limit)) else {
            return .unsupported(reason: unsupportedReason(kind: kind, dialect: dialect))
        }
        if let note = dialect.approximationNote(for: kind) {
            return .approximation(sql: sql, note: note)
        }
        return .query(sql: sql)
    }

    /// 只要 SQL 的便捷入口；不支持时 nil（**调用方应改用 `browsePlan` 拿说明**）。
    public static func browseStatement(
        _ kind: ServerObjectKind,
        dialect: any ServerObjectDialect,
        limit: Int = ServerObjects.defaultLimit
    ) -> String? {
        browsePlan(kind, dialect: dialect, limit: limit).sql
    }

    /// 一次性装配三类对象的清单。
    ///
    /// 传进来的结果按类别给：某类不支持时**不查**也照样能装配（记下说明即可）——
    /// 这正是 `unsupportedReasons` 存在的理由。
    public static func inventory(
        results: [ServerObjectKind: QueryResult],
        dialect: any ServerObjectDialect
    ) -> ServerObjectInventory {
        var inventory = ServerObjectInventory()
        for kind in ServerObjectKind.allCases {
            let plan = browsePlan(kind, dialect: dialect)
            if let reason = plan.unsupportedReason {
                inventory.unsupportedReasons[kind] = reason
                continue
            }
            guard let result = results[kind] else { continue }
            switch kind {
            case .role: inventory.roles = objects(from: result, kind: kind)
            case .tablespace: inventory.tablespaces = objects(from: result, kind: kind)
            case .extension: inventory.extensions = objects(from: result, kind: kind)
            }
        }
        return inventory
    }

    /// 结果集 → 对象列表（列名不敏感、缺列不崩、NULL 不崩）。
    public static func objects(from result: QueryResult, kind: ServerObjectKind) -> [ServerObject] {
        let index = columnIndexMap(result.columns)
        let parsed = result.rows.compactMap { row -> ServerObject? in
            object(kind: kind) { keys in value(row, keys: keys, index: index) }
        }
        return stableSorted(parsed)
    }

    /// `[String: String?]` 行 → 对象列表（键不区分大小写；缺键即缺值）。
    public static func objects(fromRows rows: [[String: String?]], kind: ServerObjectKind) -> [ServerObject] {
        let parsed = rows.compactMap { row -> ServerObject? in
            // 先归一化一行（键小写、值去空白、空值丢弃），再让三类共享同一个查找闭包 ——
            // 逐列重建字典会让行数 × 列数变成平方级的开销，而元数据查询很容易上千行。
            var lowered: [String: String] = [:]
            for (key, raw) in row {
                guard let raw, let text = normalized(raw) else { continue }
                let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if lowered[normalizedKey] == nil { lowered[normalizedKey] = text }
            }
            return object(kind: kind) { keys in
                for key in keys {
                    if let text = lowered[key.lowercased()] { return text }
                }
                return nil
            }
        }
        return stableSorted(parsed)
    }

    /// `[String: String]` 行 → 对象列表（没有"NULL"这一档，缺键即缺值）。
    public static func objects(fromRows rows: [[String: String]], kind: ServerObjectKind) -> [ServerObject] {
        objects(fromRows: rows.map { $0.mapValues { Optional($0) } }, kind: kind)
    }

    // MARK: 写操作

    /// 写操作的统一入口：校验 → 生成语句 → 标注风险；不支持 / 非法都在这里被挡下。
    public static func plan(
        _ request: ServerObjectRequest,
        dialect: any ServerObjectDialect
    ) -> ServerObjectWritePlan {
        switch request {
        case .createRole(let spec):
            return createRole(spec, dialect: dialect)

        case .alterRole(let name, let host, let password, let canLogin, let isSuperuser):
            return alterRole(
                name: name, host: host, password: password,
                canLogin: canLogin, isSuperuser: isSuperuser, dialect: dialect
            )

        case .renameRole(let name, let host, let newName):
            return renameRole(name: name, host: host, newName: newName, dialect: dialect)

        case .dropRole(let name, let host):
            return dropRole(name: name, host: host, dialect: dialect)

        case .createTablespace(let spec):
            return createTablespace(spec, dialect: dialect)

        case .dropTablespace(let name):
            return dropTablespace(name: name, dialect: dialect)

        case .createExtension(let spec):
            return createExtension(spec, dialect: dialect)

        case .dropExtension(let name):
            return dropExtension(name: name, dialect: dialect)
        }
    }

    /// `CREATE ROLE … LOGIN PASSWORD …`（PG）/ `CREATE USER … IDENTIFIED BY …`（GBase）。
    public static func createRole(_ spec: RoleSpec, dialect: any ServerObjectDialect) -> ServerObjectWritePlan {
        if let failure = nameValidationFailure(spec.name, kind: .role) { return .rejected(reason: failure) }
        if let password = spec.password, let failure = passwordValidationFailure(password) {
            return .rejected(reason: failure)
        }
        if !spec.canLogin, !dialect.supportsNoLoginRole {
            return .rejected(reason: "\(dialect.databaseType.displayName) 的账号一律可登录，"
                + "没有 NOLOGIN 这个概念（要收回登录能力只能删账号）。")
        }
        if spec.isSuperuser, !dialect.supportsRoleSuperuserFlag {
            return .rejected(reason: "\(dialect.databaseType.displayName) 的建账号语句里没有超级用户开关，"
                + "超级权限要另外用 GRANT … WITH GRANT OPTION 授予；本实现不代发 GRANT。")
        }
        if dialect.requiresPasswordForRoleCreation, (spec.password ?? "").isEmpty {
            return .rejected(reason: "\(dialect.databaseType.displayName) 建账号必须给出初始口令"
                + "（语句是 CREATE USER … IDENTIFIED BY …）。")
        }
        guard let statement = dialect.createRoleStatement(spec) else {
            return unsupported(kind: .role, dialect: dialect)
        }
        var warnings = ["建角色会改变服务器级的权限主体，需要 CREATEROLE / 超级用户权限。"]
        if spec.isSuperuser { warnings.append("超级用户不受任何权限检查，请确认这是有意的。") }
        return ready(
            kind: .role, action: .createRole, target: spec.name, statement: statement, warnings: warnings
        )
    }

    /// `ALTER ROLE …`：只带上**显式给过**的项（`nil` = 这一项不动）。
    public static func alterRole(
        name: String,
        host: String = "%",
        password: String?,
        canLogin: Bool?,
        isSuperuser: Bool?,
        dialect: any ServerObjectDialect
    ) -> ServerObjectWritePlan {
        if let failure = nameValidationFailure(name, kind: .role) { return .rejected(reason: failure) }
        if let password, let failure = passwordValidationFailure(password) { return .rejected(reason: failure) }
        if password == nil, canLogin == nil, isSuperuser == nil {
            return .rejected(reason: "没有给出任何要修改的项（口令 / 登录开关 / 超级用户开关至少要给一个）。")
        }
        if canLogin == false, !dialect.supportsNoLoginRole {
            return .rejected(reason: "\(dialect.databaseType.displayName) 的账号一律可登录，没有 NOLOGIN 这个概念。")
        }
        if isSuperuser != nil, !dialect.supportsRoleSuperuserFlag {
            return .rejected(reason: "\(dialect.databaseType.displayName) 的账号语句里没有超级用户开关，"
                + "无法通过本入口改动超级权限。")
        }
        guard let statement = dialect.alterRoleStatement(
            name: name, host: host, password: password, canLogin: canLogin, isSuperuser: isSuperuser
        ) else {
            return unsupported(kind: .role, dialect: dialect)
        }
        return ready(
            kind: .role, action: .alterRole, target: name, statement: statement,
            warnings: ["改的是服务器级权限主体，对该账号已建立的连接不是立刻生效。"]
        )
    }

    /// 重命名角色（PG 用 `ALTER ROLE … RENAME TO`，MySQL 协议族用 `RENAME USER`）。
    public static func renameRole(
        name: String,
        host: String = "%",
        newName: String,
        dialect: any ServerObjectDialect
    ) -> ServerObjectWritePlan {
        if let failure = nameValidationFailure(name, kind: .role) { return .rejected(reason: failure) }
        if let failure = nameValidationFailure(newName, kind: .role) {
            return .rejected(reason: "新名字不合法：\(failure)")
        }
        guard let statement = dialect.renameRoleStatement(name: name, host: host, newName: newName) else {
            return unsupported(kind: .role, dialect: dialect)
        }
        return ready(
            kind: .role, action: .renameRole, target: name, statement: statement,
            warnings: ["重命名不会改变该角色的权限，但引用旧名字的脚本 / 配置会失败。"]
        )
    }

    /// 删除角色（高危：不可逆，且名下还有对象时服务端会拒绝）。
    public static func dropRole(
        name: String,
        host: String = "%",
        dialect: any ServerObjectDialect
    ) -> ServerObjectWritePlan {
        if let failure = nameValidationFailure(name, kind: .role) { return .rejected(reason: failure) }
        guard let statement = dialect.dropRoleStatement(name: name, host: host) else {
            return unsupported(kind: .role, dialect: dialect)
        }
        return ready(
            kind: .role, action: .dropRole, target: name, statement: statement,
            warnings: ["删除不可逆。",
                       "若该角色名下还有对象或已授权限，PostgreSQL 会拒绝删除 —— "
                       + "需要先 REASSIGN OWNED / DROP OWNED（本实现不代发这两条）。"]
        )
    }

    /// `CREATE TABLESPACE … LOCATION …`（GBase 明确不支持，不会生成 SQL）。
    public static func createTablespace(_ spec: TablespaceSpec, dialect: any ServerObjectDialect) -> ServerObjectWritePlan {
        if let failure = nameValidationFailure(spec.name, kind: .tablespace) { return .rejected(reason: failure) }
        if let failure = locationValidationFailure(spec.location) { return .rejected(reason: failure) }
        guard let statement = dialect.createTablespaceStatement(spec) else {
            return unsupported(kind: .tablespace, dialect: dialect)
        }
        return ready(
            kind: .tablespace, action: .createTablespace, target: spec.name, statement: statement,
            warnings: ["需要超级用户权限。",
                       "目标目录必须**已经存在**、由数据库进程可写、且为空。"]
        )
    }

    /// 删除表空间（高危：只删目录项，磁盘目录要自己清）。
    public static func dropTablespace(name: String, dialect: any ServerObjectDialect) -> ServerObjectWritePlan {
        if let failure = nameValidationFailure(name, kind: .tablespace) { return .rejected(reason: failure) }
        guard let statement = dialect.dropTablespaceStatement(name: name) else {
            return unsupported(kind: .tablespace, dialect: dialect)
        }
        return ready(
            kind: .tablespace, action: .dropTablespace, target: name, statement: statement,
            warnings: ["删除不可逆。", "该表空间里还有对象时会被拒绝（要清空后才能删）。",
                       "只删除数据库里的表空间对象，**不删除磁盘目录**，磁盘空间要另行回收。"]
        )
    }

    /// `CREATE EXTENSION …`（GBase 明确不支持）。
    public static func createExtension(_ spec: ExtensionSpec, dialect: any ServerObjectDialect) -> ServerObjectWritePlan {
        if let failure = nameValidationFailure(spec.name, kind: .extension) { return .rejected(reason: failure) }
        if let schema = spec.schema, !schema.isEmpty,
           let failure = identifierValidationFailure(schema, label: "schema", kind: .role) {
            return .rejected(reason: "schema 名不合法：\(failure)")
        }
        guard let statement = dialect.createExtensionStatement(spec) else {
            return unsupported(kind: .extension, dialect: dialect)
        }
        return ready(
            kind: .extension, action: .createExtension, target: spec.name, statement: statement,
            warnings: ["需要超级用户权限（部分扩展例外）。",
                       "扩展的 .control 文件必须已经装在实例的扩展目录里，否则会报「找不到扩展」。"]
        )
    }

    /// 删除扩展（高危：依赖它的对象会一起失效）。
    public static func dropExtension(name: String, dialect: any ServerObjectDialect) -> ServerObjectWritePlan {
        if let failure = nameValidationFailure(name, kind: .extension) { return .rejected(reason: failure) }
        guard let statement = dialect.dropExtensionStatement(name: name) else {
            return unsupported(kind: .extension, dialect: dialect)
        }
        return ready(
            kind: .extension, action: .dropExtension, target: name, statement: statement,
            warnings: ["删除不可逆。", "依赖该扩展的对象（函数 / 类型 / 视图）会一起不可用；"
                       + "本实现**不代发 CASCADE**，有依赖时服务端会直接拒绝。"]
        )
    }

    // MARK: 校验（纯函数）

    /// 名字校验；返回 nil = 通过，否则是可读的中文理由。
    ///
    /// 顺序是刻意的：先挡**结构性注入**（分号 / 引号 / 注释符），再谈标识符规则 ——
    /// `a; DROP ROLE postgres` 这种名字必须拿到"不能有分号"这句话，
    /// 而不是笼统的"不符合标识符规则"（后者会让人以为是长度或大小写问题）。
    public static func nameValidationFailure(_ name: String, kind: ServerObjectKind) -> String? {
        identifierValidationFailure(name, label: "\(kind.displayName)名", kind: kind)
    }

    /// 名字校验的实现：`label` 只影响文案（例如「schema 不能为空」）。
    private static func identifierValidationFailure(
        _ name: String,
        label: String,
        kind: ServerObjectKind
    ) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "\(label)不能为空。" }
        if trimmed != name { return "名字的首尾不能有空白（否则会建出一个看不见名字边界的对象）。" }
        if trimmed.contains(";") {
            return "名字里不能有分号 —— 分号是语句分隔符，"
                + "「a; DROP ...」这样的名字会拼出第二条语句。"
        }
        if trimmed.contains("--") || trimmed.contains("/*") || trimmed.contains("*/") {
            return "名字里不能有注释符号（-- / /* */）—— 注释会把后面的语句吃掉。"
        }
        if trimmed.contains("\0") { return "名字里不能有 NUL 字符。" }
        for quote in ["'", "\"", "`", "\\"] {
            if trimmed.contains(quote) {
                return "名字里不能有引号或反斜杠（\(quote)）—— 标识符由本实现统一加引号，"
                    + "名字里再出现引号就有注入风险。"
            }
        }
        if trimmed.utf8.count > 63 {
            return "名字超过 63 字节上限（PostgreSQL 的标识符上限），请缩短。"
        }

        switch kind {
        case .role, .tablespace:
            if !PrivilegeProbe.isValidIdentifier(trimmed) {
                return "名字不符合标识符规则：首字符须为字母或下划线，其余为字母 / 数字 / _ / $。"
            }
        case .extension:
            // 扩展名放宽到字母 / 数字 / `_` / `-` / `.`：`uuid-ossp` 这种带连字符的扩展名很常见，
            // 而它作为**标识符**（加引号后）是合法的 —— 用角色的严格规则会误杀。
            if !isValidExtensionName(trimmed) {
                return "扩展名不符合规则：首字符须为字母或下划线，其余为字母 / 数字 / _ / - / ."
                    + "（例如 uuid-ossp）。"
            }
        }
        return nil
    }

    /// 口令校验（非空、无 NUL）。引号 / 反斜杠由方言的 `stringLiteral` 负责转义，不做拒绝。
    public static func passwordValidationFailure(_ password: String) -> String? {
        if password.isEmpty { return "口令不能为空（要么给一个非空口令，要么改成不可登录的角色）。" }
        if password.contains("\0") { return "口令里不能有 NUL 字符。" }
        return nil
    }

    /// 表空间目录校验：必须是绝对路径，且不含引号 / 分号（路径是**字面量**，但注入风险一样要挡）。
    public static func locationValidationFailure(_ location: String) -> String? {
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "表空间的目录不能为空。" }
        if trimmed != location { return "目录的首尾不能有空白。" }
        if !trimmed.hasPrefix("/") {
            return "表空间的目录必须是绝对路径（PostgreSQL 要求，例如 /data/pg_tbs）。"
        }
        if trimmed.contains(";") { return "目录里不能有分号（会被当成语句分隔符）。" }
        if trimmed.contains("'") || trimmed.contains("\"") || trimmed.contains("\\") {
            return "目录里不能有引号或反斜杠 —— 路径按字面量拼接，出现引号就有注入风险。"
        }
        if trimmed.contains("\0") { return "目录里不能有 NUL 字符。" }
        return nil
    }

    /// 破坏性等级的人话（`AgentRiskLevel` 没有 `displayName`，这里补一个本地的，
    /// 避免为了一句文案去改既有文件）。
    public static func riskText(_ risk: AgentRiskLevel) -> String {
        switch risk {
        case .low: return "低风险"
        case .elevated: return "需确认"
        case .destructive: return "不可逆（高危）"
        }
    }

    /// 该操作是否必须二次确认。
    public static func requiresConfirmation(_ action: ServerObjectAction) -> Bool {
        action.requiresConfirmation
    }

    /// 人读的字节数（与 `DatabaseStats.formatBytes` 同一口径，避免两处各写一份）。
    public static func formatBytes(_ bytes: Int64) -> String {
        DatabaseStats.formatBytes(bytes)
    }

    // MARK: 内部

    private static func unsupported(
        kind: ServerObjectKind,
        dialect: any ServerObjectDialect
    ) -> ServerObjectWritePlan {
        .unsupported(reason: unsupportedReason(kind: kind, dialect: dialect))
    }

    private static func unsupportedReason(
        kind: ServerObjectKind,
        dialect: any ServerObjectDialect
    ) -> String {
        dialect.unsupportedReason(for: kind)
            ?? "\(dialect.databaseType.displayName) 不支持查看 / 管理\(kind.displayName)。"
    }

    private static func ready(
        kind: ServerObjectKind,
        action: ServerObjectAction,
        target: String,
        statement: String,
        warnings: [String]
    ) -> ServerObjectWritePlan {
        .ready(
            ServerObjectCommand(
                kind: kind,
                action: action,
                targetName: target,
                statement: statement,
                risk: action.risk,
                warnings: warnings
            )
        )
    }

    /// 行 → 对象。三类的列名各自成组（并兼容 GBase 的 `User` / `Host` 之类命名）。
    private static func object(kind: ServerObjectKind, lookup: ([String]) -> String?) -> ServerObject? {
        guard let name = lookup(nameKeys(for: kind)), !name.isEmpty else { return nil }

        switch kind {
        case .role:
            return ServerObject(
                kind: kind,
                name: name,
                owner: lookup(["owner", "host", "account_host"]),
                comment: lookup(["comment", "description"]),
                canLogin: PrivilegeProbe.booleanValue(from: lookup(["can_login", "rolcanlogin", "canlogin"])),
                isSuperuser: PrivilegeProbe.booleanValue(
                    from: lookup(["is_superuser", "rolsuper", "superuser", "issuperuser"])
                )
            )

        case .tablespace:
            return ServerObject(
                kind: kind,
                name: name,
                owner: lookup(["owner", "spcowner"]),
                comment: lookup(["comment", "description"]),
                location: lookup(["location", "spclocation"]),
                sizeBytes: Int64(lookup(["bytes", "size", "size_bytes"]) ?? "")
            )

        case .extension:
            return ServerObject(
                kind: kind,
                name: name,
                owner: lookup(["owner", "extowner"]),
                comment: lookup(["comment", "description"]),
                version: lookup(["version", "extversion", "plugin_version"]),
                schema: lookup(["schema", "nspname", "schema_name"]),
                status: lookup(["status", "plugin_status"])
            )
        }
    }

    private static func nameKeys(for kind: ServerObjectKind) -> [String] {
        switch kind {
        case .role: return ["name", "rolname", "user", "usename"]
        case .tablespace: return ["name", "spcname"]
        case .extension: return ["name", "extname", "plugin_name"]
        }
    }

    /// 扩展名：首字符字母 / `_`，其余字母 / 数字 / `_` / `-` / `.`。
    private static func isValidExtensionName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        for (index, character) in name.enumerated() {
            if index == 0 {
                guard character == "_" || character.isLetter else { return false }
            } else {
                guard character == "_" || character == "-" || character == "."
                    || character.isLetter || character.isNumber else { return false }
            }
        }
        return true
    }

    /// 顺序稳定：先名字，再属主 / 状态，最后按**输入顺序**兜底。
    ///
    /// 为什么要显式兜底：Swift 的 `sorted(by:)` 不保证稳定，同名行（例如 GBase 里同一
    /// `User` 的不同 `Host`，只要名字相同就会并列）在两次刷新之间可能换位置，
    /// 用户会以为列表在"自己动"。需求要求"同输入输出稳定（确定）"，这里就钉住它。
    private static func stableSorted(_ objects: [ServerObject]) -> [ServerObject] {
        objects.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.name != rhs.element.name { return lhs.element.name < rhs.element.name }
                let left = lhs.element.owner ?? ""
                let right = rhs.element.owner ?? ""
                if left != right { return left < right }
                let leftStatus = lhs.element.status ?? ""
                let rightStatus = rhs.element.status ?? ""
                if leftStatus != rightStatus { return leftStatus < rightStatus }
                return lhs.offset < rhs.offset
            }
            .map { $0.element }
    }

    private static func columnIndexMap(_ columns: [ColumnMeta]) -> [String: Int] {
        var map: [String: Int] = [:]
        for (position, column) in columns.enumerated() {
            let key = column.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if map[key] == nil { map[key] = position }
        }
        return map
    }

    /// 按候选键取第一个**非空**值（NULL / 空串都不算命中，避免空列把真值盖掉）。
    private static func value(_ row: [String?], keys: [String], index: [String: Int]) -> String? {
        for key in keys {
            guard let position = index[key.lowercased()], row.indices.contains(position),
                  let raw = row[position] else { continue }
            return normalized(raw)
        }
        return nil
    }

    /// 去空白；空串按「没有这个属性」处理（而不是"空字符串值"）。
    private static func normalized(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
