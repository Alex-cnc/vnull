import Foundation

// MARK: - 执行期错误（全部可读）

/// 数据任务在执行 / 生成语句阶段的错误（FR-AI-05、FR-AI-06、FR-AI-08）。
///
/// 与 `issues`（保存前校验）分工：`issues` 管「定义本身填得对不对」，
/// 这里管「能不能真的编译成 SQL / 能不能真的写文件」。两者都给可读原因，不静默失败。
public enum DataTaskRunError: Error, Equatable, LocalizedError {
    /// 定义本身就有问题（内容是 `issues` 的原文）。
    case invalidDefinition([String])
    /// 未指定源列清单时无法执行这类转换（例如「丢弃列」——`SELECT *` 里挑不出列）。
    case transformationNeedsColumnList(kind: String)
    /// 转换缺少必要字段。
    case missingTransformationField(kind: String, field: String)
    /// 转换引用了源列清单里没有的列。
    case unknownColumn(column: String, kind: String)
    /// `upsert` 需要明确的输出列清单（`SELECT *` 无法生成冲突更新子句）。
    case upsertNeedsColumnList
    /// 该方言不支持 `ON CONFLICT`（当前只有 PostgreSQL 支持）。
    case upsertUnsupported(dialect: String)
    /// 任务没有配置导出目录。
    case missingExportSettings
    /// 读源没有返回结果集。
    case noResultSet
    /// 产物写盘失败（路径与原因都给出来）。
    case exportFailed(fileName: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidDefinition(let issues):
            return "任务定义不完整：" + issues.joined(separator: " ")
        case .transformationNeedsColumnList(let kind):
            return "未指定源列清单，无法执行「\(kind)」转换；请先列出要读取的列。"
        case .missingTransformationField(let kind, let field):
            return "「\(kind)」转换缺少\(field)。"
        case .unknownColumn(let column, let kind):
            return "「\(kind)」转换引用的源列「\(column)」不在源列清单里。"
        case .upsertNeedsColumnList:
            return "更新插入（upsert）需要明确的源列清单，无法用「全部列」生成冲突更新子句。"
        case .upsertUnsupported(let dialect):
            return "\(dialect) 方言不支持 ON CONFLICT 更新插入，请改用追加或覆盖。"
        case .missingExportSettings:
            return "该任务还没有设置导出目录。"
        case .noResultSet:
            return "读取源表没有返回结果集。"
        case .exportFailed(let fileName, let reason):
            return "导出产物「\(fileName)」失败：\(reason)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .invalidDefinition:
            return "在任务编辑器里按提示补齐字段后重试。"
        case .transformationNeedsColumnList, .unknownColumn:
            return "把「源列」填成明确的列清单（每行一列或逗号分隔）。"
        case .missingTransformationField:
            return "在对应的转换步骤里补上缺的字段。"
        case .upsertNeedsColumnList, .upsertUnsupported:
            return "改用「追加」或「覆盖」写入模式。"
        case .missingExportSettings:
            return "在「导出」里选择一个目录并授权。"
        case .noResultSet:
            return "确认源表名与源列清单是否正确。"
        case .exportFailed:
            return "确认授权目录仍然存在且可写，必要时重新选择目录。"
        }
    }
}

// MARK: - 读取语句的编译结果

/// 由任务定义编译出的读取语句（FR-AI-05）。
public struct DataTaskSelect: Equatable, Sendable {
    /// `SELECT ... FROM ... WHERE ...`（不含结尾分号）。
    public var sql: String
    /// 投影输出的列名；`nil` = 用了 `*`（列清单未知，写入时不能带列清单）。
    public var columnNames: [String]?

    public init(sql: String, columnNames: [String]?) {
        self.sql = sql
        self.columnNames = columnNames
    }
}

// MARK: - 执行接线（FR-AI-05 / FR-AI-06 / FR-AI-08）

/// 把「数据任务定义」编译成 SQL，并把产物导出到用户授权的目录。
///
/// 三条边界：
/// - **只编译、不擅自执行**：`.select` / `.writeStatements` 都是纯字符串生成；
///   真正下发由调用方决定，且写语句必须先进 `AgentActionGate`（FR-AI-09，不另造审批）；
/// - **转换在 SQL 里表达**：重命名 / 类型转换 / 派生 / 丢弃 / 脱敏都编译成投影表达式，
///   因此「源 → 转换 → 目标」是一条 `INSERT ... SELECT`，不需要把整表搬到客户端；
/// - **路径只能来自书签**：导出只接受 `DirectoryGrant`（它的 `url` 由书签解析而来），
///   本类型没有任何「传路径就能写」的入口（FR-AI-08）。
public enum DataTaskRunner {

    // MARK: 读取语句

    /// 编译读取语句。`limit` 非空时追加方言的分页子句（试运行 / 预览用）。
    public static func select(
        for task: DataTaskDefinition,
        dialect: any SQLDialect = PostgresDialect(),
        limit: Int? = nil
    ) throws -> DataTaskSelect {
        if !task.issues.isEmpty {
            throw DataTaskRunError.invalidDefinition(task.issues)
        }

        let projections = try projections(for: task, dialect: dialect)
        let hasWildcard = projections.contains { $0.name == nil }

        // 每个投影都显式带别名：重命名 / 派生 / 脱敏都靠它把「输出列名」钉死，
        // 不依赖驱动对表达式列名的推断（推断结果各版本不一致）。
        let selectList = projections.map { projection -> String in
            guard let name = projection.name else { return projection.sql }
            return "\(projection.sql) AS \(dialect.quoteIdentifier(name))"
        }.joined(separator: ", ")
        var sql = "SELECT \(selectList) FROM \(qualified(task.source.schema, task.source.table, dialect: dialect))"
        if let filter = task.source.filter?.trimmingCharacters(in: .whitespacesAndNewlines), !filter.isEmpty {
            sql += " WHERE \(filter)"
        }
        if let limit, limit > 0 {
            sql += " " + dialect.limitClause(offset: 0, count: limit)
        }

        let names: [String]? = hasWildcard ? nil : projections.compactMap(\.name)
        return DataTaskSelect(sql: sql, columnNames: names)
    }

    /// 读取语句（单行便利写法）。
    public static func selectStatement(
        for task: DataTaskDefinition,
        dialect: any SQLDialect = PostgresDialect(),
        limit: Int? = nil
    ) throws -> String {
        try select(for: task, dialect: dialect, limit: limit).sql
    }

    /// 真正从源表读一次（导出产物用）。读是只读语句，不需要审批。
    public static func read(
        _ task: DataTaskDefinition,
        on service: any DatabaseService,
        dialect: any SQLDialect = PostgresDialect(),
        limit: Int? = nil
    ) async throws -> QueryResult {
        let sql = try selectStatement(for: task, dialect: dialect, limit: limit)
        var last: QueryResult?
        for try await event in service.execute(sql, options: .default) {
            if case .resultSet(let result) = event {
                last = result
            }
        }
        guard let last else { throw DataTaskRunError.noResultSet }
        return last
    }

    // MARK: 写入语句

    /// 编译写入语句（覆盖模式会先 `TRUNCATE`，因此顺序敏感、必须逐条下发）。
    ///
    /// 返回的是**语句序列**：调用方可整体交给 `AgentActionGate`（多条会被标成
    /// `multipleStatements` 风险，写操作本来就要逐次审批），再按 `StatementSplitter` 下发。
    public static func writeStatements(
        for task: DataTaskDefinition,
        dialect: any SQLDialect = PostgresDialect()
    ) throws -> [String] {
        if !task.issues.isEmpty {
            throw DataTaskRunError.invalidDefinition(task.issues)
        }

        let select = try select(for: task, dialect: dialect)
        let target = qualified(task.target.schema, task.target.table, dialect: dialect)

        // 列清单：`SELECT *` 时写不出列清单，只能整体 `INSERT ... SELECT`。
        let columnList = select.columnNames.map { names in
            names.map { dialect.quoteIdentifier($0) }.joined(separator: ", ")
        }

        var statements: [String] = []
        if task.target.writeMode == .overwrite {
            statements.append("TRUNCATE TABLE \(target);")
        }

        switch task.target.writeMode {
        case .append, .overwrite:
            let insert = columnList.map { "INSERT INTO \(target) (\($0)) " } ?? "INSERT INTO \(target) "
            statements.append(insert + select.sql + ";")

        case .upsert:
            guard dialect.databaseType == .postgresql else {
                throw DataTaskRunError.upsertUnsupported(dialect: dialect.databaseType.displayName)
            }
            guard let columnList, let names = select.columnNames, !names.isEmpty else {
                throw DataTaskRunError.upsertNeedsColumnList
            }
            let keys = task.target.keyColumns
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { dialect.quoteIdentifier($0) }
                .joined(separator: ", ")
            // 冲突时更新「除冲突键以外」的所有列；没有任何非键列时退回 DO NOTHING。
            let keySet = Set(task.target.keyColumns)
            let updatable = names.filter { !keySet.contains($0) }
            let action: String
            if updatable.isEmpty {
                action = "DO NOTHING"
            } else {
                action = "DO UPDATE SET "
                    + updatable.map { "\(dialect.quoteIdentifier($0)) = EXCLUDED.\(dialect.quoteIdentifier($0))" }
                        .joined(separator: ", ")
            }
            statements.append(
                "INSERT INTO \(target) (\(columnList)) " + select.sql
                    + " ON CONFLICT (\(keys)) " + action + ";"
            )
        }

        return statements
    }

    /// 写入语句合并成一段文本（提交审批 / 记录审计的输入）。
    public static func writeStatementText(
        for task: DataTaskDefinition,
        dialect: any SQLDialect = PostgresDialect()
    ) throws -> String {
        try writeStatements(for: task, dialect: dialect).joined(separator: "\n")
    }

    /// 写语句的护栏判定；编译不出来时返回 `nil`。
    ///
    /// 放在这里是为了让编辑器在**保存前**就能显示「只读模式下这条写语句会被拒」，
    /// 而不是等用户点执行才被拦（判定逻辑与执行路径同一个 `AgentGuardrail`）。
    public static func guardAssessment(
        for task: DataTaskDefinition,
        policy: AgentGuardPolicy,
        databaseType: DatabaseType = .postgresql
    ) -> AgentGuardAssessment? {
        guard let sql = try? writeStatementText(
            for: task,
            dialect: SQLDialectFactory.make(for: databaseType)
        ) else { return nil }
        return AgentGuardrail.evaluate(sql: sql, databaseType: databaseType, policy: policy)
    }

    // MARK: 产物导出（FR-AI-08）

    /// 产物文件名：模板里的 `{task}` / `{timestamp}` 会被替换，并**剥掉路径分隔符**
    /// —— 产物文件名绝不能把写入引到授权目录之外。
    public static func artifactFileName(
        for task: DataTaskDefinition,
        at date: Date = Date()
    ) throws -> String {
        guard let output = task.output else { throw DataTaskRunError.missingExportSettings }

        let extensionName = output.format.rawValue
        let template = (output.fileNameTemplate ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let base: String
        if template.isEmpty {
            base = sanitizeFileName("\(task.name)-\(timestampText(date))")
        } else {
            base = sanitizeFileName(
                template
                    .replacingOccurrences(of: "{task}", with: task.name)
                    .replacingOccurrences(of: "{timestamp}", with: timestampText(date))
            )
        }
        return base.lowercased().hasSuffix(".\(extensionName)") ? base : "\(base).\(extensionName)"
    }

    /// 把读到的结果按任务导出设置写进授权目录（**目录来自书签解析，不硬编码**）。
    @discardableResult
    public static func exportArtifact(
        _ result: QueryResult,
        for task: DataTaskDefinition,
        grant: DirectoryGrant,
        at date: Date = Date()
    ) throws -> URL {
        guard let output = task.output else { throw DataTaskRunError.missingExportSettings }
        let format = ResultExportFormat(rawValue: output.format.rawValue) ?? .csv
        let fileName = try artifactFileName(for: task, at: date)
        let url = grant.fileURL(named: fileName)
        let text = ResultExporter.text(
            for: result,
            format: format,
            tableName: task.target.table,
            schema: task.target.schema
        )
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw DataTaskRunError.exportFailed(fileName: fileName, reason: error.localizedDescription)
        }
        return url
    }

    /// 把「任务定义 + 试运行预览」写成一份可读报告，用于**在真实执行之前**验证授权目录可写。
    ///
    /// 这样「选目录 → 书签 → 真的写出文件」这条链路不依赖数据库也能验证一次（FR-AI-08）。
    @discardableResult
    public static func exportPreviewReport(
        for task: DataTaskDefinition,
        preview: TaskDryRun,
        grant: DirectoryGrant,
        at date: Date = Date()
    ) throws -> URL {
        let fileName = sanitizeFileName("\(task.name)-preview-\(timestampText(date))") + ".txt"
        let url = grant.fileURL(named: fileName)

        var lines: [String] = []
        lines.append("任务：\(task.name)")
        lines.append("生成时间：\(timestampText(date))")
        lines.append("导出目录（书签解析）：\(grant.url.path)")
        lines.append("")
        lines.append("## 规格说明（specs）")
        lines.append(task.specs)
        lines.append("")
        lines.append("## 执行步骤")
        lines.append(contentsOf: preview.steps.map { "- \($0)" })
        lines.append("")
        lines.append("## 预览语句（不会真正执行）")
        lines.append(contentsOf: preview.previewStatements)
        if !preview.warnings.isEmpty {
            lines.append("")
            lines.append("## 告警")
            lines.append(contentsOf: preview.warnings.map { "- \($0)" })
        }
        if !preview.issues.isEmpty {
            lines.append("")
            lines.append("## 问题")
            lines.append(contentsOf: preview.issues.map { "- \($0)" })
        }

        do {
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw DataTaskRunError.exportFailed(fileName: fileName, reason: error.localizedDescription)
        }
        return url
    }

    // MARK: 内部

    /// 一条投影：`sql` 是 SELECT 里的表达式，`name` 是输出列名（`nil` = `*`）。
    struct Projection: Equatable {
        var sql: String
        var name: String?
    }

    /// 把源列 + 转换编译成投影列表。
    ///
    /// 规则（顺序即语义，后一步看到的是前一步的结果）：
    /// - 源列清单为空 → `SELECT *`；此时「丢弃列」无列可挑，直接给可读错误；
    /// - 重命名改变输出列名；类型转换编译成 `CAST(...)`；脱敏 / 派生把表达式括号化后投影。
    static func projections(
        for task: DataTaskDefinition,
        dialect: any SQLDialect
    ) throws -> [Projection] {
        let explicitColumns = task.source.columns
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var projections: [Projection] = explicitColumns.isEmpty
            ? [Projection(sql: "*", name: nil)]
            : explicitColumns.map { Projection(sql: dialect.quoteIdentifier($0), name: $0) }

        for transformation in task.transformations {
            let kindName = transformation.kind.displayName
            switch transformation.kind {
            case .rename:
                let column = try require(transformation.column, kind: kindName, field: "源列名")
                let target = try require(transformation.targetColumn, kind: kindName, field: "目标列名")
                let index = try index(of: column, in: projections, kind: kindName)
                projections[index].name = target

            case .cast:
                let column = try require(transformation.column, kind: kindName, field: "源列名")
                let expression = try require(transformation.expression, kind: kindName, field: "目标类型")
                let index = try index(of: column, in: projections, kind: kindName)
                projections[index] = Projection(
                    sql: "CAST(\(projections[index].sql) AS \(expression))",
                    name: projections[index].name
                )

            case .mask:
                let column = try require(transformation.column, kind: kindName, field: "源列名")
                let expression = try require(transformation.expression, kind: kindName, field: "脱敏表达式")
                let index = try index(of: column, in: projections, kind: kindName)
                projections[index] = Projection(sql: "(\(expression))", name: projections[index].name)

            case .drop:
                let column = try require(transformation.column, kind: kindName, field: "源列名")
                if projections.contains(where: { $0.name == nil }) {
                    throw DataTaskRunError.transformationNeedsColumnList(kind: kindName)
                }
                let index = try index(of: column, in: projections, kind: kindName)
                projections.remove(at: index)

            case .derive:
                let expression = try require(transformation.expression, kind: kindName, field: "表达式")
                let target = try require(transformation.targetColumn, kind: kindName, field: "目标列名")
                projections.append(Projection(sql: "(\(expression))", name: target))
            }
        }

        return projections
    }

    private static func require(
        _ value: String?,
        kind: String,
        field: String
    ) throws -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            throw DataTaskRunError.missingTransformationField(kind: kind, field: field)
        }
        return trimmed
    }

    private static func index(
        of column: String,
        in projections: [Projection],
        kind: String
    ) throws -> Int {
        guard let index = projections.firstIndex(where: { $0.name == column }) else {
            throw DataTaskRunError.unknownColumn(column: column, kind: kind)
        }
        return index
    }

    private static func qualified(_ schema: String?, _ table: String, dialect: any SQLDialect) -> String {
        guard let schema, !schema.isEmpty, dialect.featureSet.contains(.supportsSchemas) else {
            return dialect.quoteIdentifier(table)
        }
        return "\(dialect.quoteIdentifier(schema)).\(dialect.quoteIdentifier(table))"
    }

    /// 文件名净化：剥掉路径分隔符与 `..`，避免产物被写到授权目录之外。
    static func sanitizeFileName(_ raw: String) -> String {
        var name = raw
        for bad in ["/", "\\", ":", "\0"] {
            name = name.replacingOccurrences(of: bad, with: "-")
        }
        name = name.replacingOccurrences(of: "..", with: "-")
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") {
            name.removeFirst()
        }
        return name.isEmpty ? "task" : name
    }

    /// 文件名时间戳（固定格式，不随语言变化）。
    static func timestampText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
