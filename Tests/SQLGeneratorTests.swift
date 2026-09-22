import XCTest
@testable import DoyahCore

/// FR-DATA-01 ~ FR-DATA-03、FR-DDL-01 ~ FR-DDL-02、FR-DIAG-01：SQL 生成器。
final class SQLGeneratorTests: XCTestCase {

    private let pg = PostgresDialect()
    private let gbase = GBaseDialect()

    // MARK: - 表数据浏览

    func testSelectRowsForPostgres() {
        let sql = SQLGenerator.selectRows(table: "users", schema: "public", dialect: pg)
        XCTAssertEqual(sql, "SELECT * FROM \"public\".\"users\" LIMIT 200 OFFSET 0;")
    }

    func testSelectRowsWithoutSchema() {
        let sql = SQLGenerator.selectRows(table: "users", dialect: pg)
        XCTAssertEqual(sql, "SELECT * FROM \"users\" LIMIT 200 OFFSET 0;")
    }

    func testSelectRowsUsesDialectLimitSyntax() {
        // GBase 无 schema 层，schema 参数被忽略，分页语法是 LIMIT offset, count。
        let sql = SQLGenerator.selectRows(
            table: "users",
            schema: "public",
            limit: 50,
            offset: 100,
            dialect: gbase
        )
        XCTAssertEqual(sql, "SELECT * FROM `users` LIMIT 100, 50;")
    }

    func testSelectRowsClampsNegativeNumbers() {
        let sql = SQLGenerator.selectRows(table: "t", limit: -5, offset: -1, dialect: pg)
        XCTAssertEqual(sql, "SELECT * FROM \"t\" LIMIT 0 OFFSET 0;")
    }

    func testCountRows() {
        XCTAssertEqual(
            SQLGenerator.countRows(table: "users", schema: "public", dialect: pg),
            "SELECT count(*) FROM \"public\".\"users\";"
        )
    }

    // MARK: - 模板生成

    func testInsertTemplate() {
        let sql = SQLGenerator.insertTemplate(table: "users", columns: ["id", "name"], dialect: pg)
        XCTAssertEqual(sql, "INSERT INTO \"users\" (\"id\", \"name\") VALUES (?, ?);")
    }

    func testInsertTemplateWithoutColumnsFallsBackToDefaultValues() {
        let sql = SQLGenerator.insertTemplate(table: "users", columns: [], dialect: pg)
        XCTAssertEqual(sql, "INSERT INTO \"users\" DEFAULT VALUES;")
    }

    func testSelectTemplateListsQuotedColumns() {
        let sql = SQLGenerator.selectTemplate(table: "users", columns: ["id", "name"], dialect: gbase)
        XCTAssertEqual(sql, "SELECT `id`, `name` FROM `users`;")
    }

    func testSelectTemplateWithoutColumnsUsesStar() {
        XCTAssertEqual(SQLGenerator.selectTemplate(table: "users", columns: [], dialect: pg),
                       "SELECT * FROM \"users\";")
    }

    // MARK: - DDL

    func testCreateTableRespectsNullability() {
        let columns = [
            ColumnMeta(id: 0, name: "id", typeName: "integer", isNullable: false),
            ColumnMeta(id: 1, name: "name", typeName: "text", isNullable: true)
        ]
        let sql = SQLGenerator.createTableDDL(table: "users", columns: columns, schema: "public", dialect: pg)

        XCTAssertEqual(
            sql,
            "CREATE TABLE \"public\".\"users\" (\n    \"id\" integer NOT NULL,\n    \"name\" text\n);"
        )
    }

    func testCreateTableWithoutColumns() {
        XCTAssertEqual(SQLGenerator.createTableDDL(table: "t", columns: [], dialect: pg),
                       "CREATE TABLE \"t\" ();")
    }

    func testDropTableHasIfExistsByDefault() {
        XCTAssertEqual(SQLGenerator.dropTable(table: "users", dialect: pg),
                       "DROP TABLE IF EXISTS \"users\";")
        XCTAssertEqual(SQLGenerator.dropTable(table: "users", schema: "public", ifExists: false, dialect: pg),
                       "DROP TABLE \"public\".\"users\";")
    }

    func testTruncateTable() {
        XCTAssertEqual(SQLGenerator.truncateTable(table: "users", schema: "public", dialect: pg),
                       "TRUNCATE TABLE \"public\".\"users\";")
    }

    // MARK: - 执行计划语句

    func testExplainWithoutOptions() {
        XCTAssertEqual(SQLGenerator.explain(sql: "SELECT 1;", dialect: pg), "EXPLAIN SELECT 1;")
    }

    func testExplainWithAnalyzeAndJSON() {
        let sql = SQLGenerator.explain(sql: "SELECT * FROM t", analyze: true, formatJSON: true, dialect: pg)
        XCTAssertEqual(sql, "EXPLAIN (ANALYZE, FORMAT JSON) SELECT * FROM t;")
    }

    func testExplainWithBuffers() {
        let sql = SQLGenerator.explain(sql: "SELECT 1", analyze: true, buffers: true, dialect: pg)
        XCTAssertEqual(sql, "EXPLAIN (ANALYZE, BUFFERS) SELECT 1;")
    }

    func testExplainStripsTrailingSemicolonsAndWhitespace() {
        let sql = SQLGenerator.explain(sql: "  SELECT 1 ;;  ", analyze: true, dialect: pg)
        XCTAssertEqual(sql, "EXPLAIN (ANALYZE) SELECT 1;")
    }

    func testExplainFallsBackForDialectsWithoutJSONSupport() {
        // GBase 不支持 FORMAT JSON / BUFFERS，退化为普通 EXPLAIN。
        let sql = SQLGenerator.explain(sql: "SELECT 1", analyze: true, buffers: true, formatJSON: true, dialect: gbase)
        XCTAssertEqual(sql, "EXPLAIN SELECT 1;")
    }

    // MARK: - 库级管理（FR-SESS-05）

    func testDropDatabaseHasIfExistsByDefault() {
        XCTAssertEqual(SQLGenerator.dropDatabase(name: "mydb", dialect: pg),
                       "DROP DATABASE IF EXISTS \"mydb\";")
        XCTAssertEqual(SQLGenerator.dropDatabase(name: "mydb", ifExists: false, dialect: pg),
                       "DROP DATABASE \"mydb\";")
    }

    func testDropDatabaseQuotesPerDialect() {
        // GBase（MySQL 系）用反引号，且同样支持 DROP DATABASE。
        XCTAssertEqual(SQLGenerator.dropDatabase(name: "mydb", dialect: gbase),
                       "DROP DATABASE IF EXISTS `mydb`;")
    }

    func testDropDatabaseRejectsInvalidName() {
        XCTAssertNil(SQLGenerator.dropDatabase(name: "1bad", dialect: pg))
        XCTAssertNil(SQLGenerator.dropDatabase(name: "my-db", dialect: pg))
        XCTAssertNil(SQLGenerator.dropDatabase(name: "   ", dialect: pg))
    }

    func testAlterDatabaseOwner() {
        let sql = SQLGenerator.alterDatabase(
            name: "mydb",
            alterations: SQLGenerator.DatabaseAlterations(owner: "alice"),
            dialect: pg
        )
        XCTAssertEqual(sql, "ALTER DATABASE \"mydb\" OWNER TO \"alice\";")
    }

    func testAlterDatabaseConnectionOptions() {
        let sql = SQLGenerator.alterDatabase(
            name: "mydb",
            alterations: SQLGenerator.DatabaseAlterations(connectionLimit: 10, allowConnections: false),
            dialect: pg
        )
        XCTAssertEqual(sql, "ALTER DATABASE \"mydb\" WITH CONNECTION LIMIT 10 ALLOW_CONNECTIONS false;")
    }

    func testAlterDatabaseUnlimitedConnectionsAreAllowed() {
        let sql = SQLGenerator.alterDatabase(
            name: "mydb",
            alterations: SQLGenerator.DatabaseAlterations(connectionLimit: -1),
            dialect: pg
        )
        XCTAssertEqual(sql, "ALTER DATABASE \"mydb\" WITH CONNECTION LIMIT -1;")
    }

    func testAlterDatabaseSettingQuotesStringsAndLeavesNumbersBare() {
        let text = SQLGenerator.alterDatabase(
            name: "mydb",
            alterations: SQLGenerator.DatabaseAlterations(parameterName: "search_path", parameterValue: "app, public"),
            dialect: pg
        )
        XCTAssertEqual(text, "ALTER DATABASE \"mydb\" SET search_path TO 'app, public';")

        let number = SQLGenerator.alterDatabase(
            name: "mydb",
            alterations: SQLGenerator.DatabaseAlterations(parameterName: "statement_timeout", parameterValue: "5000"),
            dialect: pg
        )
        XCTAssertEqual(number, "ALTER DATABASE \"mydb\" SET statement_timeout TO 5000;")
    }

    func testAlterDatabaseEscapesSingleQuotesInSettingValue() {
        let sql = SQLGenerator.alterDatabase(
            name: "mydb",
            alterations: SQLGenerator.DatabaseAlterations(parameterName: "search_path", parameterValue: "o'brien"),
            dialect: pg
        )
        XCTAssertEqual(sql, "ALTER DATABASE \"mydb\" SET search_path TO 'o''brien';")
    }

    func testAlterDatabaseCombinesOwnerAndOptionsIntoMultipleStatements() {
        let sql = SQLGenerator.alterDatabase(
            name: "mydb",
            alterations: SQLGenerator.DatabaseAlterations(owner: "alice", connectionLimit: 5),
            dialect: pg
        )
        // 属主与选项是两种语句形，必须拆成两条（StatementSplitter 会逐条执行）。
        XCTAssertEqual(sql, "ALTER DATABASE \"mydb\" OWNER TO \"alice\";\nALTER DATABASE \"mydb\" WITH CONNECTION LIMIT 5;")
    }

    func testAlterDatabaseRejectsInvalidInputs() {
        // 无改动
        XCTAssertNil(SQLGenerator.alterDatabase(name: "mydb", alterations: SQLGenerator.DatabaseAlterations(), dialect: pg))
        // 非法库名
        XCTAssertNil(SQLGenerator.alterDatabase(name: "1bad", alterations: SQLGenerator.DatabaseAlterations(owner: "alice"), dialect: pg))
        // 非法属主
        XCTAssertNil(SQLGenerator.alterDatabase(name: "mydb", alterations: SQLGenerator.DatabaseAlterations(owner: "a b"), dialect: pg))
        // 连接数越界
        XCTAssertNil(SQLGenerator.alterDatabase(name: "mydb", alterations: SQLGenerator.DatabaseAlterations(connectionLimit: -2), dialect: pg))
        // 参数名与值只给一个
        XCTAssertNil(SQLGenerator.alterDatabase(name: "mydb", alterations: SQLGenerator.DatabaseAlterations(parameterName: "search_path"), dialect: pg))
        XCTAssertNil(SQLGenerator.alterDatabase(name: "mydb", alterations: SQLGenerator.DatabaseAlterations(parameterValue: "app"), dialect: pg))
        // 非法参数名（含引号，防注入）
        XCTAssertNil(SQLGenerator.alterDatabase(name: "mydb", alterations: SQLGenerator.DatabaseAlterations(parameterName: "a'=1--", parameterValue: "x"), dialect: pg))
    }

    func testAlterDatabaseRejectedForNonPostgresDialect() {
        // GBase 的 ALTER DATABASE 选项集与 PostgreSQL 不同，本期不生成（FR-SESS-05 已注明）。
        XCTAssertNil(SQLGenerator.alterDatabase(
            name: "mydb",
            alterations: SQLGenerator.DatabaseAlterations(owner: "alice"),
            dialect: gbase
        ))
    }

    func testDatabaseAlterationsIsEmpty() {
        XCTAssertTrue(SQLGenerator.DatabaseAlterations().isEmpty)
        XCTAssertFalse(SQLGenerator.DatabaseAlterations(connectionLimit: 0).isEmpty)
    }

    func testSettingLiteralKeepsBooleansBareAndQuotesText() {
        XCTAssertEqual(SQLGenerator.settingLiteral("true"), "true")
        XCTAssertEqual(SQLGenerator.settingLiteral("OFF"), "off")
        XCTAssertEqual(SQLGenerator.settingLiteral("1.5"), "1.5")
        XCTAssertEqual(SQLGenerator.settingLiteral("app, public"), "'app, public'")
    }

    // MARK: - 权限管理（FR-SESS-04）

    func testGrantOnTable() {
        let sql = SQLGenerator.grant(
            SQLGenerator.PrivilegeChange(
                privileges: ["select", "insert"],
                object: .table(schema: "public", name: "users"),
                grantee: "alice"
            ),
            dialect: pg
        )
        XCTAssertEqual(sql, "GRANT SELECT, INSERT ON TABLE \"public\".\"users\" TO \"alice\";")
    }

    func testGrantAllOnDatabaseToPublic() {
        let sql = SQLGenerator.grant(
            SQLGenerator.PrivilegeChange(privileges: ["ALL"], object: .database("mydb"), grantee: "PUBLIC"),
            dialect: pg
        )
        // PUBLIC 是关键字，不能加引号。
        XCTAssertEqual(sql, "GRANT ALL ON DATABASE \"mydb\" TO PUBLIC;")
    }

    func testGrantWithGrantOption() {
        let sql = SQLGenerator.grant(
            SQLGenerator.PrivilegeChange(
                privileges: ["USAGE"],
                object: .schema("app"),
                grantee: "alice",
                withGrantOption: true
            ),
            dialect: pg
        )
        XCTAssertEqual(sql, "GRANT USAGE ON SCHEMA \"app\" TO \"alice\" WITH GRANT OPTION;")
    }

    func testGrantOnAllTablesInSchema() {
        let sql = SQLGenerator.grant(
            SQLGenerator.PrivilegeChange(privileges: ["SELECT"], object: .allTablesInSchema("app"), grantee: "readers"),
            dialect: pg
        )
        XCTAssertEqual(sql, "GRANT SELECT ON ALL TABLES IN SCHEMA \"app\" TO \"readers\";")
    }

    func testGrantOnSequence() {
        let sql = SQLGenerator.grant(
            SQLGenerator.PrivilegeChange(privileges: ["USAGE"], object: .sequence(schema: "app", name: "orders_id_seq"), grantee: "alice"),
            dialect: pg
        )
        XCTAssertEqual(sql, "GRANT USAGE ON SEQUENCE \"app\".\"orders_id_seq\" TO \"alice\";")
    }

    func testRevokeBasic() {
        let sql = SQLGenerator.revoke(
            SQLGenerator.PrivilegeChange(privileges: ["DELETE"], object: .table(schema: "public", name: "users"), grantee: "alice"),
            dialect: pg
        )
        XCTAssertEqual(sql, "REVOKE DELETE ON TABLE \"public\".\"users\" FROM \"alice\";")
    }

    func testRevokeGrantOptionOnly() {
        let sql = SQLGenerator.revoke(
            SQLGenerator.PrivilegeChange(
                privileges: ["SELECT"],
                object: .table(schema: nil, name: "users"),
                grantee: "alice",
                withGrantOption: true
            ),
            dialect: pg
        )
        XCTAssertEqual(sql, "REVOKE GRANT OPTION FOR SELECT ON TABLE \"users\" FROM \"alice\";")
    }

    func testGrantRejectsUnknownPrivilege() {
        // 白名单外的一律拒绝，避免把任意文本拼进 SQL。
        let sql = SQLGenerator.grant(
            SQLGenerator.PrivilegeChange(privileges: ["SELECT; DROP TABLE x--"], object: .database("mydb"), grantee: "alice"),
            dialect: pg
        )
        XCTAssertNil(sql)
    }

    func testGrantRejectsAllMixedWithOthers() {
        XCTAssertNil(SQLGenerator.grant(
            SQLGenerator.PrivilegeChange(privileges: ["ALL", "SELECT"], object: .database("mydb"), grantee: "alice"),
            dialect: pg
        ))
    }

    func testGrantRejectsEmptyPrivileges() {
        XCTAssertNil(SQLGenerator.grant(
            SQLGenerator.PrivilegeChange(privileges: [], object: .database("mydb"), grantee: "alice"),
            dialect: pg
        ))
        XCTAssertNil(SQLGenerator.grant(
            SQLGenerator.PrivilegeChange(privileges: ["", "  "], object: .database("mydb"), grantee: "alice"),
            dialect: pg
        ))
    }

    func testGrantRejectsInvalidGranteeAndObject() {
        // 非法角色名
        XCTAssertNil(SQLGenerator.grant(
            SQLGenerator.PrivilegeChange(privileges: ["SELECT"], object: .database("mydb"), grantee: "a b"),
            dialect: pg
        ))
        // 非法对象名
        XCTAssertNil(SQLGenerator.grant(
            SQLGenerator.PrivilegeChange(privileges: ["SELECT"], object: .table(schema: nil, name: "1bad"), grantee: "alice"),
            dialect: pg
        ))
        XCTAssertNil(SQLGenerator.grant(
            SQLGenerator.PrivilegeChange(privileges: ["SELECT"], object: .allTablesInSchema("bad-schema"), grantee: "alice"),
            dialect: pg
        ))
    }

    func testPostgresObjectPrivilegeQueryEscapesRoleName() {
        let sql = pg.objectPrivilegeQuery(role: "o'brien")
        XCTAssertNotNil(sql)
        XCTAssertTrue(sql?.contains("rolname = 'o''brien'") == true)
        XCTAssertTrue(sql?.contains("aclexplode") == true)
        XCTAssertTrue(sql?.contains("pg_blocking_pids") == false)
    }

    func testGBaseHasNoObjectPrivilegeQuery() {
        // GBase（MySQL 系）的权限模型与 PostgreSQL 不同，本期不接入（FR-SESS-04 已注明）。
        XCTAssertNil(gbase.objectPrivilegeQuery(role: "root"))
    }

    // MARK: - 索引与约束（FR-DDL-03 扩写）

    func testCreateIndexBasic() {
        let sql = SQLGenerator.createIndex(
            SQLGenerator.IndexDefinition(name: "users_email_idx", table: "users", schema: "public", columns: ["email"]),
            dialect: pg
        )
        XCTAssertEqual(sql, "CREATE INDEX \"users_email_idx\" ON \"public\".\"users\" (\"email\");")
    }

    func testCreateIndexUniqueWithMethodAndMultipleColumns() {
        let sql = SQLGenerator.createIndex(
            SQLGenerator.IndexDefinition(
                name: "orders_lookup_idx",
                table: "orders",
                columns: ["user_id", "created_at"],
                isUnique: true,
                method: "gin"
            ),
            dialect: pg
        )
        XCTAssertEqual(sql, "CREATE UNIQUE INDEX \"orders_lookup_idx\" ON \"orders\" USING gin (\"user_id\", \"created_at\");")
    }

    func testCreateIndexConcurrentlyWithPartialWhere() {
        let sql = SQLGenerator.createIndex(
            SQLGenerator.IndexDefinition(
                name: "active_users_idx",
                table: "users",
                columns: ["id"],
                whereClause: "deleted_at IS NULL",
                concurrently: true
            ),
            dialect: pg
        )
        XCTAssertEqual(sql, "CREATE INDEX CONCURRENTLY \"active_users_idx\" ON \"users\" (\"id\") WHERE deleted_at IS NULL;")
    }

    func testCreateIndexRejectsUnknownMethod() {
        XCTAssertNil(SQLGenerator.createIndex(
            SQLGenerator.IndexDefinition(name: "i", table: "t", columns: ["c"], method: "magic"),
            dialect: pg
        ))
    }

    func testCreateIndexRejectsInvalidInputs() {
        // 空列
        XCTAssertNil(SQLGenerator.createIndex(
            SQLGenerator.IndexDefinition(name: "i", table: "t", columns: []), dialect: pg))
        // 非法索引名
        XCTAssertNil(SQLGenerator.createIndex(
            SQLGenerator.IndexDefinition(name: "1bad", table: "t", columns: ["c"]), dialect: pg))
        // 非法列名
        XCTAssertNil(SQLGenerator.createIndex(
            SQLGenerator.IndexDefinition(name: "i", table: "t", columns: ["c; DROP TABLE x"]), dialect: pg))
    }

    func testCreateIndexRejectsStatementStackingInWhereClause() {
        XCTAssertNil(SQLGenerator.createIndex(
            SQLGenerator.IndexDefinition(name: "i", table: "t", columns: ["c"], whereClause: "true; DROP TABLE users"),
            dialect: pg
        ))
    }

    func testDropIndexDefaults() {
        XCTAssertEqual(
            SQLGenerator.dropIndex(name: "users_email_idx", schema: "public", dialect: pg),
            "DROP INDEX IF EXISTS \"public\".\"users_email_idx\";"
        )
        XCTAssertEqual(
            SQLGenerator.dropIndex(name: "i", ifExists: false, concurrently: true, dialect: pg),
            "DROP INDEX CONCURRENTLY \"i\";"
        )
        XCTAssertNil(SQLGenerator.dropIndex(name: "1bad", dialect: pg))
    }

    func testAddForeignKeyBasic() {
        let sql = SQLGenerator.addForeignKey(
            SQLGenerator.ForeignKeyDefinition(
                name: "orders_user_fk",
                table: "orders",
                schema: "public",
                columns: ["user_id"],
                referencedTable: "users",
                referencedSchema: "public",
                referencedColumns: ["id"]
            ),
            dialect: pg
        )
        XCTAssertEqual(sql, "ALTER TABLE \"public\".\"orders\" ADD CONSTRAINT \"orders_user_fk\" "
                       + "FOREIGN KEY (\"user_id\") REFERENCES \"public\".\"users\" (\"id\");")
    }

    func testAddForeignKeyWithReferentialActions() {
        let sql = SQLGenerator.addForeignKey(
            SQLGenerator.ForeignKeyDefinition(
                table: "orders",
                columns: ["user_id"],
                referencedTable: "users",
                referencedColumns: ["id"],
                onDelete: .cascade,
                onUpdate: .setNull
            ),
            dialect: pg
        )
        // 未指定约束名 → 交给数据库自动命名。
        XCTAssertEqual(sql, "ALTER TABLE \"orders\" ADD FOREIGN KEY (\"user_id\") "
                       + "REFERENCES \"users\" (\"id\") ON DELETE CASCADE ON UPDATE SET NULL;")
    }

    func testAddForeignKeyRejectsColumnCountMismatch() {
        XCTAssertNil(SQLGenerator.addForeignKey(
            SQLGenerator.ForeignKeyDefinition(
                table: "orders",
                columns: ["user_id", "tenant_id"],
                referencedTable: "users",
                referencedColumns: ["id"]
            ),
            dialect: pg
        ))
    }

    func testAddForeignKeyRejectsInvalidConstraintName() {
        XCTAssertNil(SQLGenerator.addForeignKey(
            SQLGenerator.ForeignKeyDefinition(
                name: "bad name",
                table: "orders",
                columns: ["user_id"],
                referencedTable: "users",
                referencedColumns: ["id"]
            ),
            dialect: pg
        ))
    }

    func testDropConstraint() {
        XCTAssertEqual(
            SQLGenerator.dropConstraint(name: "orders_user_fk", table: "orders", schema: "public", cascade: true, dialect: pg),
            "ALTER TABLE \"public\".\"orders\" DROP CONSTRAINT IF EXISTS \"orders_user_fk\" CASCADE;"
        )
        XCTAssertNil(SQLGenerator.dropConstraint(name: "fk", table: "1bad", dialect: pg))
    }
}
