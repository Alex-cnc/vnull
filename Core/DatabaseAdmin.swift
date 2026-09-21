import Foundation

// MARK: - 已授权限（FR-SESS-04）

/// 一条「某角色在某对象上拥有的权限」。
///
/// 对应 `SQLDialect.objectPrivilegeQuery(role:)` 的六列输出
/// （`object_kind` / `object_name` / `schema_name` / `grantee` / `privilege_type` / `is_grantable`）。
public struct ObjectPrivilege: Identifiable, Hashable, Sendable {
    /// 对象类别。
    public enum ObjectKind: String, Codable, Sendable, CaseIterable {
        case database
        case schema
        case table
        case view
        case sequence
        case function
        /// 服务端返回了无法识别的类别（不丢行，归类到此处）。
        case other

        public init(serverValue: String?) {
            let normalized = (serverValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            self = ObjectKind(rawValue: normalized) ?? .other
        }
    }

    /// 稳定标识：同一角色在同一对象上的同一权限只应出现一条。
    public var id: String {
        "\(objectKind.rawValue)|\(schema ?? "")|\(objectName)|\(grantee)|\(privilege)"
    }

    public var objectKind: ObjectKind
    public var objectName: String
    /// 对象所属 schema；库级权限没有 schema。
    public var schema: String?
    /// 被授权角色（`PUBLIC` 表示所有角色）。
    public var grantee: String
    /// 权限名，例如 `SELECT` / `CONNECT` / `USAGE`。
    public var privilege: String
    /// 是否带 `WITH GRANT OPTION`。
    public var isGrantable: Bool

    public init(
        objectKind: ObjectKind,
        objectName: String,
        schema: String? = nil,
        grantee: String,
        privilege: String,
        isGrantable: Bool = false
    ) {
        self.objectKind = objectKind
        self.objectName = objectName
        self.schema = schema
        self.grantee = grantee
        self.privilege = privilege
        self.isGrantable = isGrantable
    }

    /// 带 schema 限定的对象名。
    public var qualifiedObjectName: String {
        guard let schema, !schema.isEmpty else { return objectName }
        return "\(schema).\(objectName)"
    }

    /// 列表显示用：`对象类别 对象名 · 权限`。
    public var displayName: String {
        "\(objectKind.rawValue) \(qualifiedObjectName) · \(privilege)"
    }
}

/// 权限查询结果的解析（FR-SESS-04）。
public enum ObjectPrivilegeParser {

    /// 把 `objectPrivilegeQuery` 的结果解析成权限列表。
    ///
    /// - 列名匹配不区分大小写；
    /// - 缺 `object_name` 或 `privilege_type` 的行跳过（不是有效的权限记录）；
    /// - `grantee` 缺失时归一为 `PUBLIC`（与查询里的 `COALESCE` 语义一致）；
    /// - 输出按「对象类别 → 对象名 → 权限名」排序，便于界面稳定展示。
    public static func privileges(from result: QueryResult) -> [ObjectPrivilege] {
        let index = LockMonitor.columnIndexMap(result.columns)

        let parsed = result.rows.compactMap { row -> ObjectPrivilege? in
            guard let objectName = LockMonitor.value(row, keys: ["object_name"], index: index)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !objectName.isEmpty,
                let privilege = LockMonitor.value(row, keys: ["privilege_type", "privilege"], index: index)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !privilege.isEmpty
            else { return nil }

            let schema = LockMonitor.value(row, keys: ["schema_name", "schema"], index: index)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let grantee = LockMonitor.value(row, keys: ["grantee"], index: index)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return ObjectPrivilege(
                objectKind: ObjectPrivilege.ObjectKind(
                    serverValue: LockMonitor.value(row, keys: ["object_kind", "kind"], index: index)
                ),
                objectName: objectName,
                schema: (schema?.isEmpty ?? true) ? nil : schema,
                grantee: (grantee?.isEmpty ?? true) ? "PUBLIC" : grantee!,
                privilege: privilege.uppercased(),
                isGrantable: PrivilegeProbe.booleanValue(
                    from: LockMonitor.value(row, keys: ["is_grantable", "grantable"], index: index)
                ) ?? false
            )
        }

        return sorted(parsed)
    }

    /// 排序：对象类别（已识别类别在前、「其他」殿后）→ schema → 对象名 → 权限名。
    public static func sorted(_ privileges: [ObjectPrivilege]) -> [ObjectPrivilege] {
        privileges.sorted { lhs, rhs in
            let lhsRank = rank(of: lhs.objectKind)
            let rhsRank = rank(of: rhs.objectKind)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            if lhs.qualifiedObjectName != rhs.qualifiedObjectName {
                return lhs.qualifiedObjectName < rhs.qualifiedObjectName
            }
            if lhs.privilege != rhs.privilege { return lhs.privilege < rhs.privilege }
            return lhs.grantee < rhs.grantee
        }
    }

    /// 类别顺序按声明顺序（库 → schema → 表 → 视图 → 序列 → 函数），无法识别的排最后。
    private static func rank(of kind: ObjectPrivilege.ObjectKind) -> Int {
        ObjectPrivilege.ObjectKind.allCases.firstIndex(of: kind) ?? ObjectPrivilege.ObjectKind.allCases.count
    }

    /// 按对象聚合（界面按对象分组展示用）。
    public static func groupedByObject(_ privileges: [ObjectPrivilege]) -> [(object: ObjectPrivilege, privileges: [ObjectPrivilege])] {
        var order: [String] = []
        var buckets: [String: [ObjectPrivilege]] = [:]

        for privilege in sorted(privileges) {
            let key = "\(privilege.objectKind.rawValue)|\(privilege.qualifiedObjectName)"
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(privilege)
        }

        return order.compactMap { key in
            guard let items = buckets[key], let first = items.first else { return nil }
            return (object: first, privileges: items)
        }
    }
}

// MARK: - 服务端错误的可读提示（FR-SESS-04 / FR-SESS-05）

/// 库级 / 权限操作失败时的可读归类。
///
/// 验收要点明确要求「存在其他会话连接时给出可读提示」「无权限时给可读错误」，
/// 因此这里把服务端原文归类成枚举，由界面翻译成整句提示。
public enum DatabaseAdminHint: String, Equatable, Sendable, CaseIterable {
    /// 还有别的会话连着这个库（`DROP DATABASE` 会失败）。
    case activeConnections
    /// 权限不足 / 必须是属主或超级用户。
    case insufficientPrivilege
    /// 目标库不存在。
    case databaseDoesNotExist
    /// 目标库当前正被自己连接（PG 不允许删掉当前连接的库）。
    case currentDatabase

    /// 从服务端错误文本归类；无法识别时返回 `nil`（界面回退为原文）。
    public static func classify(serverMessage: String) -> DatabaseAdminHint? {
        let lower = serverMessage.lowercased()

        if lower.contains("is being accessed by other users")
            || lower.contains("being accessed by other users")
            || lower.contains("有其他会话") {
            return .activeConnections
        }
        if lower.contains("cannot drop the currently open database")
            || lower.contains("current database") {
            return .currentDatabase
        }
        if lower.contains("does not exist") {
            return .databaseDoesNotExist
        }
        if lower.contains("must be owner")
            || lower.contains("must be superuser")
            || lower.contains("permission denied")
            || lower.contains("insufficient privilege")
            || lower.contains("权限不足") {
            return .insufficientPrivilege
        }
        return nil
    }
}
