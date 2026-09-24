import Foundation

/// 我们把哪些能力暴露给外部智能体（FR-AI-10 的 "server" 方向）。
///
/// 需求原文的硬约束：「权限**继承当前会话**，不另开特权；外部调用同样进审批与审计」。
/// 所以这张表里每个工具都带三件事：
///   · **要什么权限**（只读查询 / 写语句 / 元数据 / 导出）—— 由当前会话的连接属性（只读？生产？）裁定；
///   · **要不要审批**（写语句要；查询不要）；
///   · **审计怎么写**（谁调的、调了什么、结果如何）。
///
/// **刻意不暴露**的能力（写在这里比写在文档里更难被绕过）：连接管理与口令（外部智能体不该能新建 / 改连接）、
/// 备份恢复与维护任务（那是 FR-AI-04 的审批链）、工作区文件读写（那会绕过目录授权）。
public struct MCPTool: Equatable, Sendable {

    public enum Access: String, Equatable, Sendable {
        /// 只读查询（`SELECT` / `EXPLAIN` 等）。
        case readQuery
        /// 会改数据或结构（`INSERT` / `UPDATE` / `DDL` …）。
        case write
        /// 元数据（对象树 / 表结构）。
        case metadata
        /// 导出结果（写文件）。
        case export

        /// 需不需要另一次审批。
        public var requiresApproval: Bool {
            switch self {
            case .readQuery, .metadata: return false
            case .write, .export: return true
            }
        }
    }

    public var name: String
    public var description: String
    public var access: Access
    /// 参数的 JSON Schema（够用的形状：object + 必填字段）。
    public var inputSchema: MCPValue

    public func schemaJSON() -> MCPValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "inputSchema": inputSchema,
        ])
    }
}

public enum MCPToolCatalog {

    public static let querySQL = "query_sql"
    public static let listObjects = "list_objects"
    public static let describeTable = "describe_table"
    public static let exportResult = "export_result"

    /// 暴露出去的四个工具。
    ///
    /// 为什么是这四个：它们正好覆盖需求原文点名的「连接 / 查询 / 元数据 / 导出」，
    /// 又都能**落到当前会话已有的权限与安全动线**上（查询与导出走 `ExecutionSafety`、
    /// 元数据走 `MetadataService`）—— 不新增任何特权路径。
    public static let all: [MCPTool] = [
        MCPTool(
            name: querySQL,
            description: "Run one SQL statement on the current connection. Write statements require approval.",
            access: .readQuery,
            inputSchema: schema(required: ["sql"], properties: ["sql": "string"])
        ),
        MCPTool(
            name: listObjects,
            description: "List databases, schemas and tables of the current connection.",
            access: .metadata,
            inputSchema: schema(required: [], properties: [:])
        ),
        MCPTool(
            name: describeTable,
            description: "Describe one table (columns and types).",
            access: .metadata,
            inputSchema: schema(required: ["table"], properties: ["table": "string", "schema": "string"])
        ),
        MCPTool(
            name: exportResult,
            description: "Export the result of one query to a file (requires approval).",
            access: .export,
            inputSchema: schema(required: ["sql", "path"], properties: ["sql": "string", "path": "string"])
        ),
    ]

    public static func tool(named name: String) -> MCPTool? {
        all.first { $0.name == name }
    }

    /// **一次调用的指纹**（批准按"这一次"算，不按工具名算）。
    ///
    /// 为什么是"按次"：一开始我用"工具名"当批准单位，脚本当场把它暴露出来了 ——
    /// `--allow query_sql` 之后，**任何**写语句都能通过同一个工具跑掉（实测真的把
    /// `DELETE FROM customers` 下发到了库里，只是被外键挡了下来）。需求原文要的是
    /// 「外部调用同样进审批」，那就必须是**每一次调用**都能被人看一眼再决定。
    public static func callFingerprint(tool: String, arguments: MCPValue) -> String {
        // `jsonText` 按 key 排序，因此同一份参数每次算出来一样（可用于跨进程批准）。
        "\(tool)|\(arguments.jsonText)"
    }

    private static func schema(required: [String], properties: [String: String]) -> MCPValue {
        var propertyObjects: [String: MCPValue] = [:]
        for (key, type) in properties {
            propertyObjects[key] = .object(["type": .string(type)])
        }
        return .object([
            "type": .string("object"),
            "properties": .object(propertyObjects),
            "required": .array(required.map { .string($0) }),
            "additionalProperties": .bool(false),
        ])
    }

    /// 某个工具在**当前会话**下能不能跑 —— 判据就是这一条，别处不要另写。
    ///
    /// - Parameters:
    ///   - tool: 要调的工具。
    ///   - sql: 如果是执行语句的工具，把语句一起给进来（写不写不取决于工具名，取决于**语句内容**：
    ///     `query_sql` 里塞一条 `DROP TABLE` 就是写操作）。
    ///   - isReadOnlyConnection: 当前连接是不是只读（它**不可绕过**，与 `ExecutionSafety` 同口径）。
    ///   - isApproved: 需要审批的工具，这一轮外部调用是否已获批。
    public static func decision(
        for tool: MCPTool,
        sql: String? = nil,
        databaseType: DatabaseType = .postgresql,
        isReadOnlyConnection: Bool = false,
        isApproved: Bool = false
    ) -> MCPToolDecision {
        // 语句内容优先：先看这条语句本身是什么性质（工具名只是入口，不是判据）。
        var access = tool.access
        var safety: ExecutionSafety.Decision?
        if let sql, !sql.isEmpty {
            let decision = ExecutionSafety.check(
                sql: sql,
                databaseType: databaseType,
                policy: ExecutionSafetyPolicy(isEnabled: true, isReadOnly: isReadOnlyConnection)
            )
            safety = decision
            switch decision {
            case .refused:
                // 只读连接上的写语句：直接拒绝，**下面的审批也救不回来**。
                return .refused(reason: text(.mcpRefusedReadOnly))
            case .needsConfirmation:
                access = .write
            case .allow:
                // 即使 `ExecutionSafety` 放行，只要语句本身会改数据 / 结构，就按写操作对待
                // （两条判据都看一遍：一条判"连接允不允许"，一条判"语句是什么性质"）。
                if AgentGuardrail.evaluate(sql: sql).statements.contains(where: { $0.kind.changesDataOrSchema }) {
                    access = .write
                }
            }
        }

        if access.requiresApproval, !isApproved {
            return .needsApproval(reason: text(.mcpNeedsApproval, tool.name))
        }
        // 只读连接上，写工具一律拒绝 —— **审批也不能把它变成"可以"**。
        if access.requiresApproval, isReadOnlyConnection {
            return .refused(reason: text(.mcpRefusedReadOnly))
        }
        return .allowed(access: access, safety: safety)
    }
}

/// 单个工具调用的裁决。
public enum MCPToolDecision: Equatable, Sendable {
    case allowed(access: MCPTool.Access, safety: ExecutionSafety.Decision?)
    case needsApproval(reason: String)
    case refused(reason: String)

    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }
}

/// 审计条目：外部每一次调用都留痕（需求原文「外部调用同样进审批与审计」）。
public struct MCPAuditEntry: Equatable, Sendable {
    public var at: Date
    /// 外部对端的自称（`initialize` 里的 clientInfo.name）。
    public var client: String
    public var tool: String
    /// 参数摘要（**不含口令**：这一层只收到工具参数）。
    public var argumentsSummary: String
    public var outcome: String

    public init(at: Date = Date(), client: String, tool: String, argumentsSummary: String, outcome: String) {
        self.at = at
        self.client = client
        self.tool = tool
        self.argumentsSummary = argumentsSummary
        self.outcome = outcome
    }

    public var jsonText: String {
        MCPValue.object([
            "at": .string(ISO8601DateFormatter().string(from: at)),
            "client": .string(client),
            "tool": .string(tool),
            "arguments": .string(argumentsSummary),
            "outcome": .string(outcome),
        ]).jsonText
    }
}

/// Core 侧的文案取值（与其余 Core 展示文本同一现状：默认简体中文，界面语言透传见 R-45）。
private func text(_ key: LKey, _ arguments: CVarArg...) -> String {
    if arguments.isEmpty {
        return LocalizedStrings.text(key, language: .simplifiedChinese)
    }
    return LocalizedStrings.format(key, language: .simplifiedChinese, arguments)
}
