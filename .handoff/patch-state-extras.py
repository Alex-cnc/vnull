# -*- coding: utf-8 -*-
'''FR-DDL-03 扩写：AppState 读索引/约束 + 变更集执行；对象树调用处；文案。跑完即删。'''

import pathlib

root = pathlib.Path('/Users/alex/.dsh/projects/DoyahStudio')

# ── 1) AppState
p = root / 'App/AppState.swift'
t = p.read_text(encoding='utf-8')

old = '''    func alterTable(
        _ object: DatabaseObject,
        from original: [TableColumnDefinition],
        to edited: [TableColumnDefinition]
    ) async -> Bool {
        guard let configuration = selectedConnection else {
            errorMessage = L(.stateSelectConnectionFirst)
            return false
        }

        let changes = TableDesign.columnChanges(original: original, edited: edited)
        let statements = SQLGenerator.alterTableStatements(
            table: object.name,
            schema: object.schema,
            changes: changes,
            dialect: SQLDialectFactory.make(for: configuration.dbType)
        )
        guard !statements.isEmpty else { return true }'''
new = '''    /// 读取一张表既有的索引与约束（FR-DDL-03 的「删」要先看得见）。
    ///
    /// 方言不支持时**返回空数组 + 明说**：界面据此显示"暂不支持读取"，
    /// 而不是让人以为"这张表没有索引"。
    func tableExtras(of object: DatabaseObject) async throws -> (indexes: [TableIndexInfo], constraints: [TableConstraintInfo]) {
        guard let configuration = selectedConnection else {
            throw AppError.notConnected
        }
        let dialect = SQLDialectFactory.make(for: configuration.dbType)
        let database = object.database ?? currentDatabaseName(for: configuration)
        let service = try await ensureService(for: configuration, database: database)

        var indexes: [TableIndexInfo] = []
        if let query = dialect.tableIndexesQuery(table: object.name, schema: object.schema) {
            indexes = TableDesignChangeSet.indexes(from: try await runSingleQuery(query, on: service))
        }

        var constraints: [TableConstraintInfo] = []
        if let query = dialect.tableConstraintsQuery(table: object.name, schema: object.schema) {
            constraints = TableDesignChangeSet.constraints(from: try await runSingleQuery(query, on: service))
        }

        return (indexes, constraints)
    }

    /// 应用一份表设计变更（列 + 索引 + 外键 + 约束）。
    ///
    /// 语句顺序由 Core 决定（删约束 → 删索引 → 列变更 → 新索引 → 新外键 → 新约束）；
    /// 中间失败时**指明第几条**并让对象树刷新（前面的语句可能已生效），绝不谎报成功。
    func alterTable(_ object: DatabaseObject, changeSet: TableDesignChangeSet) async -> Bool {
        guard let configuration = selectedConnection else {
            errorMessage = L(.stateSelectConnectionFirst)
            return false
        }

        let dialect = SQLDialectFactory.make(for: configuration.dbType)
        let statements = TableDesignChangeSet.statements(
            for: changeSet,
            table: object.name,
            schema: object.schema,
            dialect: dialect
        )
        // 非空变更集却生成不出语句 = 某条输入非法（Core 会整批返回空），必须说出来。
        guard !statements.isEmpty else {
            if changeSet.hasChanges {
                errorMessage = L(.tableDesignInvalid)
                return false
            }
            return true
        }'''
assert t.count(old) == 1
t = t.replace(old, new, 1)

old = '''        guard !statements.isEmpty else { return true }

        do {
            let database = object.database ?? currentDatabaseName(for: configuration)
            let service = try await ensureService(for: configuration, database: database)
            for (index, statement) in statements.enumerated() {
                do {
                    _ = try await runSingleQuery(statement, on: service)
                } catch {
                    errorMessage = L(.tableDesignAlterFailed, index + 1, ErrorPresenter.message(for: error))
                    metadataRevision += 1 // 前面几条可能已经生效，让对象树刷新
                    return false
                }
            }

            statusMessage = L(.tableDesignAltered, object.name, "\\(changes.count)")'''
new = '''        do {
            let database = object.database ?? currentDatabaseName(for: configuration)
            let service = try await ensureService(for: configuration, database: database)
            for (index, statement) in statements.enumerated() {
                do {
                    _ = try await runSingleQuery(statement, on: service)
                } catch {
                    errorMessage = L(.tableDesignAlterFailed, index + 1, ErrorPresenter.message(for: error))
                    metadataRevision += 1 // 前面几条可能已经生效，让对象树刷新
                    return false
                }
            }

            statusMessage = L(.tableDesignAltered, object.name, "\\(statements.count)")'''
assert t.count(old) == 1
t = t.replace(old, new, 1)

# createTable：支持建表后补索引 / 约束
old = '''    func createTable(
        named rawName: String,
        schema: String?,
        columns: [TableColumnDefinition]
    ) async -> Bool {'''
new = '''    func createTable(
        named rawName: String,
        schema: String?,
        columns: [TableColumnDefinition],
        extras: TableDesignChangeSet? = nil
    ) async -> Bool {'''
assert t.count(old) == 1
t = t.replace(old, new, 1)
p.write_text(t, encoding='utf-8')
print('✅ AppState：tableExtras / alterTable(changeSet:) / createTable(extras:)')
