import XCTest
@testable import DoyahCore

/// 服务器级对象管理（FR-SESS-03）：浏览查询构造 / 结果解析 / 增删改语句生成 / 风险标注。
///
/// 这一项最容易做错的三处，也是本文件重点钉住的：
/// 1. **GBase 的表空间必须"不支持"且一条 SQL 都不发** —— 发出去必报错，
///    那会把「这个方言没有这个概念」误报成「你的库坏了」；
/// 2. **写操作必须能预览、能拒绝** —— 空名字 / `a; DROP …` / 带引号的名字要被挡下，
///    而且理由要能读懂（不是一句"非法输入"）；
/// 3. **解析必须容忍 NULL / 缺列** —— 不同版本、不同方言的列名与可空性都不一样。
final class ServerObjectsTests: XCTestCase {

    private let pg = PostgresServerObjectDialect()
    private let gbase = GBaseServerObjectDialect()

    private func result(_ columns: [String], _ rows: [[String?]]) -> QueryResult {
        QueryResult(
            columns: columns.enumerated().map { ColumnMeta(id: $0.offset, name: $0.element) },
            rows: rows
        )
    }

    // MARK: 浏览查询：PostgreSQL

    func testPostgresRoleBrowseQueryUsesPgRoles() {
        let plan = ServerObjects.browsePlan(.role, dialect: pg)
        let sql = plan.sql ?? ""
        XCTAssertTrue(sql.contains("pg_catalog.pg_roles"), "角色查询应走 pg_roles：\(sql)")
        XCTAssertTrue(sql.contains("rolcanlogin"), "应取出能否登录的标志")
        XCTAssertTrue(sql.contains("rolsuper"), "应取出是否超级用户")
        XCTAssertTrue(sql.contains("ORDER BY r.rolname"), "顺序必须确定")
        XCTAssertNil(plan.unsupportedReason)
        XCTAssertNil(plan.note, "PG 是原生支持，不是近似物")
    }

    func testPostgresTablespaceBrowseQueryUsesPgTablespace() {
        let plan = ServerObjects.browsePlan(.tablespace, dialect: pg)
        let sql = plan.sql ?? ""
        XCTAssertTrue(sql.contains("pg_catalog.pg_tablespace"), "表空间查询应走 pg_tablespace：\(sql)")
        XCTAssertTrue(sql.contains("pg_tablespace_location"), "应给出磁盘目录")
        XCTAssertTrue(sql.contains("pg_tablespace_size"), "应给出占用大小")
        XCTAssertNil(plan.unsupportedReason)
    }

    func testPostgresExtensionBrowseQueryUsesPgExtension() {
        let plan = ServerObjects.browsePlan(.extension, dialect: pg)
        let sql = plan.sql ?? ""
        XCTAssertTrue(sql.contains("pg_catalog.pg_extension"), "扩展查询应走 pg_extension：\(sql)")
        XCTAssertTrue(sql.contains("extversion"), "应给出扩展版本")
        XCTAssertTrue(sql.contains("pg_namespace"), "应给出扩展所在 schema")
        XCTAssertNil(plan.unsupportedReason)
    }

    /// 浏览上限要被夹到 ≥1：`LIMIT 0` 会让人以为"这台服务器上一个对象都没有"。
    func testBrowseLimitIsBoundedBelowOne() {
        let sql = ServerObjects.browseStatement(.role, dialect: pg, limit: 0) ?? ""
        XCTAssertTrue(sql.contains("LIMIT 1"), "上限应夹到 1，而不是原样拼 0：\(sql)")
        let big = ServerObjects.browseStatement(.role, dialect: pg, limit: 25) ?? ""
        XCTAssertTrue(big.contains("LIMIT 25"))
    }

    func testPostgresBrowseStatementMatchesPlan() {
        for kind in ServerObjectKind.allCases {
            XCTAssertEqual(
                ServerObjects.browseStatement(kind, dialect: pg),
                ServerObjects.browsePlan(kind, dialect: pg).sql,
                "两个入口必须给同一条 SQL：\(kind.rawValue)"
            )
        }
    }

    // MARK: 浏览查询：GBase 8a

    /// **本项最关键的一条**：GBase 没有表空间 —— 必须是"不支持"且**不生成任何 SQL**。
    func testGBaseTablespaceIsUnsupportedWithoutAnySQL() {
        let plan = ServerObjects.browsePlan(.tablespace, dialect: gbase)
        XCTAssertNil(plan.sql, "不支持就不能生成 SQL（发了必报错的语句是误导）")
        XCTAssertFalse(plan.isSupported)
        guard let reason = plan.unsupportedReason else {
            return XCTFail("必须给出可读的中文说明，而不是静默为空")
        }
        XCTAssertTrue(reason.contains("表空间"), "说明要点名「表空间」：\(reason)")
        XCTAssertTrue(reason.contains("GBase 8a"), "说明要点名方言：\(reason)")
        XCTAssertGreaterThan(reason.count, 10, "说明要是一句人话，不是一个词")
    }

    /// GBase 的扩展确实没有对应物，但 `information_schema.PLUGINS` 是有用的**近似物**：
    /// 查询照发，但必须带上「这不是 PostgreSQL 扩展」的说明。
    func testGBaseExtensionBrowseIsApproximationWithNote() {
        let plan = ServerObjects.browsePlan(.extension, dialect: gbase)
        let sql = plan.sql ?? ""
        XCTAssertTrue(sql.contains("information_schema.PLUGINS"), "近似查询应走 PLUGINS：\(sql)")
        XCTAssertNil(plan.unsupportedReason)
        guard let note = plan.note else {
            return XCTFail("近似物必须带说明，否则等于把插件说成了扩展")
        }
        XCTAssertTrue(note.contains("插件"), "说明要点明白列出来的是插件：\(note)")
        XCTAssertTrue(note.contains("GBase 8a"))
    }

    func testGBaseRoleBrowseUsesMySQLUserApproximation() {
        let plan = ServerObjects.browsePlan(.role, dialect: gbase)
        let sql = plan.sql ?? ""
        XCTAssertTrue(sql.contains("mysql.user"), "账号清单应走 mysql.user：\(sql)")
        XCTAssertTrue(sql.contains("Host"), "应带上来源主机（账号是 User@Host 二元组）")
        XCTAssertNotNil(plan.note, "GBase 没有独立角色对象，必须说明这是账号近似")
        XCTAssertTrue(plan.note?.contains("账号") == true)
    }

    func testGBaseUnsupportedReasonsAreReadableForEveryKind() {
        // 角色：支持（近似）；表空间 / 扩展：不支持且都有中文说明。
        XCTAssertNil(gbase.unsupportedReason(for: .role), "角色在 GBase 上走账号近似，不是不支持")
        for kind in [ServerObjectKind.tablespace, .extension] {
            guard let reason = gbase.unsupportedReason(for: kind) else {
                return XCTFail("\(kind.rawValue) 必须有不支持说明")
            }
            XCTAssertTrue(reason.hasPrefix("GBase 8a"), "说明应点名方言：\(reason)")
        }
        XCTAssertNil(pg.unsupportedReason(for: .tablespace), "PG 三类都支持")
        XCTAssertNil(pg.unsupportedReason(for: .extension))
    }

    // MARK: 解析（纯函数）

    func testRoleParsingHandlesNullAndMissingColumns() {
        let full = result(
            ["name", "can_login", "is_superuser", "comment"],
            [["postgres", "t", "t", nil],
             ["app", "f", "f", "只读账号"],
             ["weird", nil, nil, nil],
             [nil, "t", "f", nil]]
        )
        let roles = ServerObjects.objects(from: full, kind: .role)
        XCTAssertEqual(roles.map(\.name), ["app", "postgres", "weird"], "名字为空的行应被丢掉")
        XCTAssertEqual(roles.first { $0.name == "postgres" }?.canLogin, true)
        XCTAssertEqual(roles.first { $0.name == "postgres" }?.isSuperuser, true)
        XCTAssertEqual(roles.first { $0.name == "app" }?.canLogin, false)
        XCTAssertNil(roles.first { $0.name == "weird" }?.canLogin, "NULL 就是「不知道」，不是 false")

        // 只有一列名字：其余属性全缺，也不该崩。
        let sparse = ServerObjects.objects(
            from: result(["rolname"], [["a"], ["b"]]),
            kind: .role
        )
        XCTAssertEqual(sparse.map(\.name), ["a", "b"])
        XCTAssertNil(sparse[0].owner)
        XCTAssertNil(sparse[0].canLogin)
        XCTAssertNil(sparse[0].isSuperuser)
    }

    func testRoleParsingReadsBooleanTextAndComment() {
        let roles = ServerObjects.objects(
            from: result(
                ["name", "can_login", "is_superuser", "comment"],
                [["svc", "1", "0", "服务账号"]]
            ),
            kind: .role
        )
        XCTAssertEqual(roles.count, 1)
        XCTAssertEqual(roles[0].canLogin, true, "GBase 的 1/0 也要认")
        XCTAssertEqual(roles[0].isSuperuser, false)
        XCTAssertEqual(roles[0].comment, "服务账号")
    }

    func testTablespaceParsingReadsOwnerLocationAndSize() {
        let spaces = ServerObjects.objects(
            from: result(
                ["name", "owner", "location", "bytes", "comment"],
                [["fast", "postgres", "/data/fast", "8192", "快盘"],
                 ["pg_default", "postgres", "", nil, nil]]
            ),
            kind: .tablespace
        )
        XCTAssertEqual(spaces.map(\.name), ["fast", "pg_default"])
        XCTAssertEqual(spaces[0].owner, "postgres")
        XCTAssertEqual(spaces[0].location, "/data/fast")
        XCTAssertEqual(spaces[0].sizeBytes, 8192)
        XCTAssertEqual(spaces[0].comment, "快盘")
        XCTAssertNil(spaces[1].location, "空串（pg_default 没有独立目录）应当作没有该属性")
        XCTAssertNil(spaces[1].sizeBytes)
    }

    func testTablespaceParsingIgnoresNonNumericSize() {
        let spaces = ServerObjects.objects(
            from: result(["name", "bytes"], [["x", "abc"], ["y", "0"]]),
            kind: .tablespace
        )
        XCTAssertNil(spaces[0].sizeBytes, "解析不出来的大小是「未知」，不是 0")
        XCTAssertEqual(spaces[1].sizeBytes, 0, "真的是 0 时才给 0")
    }

    func testExtensionParsingReadsVersionSchemaAndStatus() {
        let installed = ServerObjects.objects(
            from: result(
                ["name", "version", "schema", "owner", "comment"],
                [["plpgsql", "1.0", "pg_catalog", nil, nil]]
            ),
            kind: .extension
        )
        XCTAssertEqual(installed[0].name, "plpgsql")
        XCTAssertEqual(installed[0].version, "1.0")
        XCTAssertEqual(installed[0].schema, "pg_catalog")

        // GBase 的 PLUGINS 近似：列名不同（status 而不是 schema），也不该崩。
        let plugins = ServerObjects.objects(
            from: result(["name", "version", "status"], [["InnoDB", "8.0", "ACTIVE"]]),
            kind: .extension
        )
        XCTAssertEqual(plugins[0].version, "8.0")
        XCTAssertEqual(plugins[0].status, "ACTIVE")
        XCTAssertNil(plugins[0].schema)
    }

    func testDictionaryRowParsingToleratesMissingKeys() {
        let rows: [[String: String]] = [["Name": "zeta", "CAN_LOGIN": "1"], ["name": "alpha"]]
        let parsed = ServerObjects.objects(fromRows: rows, kind: .role)
        XCTAssertEqual(parsed.map(\.name), ["alpha", "zeta"], "键不区分大小写，且按名字排序")
        XCTAssertEqual(parsed[1].canLogin, true)
        XCTAssertNil(parsed[1].isSuperuser)

        let optionalRows: [[String: String?]] = [
            ["name": "t1", "bytes": "4096", "location": nil],
            ["bytes": "4096"]
        ]
        let spaces = ServerObjects.objects(fromRows: optionalRows, kind: .tablespace)
        XCTAssertEqual(spaces.count, 1, "没有名字的行丢掉")
        XCTAssertEqual(spaces[0].sizeBytes, 4096)
        XCTAssertNil(spaces[0].location)
    }

    func testParsingIsSortedAndDeterministic() {
        let input = result(
            ["name", "can_login"],
            [["c", "t"], ["a", "t"], ["b", "t"], ["a", "f"]]
        )
        let first = ServerObjects.objects(from: input, kind: .role)
        let second = ServerObjects.objects(from: input, kind: .role)
        XCTAssertEqual(first, second, "同输入必须给出同一个结果（确定性）")
        XCTAssertEqual(first.map(\.name), ["a", "a", "b", "c"], "同名时保持输入顺序（稳定排序）")
        XCTAssertEqual(first.filter { $0.name == "a" }.map(\.canLogin), [true, false])
    }

    // MARK: 清单装配

    func testInventoryRecordsUnsupportedReasonsWithoutQuerying() {
        let inventory = ServerObjects.inventory(
            results: [.role: result(["name"], [["app"]])],
            dialect: gbase
        )
        XCTAssertEqual(inventory.roles.map(\.name), ["app"])
        XCTAssertTrue(inventory.tablespaces.isEmpty)
        XCTAssertTrue(inventory.isUnsupported(.tablespace))
        XCTAssertTrue(inventory.isUnsupported(.extension) == false, "扩展是近似物，不是不支持")
        XCTAssertFalse(inventory.isUnsupported(.role))
        XCTAssertNotNil(inventory.unsupportedReason(for: .tablespace))
        XCTAssertNil(inventory.unsupportedReason(for: .role))
        XCTAssertFalse(inventory.isEmpty, "有角色就不算空")
    }

    func testInventoryAssemblesAllThreeKindsForPostgres() {
        let inventory = ServerObjects.inventory(
            results: [
                .role: result(["name"], [["app"]]),
                .tablespace: result(["name"], [["fast"]]),
                .extension: result(["name", "version"], [["plpgsql", "1.0"]])
            ],
            dialect: pg
        )
        XCTAssertEqual(inventory.totalCount, 3)
        XCTAssertEqual(inventory.count(for: .tablespace), 1)
        XCTAssertEqual(inventory.objects(for: .extension).first?.version, "1.0")
        XCTAssertTrue(inventory.unsupportedReasons.isEmpty, "PG 三类都支持")
    }

    // MARK: 写操作：角色（PostgreSQL）

    func testCreateRoleQuotesIdentifierAndEscapesPassword() {
        let plan = ServerObjects.createRole(
            RoleSpec(name: "probe_role", password: "se'cret", canLogin: true),
            dialect: pg
        )
        XCTAssertEqual(plan.sql, "CREATE ROLE \"probe_role\" WITH LOGIN PASSWORD 'se''cret'",
                       "标识符要加引号，口令里的单引号要翻倍")
        XCTAssertEqual(plan.risk, .elevated)
        XCTAssertEqual(plan.command?.kind, .role)
        XCTAssertEqual(plan.command?.preview, plan.sql, "预览就是将要执行的那一句")
        XCTAssertTrue(plan.command?.requiresConfirmation == true)
        XCTAssertFalse(plan.command?.warnings.isEmpty ?? true, "写操作要带代价说明")
    }

    func testCreateRoleEncodesNoLoginAndSuperuser() {
        let plan = ServerObjects.createRole(
            RoleSpec(name: "bot", password: nil, canLogin: false, isSuperuser: true),
            dialect: pg
        )
        XCTAssertEqual(plan.sql, "CREATE ROLE \"bot\" WITH NOLOGIN SUPERUSER")
    }

    func testCreateRoleRejectsEmptyName() {
        let plan = ServerObjects.createRole(RoleSpec(name: "   "), dialect: pg)
        XCTAssertNil(plan.sql, "被拒绝时不能有语句")
        guard let reason = plan.rejectionReason else { return XCTFail("必须给出拒绝理由") }
        XCTAssertTrue(reason.contains("不能为空"), "理由要能读懂：\(reason)")
    }

    func testCreateRoleRejectsSemicolonInjection() {
        let plan = ServerObjects.createRole(
            RoleSpec(name: "a; DROP ROLE postgres", password: "pw"),
            dialect: pg
        )
        XCTAssertNil(plan.sql, "带分号的名字必须被拒，且不生成任何语句")
        guard let reason = plan.rejectionReason else { return XCTFail("必须给出拒绝理由") }
        XCTAssertTrue(reason.contains("分号"), "理由要点名分号注入：\(reason)")
    }

    func testCreateRoleRejectsQuoteBacktickAndBackslashInjection() {
        for bad in ["a\"b", "a'b", "a`b", "a\\b", "a--b", "a/*b"] {
            let plan = ServerObjects.createRole(RoleSpec(name: bad, password: "pw"), dialect: pg)
            XCTAssertNil(plan.sql, "可疑名字必须被拒：\(bad)")
            XCTAssertNotNil(plan.rejectionReason, "并给出理由：\(bad)")
        }
    }

    func testCreateRoleRejectsWhitespacePaddingAndOverlongName() {
        let padded = ServerObjects.createRole(RoleSpec(name: " probe"), dialect: pg)
        XCTAssertNil(padded.sql)
        XCTAssertTrue(padded.rejectionReason?.contains("空白") == true)

        let long = ServerObjects.createRole(RoleSpec(name: String(repeating: "a", count: 64)), dialect: pg)
        XCTAssertNil(long.sql)
        XCTAssertTrue(long.rejectionReason?.contains("63") == true)
    }

    func testCreateRoleRejectsEmptyPasswordWhenGiven() {
        let plan = ServerObjects.createRole(RoleSpec(name: "svc", password: ""), dialect: pg)
        XCTAssertNil(plan.sql)
        XCTAssertTrue(plan.rejectionReason?.contains("口令") == true)
    }

    func testAlterRoleGeneratesOnlyGivenOptions() {
        let passwordOnly = ServerObjects.alterRole(
            name: "svc", password: "new", canLogin: nil, isSuperuser: nil, dialect: pg
        )
        XCTAssertEqual(passwordOnly.sql, "ALTER ROLE \"svc\" WITH PASSWORD 'new'",
                       "没给的项不能出现在语句里（否则等于把别的属性也改了）")
        XCTAssertEqual(passwordOnly.risk, .elevated)

        let noLogin = ServerObjects.alterRole(
            name: "svc", password: nil, canLogin: false, isSuperuser: false, dialect: pg
        )
        XCTAssertEqual(noLogin.sql, "ALTER ROLE \"svc\" WITH NOLOGIN NOSUPERUSER")
    }

    func testAlterRoleRejectsEmptyOptionSet() {
        let plan = ServerObjects.alterRole(
            name: "svc", password: nil, canLogin: nil, isSuperuser: nil, dialect: pg
        )
        XCTAssertNil(plan.sql)
        XCTAssertTrue(plan.rejectionReason?.contains("没有给出任何要修改的项") == true,
                      "空修改要给可读理由：\(plan.preview)")
    }

    func testRenameRoleStatements() {
        XCTAssertEqual(
            ServerObjects.renameRole(name: "old", newName: "new", dialect: pg).sql,
            "ALTER ROLE \"old\" RENAME TO \"new\""
        )
        XCTAssertEqual(
            ServerObjects.renameRole(name: "old", newName: "new", dialect: gbase).sql,
            "RENAME USER 'old'@'%' TO 'new'@'%'"
        )
        let bad = ServerObjects.renameRole(name: "old", newName: "new; DROP", dialect: pg)
        XCTAssertNil(bad.sql)
        XCTAssertTrue(bad.rejectionReason?.contains("新名字") == true)
    }

    // MARK: 写操作：角色（GBase 8a）

    func testGBaseCreateUserUsesLiteralSyntaxAndEscapesBackslash() {
        let plan = ServerObjects.createRole(
            RoleSpec(name: "probe", password: #"p\q"#),
            dialect: gbase
        )
        XCTAssertEqual(
            plan.sql,
            #"CREATE USER 'probe'@'%' IDENTIFIED BY 'p\\q'"#,
            "MySQL 协议族把账号写成字面量，且反斜杠也要转义"
        )
        XCTAssertEqual(plan.risk, .elevated)

        let quoted = ServerObjects.createRole(RoleSpec(name: "probe", password: "pa'ss"), dialect: gbase)
        XCTAssertEqual(quoted.sql, "CREATE USER 'probe'@'%' IDENTIFIED BY 'pa''ss'")
    }

    func testGBaseAlterDropAndRenameUseUserSyntax() {
        XCTAssertEqual(
            ServerObjects.alterRole(name: "probe", password: "new", canLogin: nil, isSuperuser: nil, dialect: gbase).sql,
            "ALTER USER 'probe'@'%' IDENTIFIED BY 'new'"
        )
        XCTAssertEqual(ServerObjects.dropRole(name: "probe", dialect: gbase).sql, "DROP USER 'probe'@'%'")
    }

    func testGBaseRejectsAccountFlagsItDoesNotHave() {
        let noLogin = ServerObjects.createRole(
            RoleSpec(name: "probe", password: "pw", canLogin: false),
            dialect: gbase
        )
        XCTAssertNil(noLogin.sql)
        XCTAssertTrue(noLogin.rejectionReason?.contains("NOLOGIN") == true,
                      "要说明该方言没有 NOLOGIN：\(noLogin.preview)")

        let superuser = ServerObjects.createRole(
            RoleSpec(name: "probe", password: "pw", isSuperuser: true),
            dialect: gbase
        )
        XCTAssertNil(superuser.sql)
        XCTAssertTrue(superuser.rejectionReason?.contains("GRANT") == true,
                      "要说明超级权限得走 GRANT：\(superuser.preview)")

        let noPassword = ServerObjects.createRole(RoleSpec(name: "probe"), dialect: gbase)
        XCTAssertNil(noPassword.sql)
        XCTAssertTrue(noPassword.rejectionReason?.contains("口令") == true)
    }

    // MARK: 写操作：表空间

    func testCreateTablespaceStatementQuotesNameAndPath() {
        let plan = ServerObjects.createTablespace(
            TablespaceSpec(name: "fast_space", location: "/data/pg_tbs"),
            dialect: pg
        )
        XCTAssertEqual(plan.sql, "CREATE TABLESPACE \"fast_space\" LOCATION '/data/pg_tbs'")
        XCTAssertEqual(plan.risk, .elevated)
        XCTAssertEqual(plan.command?.kind, .tablespace)
    }

    func testCreateTablespaceRejectsRelativeOrInjectedLocation() {
        let relative = ServerObjects.createTablespace(
            TablespaceSpec(name: "fast", location: "data/pg_tbs"),
            dialect: pg
        )
        XCTAssertNil(relative.sql)
        XCTAssertTrue(relative.rejectionReason?.contains("绝对路径") == true)

        let injected = ServerObjects.createTablespace(
            TablespaceSpec(name: "fast", location: "/data/x; DROP TABLESPACE y"),
            dialect: pg
        )
        XCTAssertNil(injected.sql)
        XCTAssertTrue(injected.rejectionReason?.contains("分号") == true)

        let quoted = ServerObjects.createTablespace(
            TablespaceSpec(name: "fast", location: "/data/it's"),
            dialect: pg
        )
        XCTAssertNil(quoted.sql)
        XCTAssertTrue(quoted.rejectionReason?.contains("引号") == true)

        let empty = ServerObjects.createTablespace(TablespaceSpec(name: "fast", location: "  "), dialect: pg)
        XCTAssertNil(empty.sql)
        XCTAssertTrue(empty.rejectionReason?.contains("不能为空") == true)
    }

    func testDropTablespaceIsDestructive() {
        let plan = ServerObjects.dropTablespace(name: "fast", dialect: pg)
        XCTAssertEqual(plan.sql, "DROP TABLESPACE \"fast\"")
        XCTAssertEqual(plan.risk, .destructive, "DROP 是不可逆操作")
        XCTAssertEqual(plan.command?.isDestructive, true)
        XCTAssertTrue(plan.command?.warnings.contains { $0.contains("不可逆") } == true)
    }

    func testGBaseTablespaceWritesAreUnsupportedWithoutAnySQL() {
        for plan in [
            ServerObjects.createTablespace(TablespaceSpec(name: "fast", location: "/data/x"), dialect: gbase),
            ServerObjects.dropTablespace(name: "fast", dialect: gbase)
        ] {
            XCTAssertNil(plan.sql, "GBase 不该生成任何表空间语句")
            XCTAssertEqual(plan.risk, nil)
            guard let reason = plan.unsupportedReason else {
                return XCTFail("不支持时必须是可读说明，而不是被当成「被拒」")
            }
            XCTAssertTrue(reason.contains("表空间"))
            XCTAssertNil(plan.rejectionReason)
        }
    }

    // MARK: 写操作：扩展

    func testCreateExtensionStatementWithSchemaAndVersion() {
        let plain = ServerObjects.createExtension(ExtensionSpec(name: "hstore"), dialect: pg)
        XCTAssertEqual(plain.sql, "CREATE EXTENSION \"hstore\"")

        let scoped = ServerObjects.createExtension(
            ExtensionSpec(name: "hstore", schema: "ext", version: "1.10"),
            dialect: pg
        )
        XCTAssertEqual(scoped.sql, "CREATE EXTENSION \"hstore\" WITH SCHEMA \"ext\" VERSION '1.10'")
        XCTAssertEqual(scoped.risk, .elevated)
    }

    /// 扩展名比标识符宽一档：`uuid-ossp` 是真实存在的常见扩展（加引号后合法）。
    func testCreateExtensionAcceptsHyphenatedName() {
        XCTAssertNil(ServerObjects.nameValidationFailure("uuid-ossp", kind: .extension))
        XCTAssertEqual(
            ServerObjects.createExtension(ExtensionSpec(name: "uuid-ossp"), dialect: pg).sql,
            "CREATE EXTENSION \"uuid-ossp\""
        )
        // 同一串名字在角色上就不合法（角色名是严格标识符）。
        XCTAssertNotNil(ServerObjects.nameValidationFailure("uuid-ossp", kind: .role))
    }

    func testCreateExtensionRejectsBadNameOrSchema() {
        let badName = ServerObjects.createExtension(ExtensionSpec(name: "a; DROP EXTENSION x"), dialect: pg)
        XCTAssertNil(badName.sql)
        XCTAssertTrue(badName.rejectionReason?.contains("分号") == true)

        let badSchema = ServerObjects.createExtension(
            ExtensionSpec(name: "hstore", schema: "bad schema"),
            dialect: pg
        )
        XCTAssertNil(badSchema.sql)
        XCTAssertTrue(badSchema.rejectionReason?.contains("schema") == true)
    }

    func testGBaseExtensionWritesAreUnsupportedWithoutAnySQL() {
        for plan in [
            ServerObjects.createExtension(ExtensionSpec(name: "hstore"), dialect: gbase),
            ServerObjects.dropExtension(name: "hstore", dialect: gbase)
        ] {
            XCTAssertNil(plan.sql, "GBase 不该生成任何扩展语句")
            XCTAssertTrue(plan.unsupportedReason?.contains("扩展") == true)
            XCTAssertNil(plan.rejectionReason)
        }
    }

    func testDropExtensionAndDropRoleAreDestructive() {
        let dropExtension = ServerObjects.dropExtension(name: "hstore", dialect: pg)
        XCTAssertEqual(dropExtension.sql, "DROP EXTENSION \"hstore\"")
        XCTAssertEqual(dropExtension.risk, .destructive)

        let dropRole = ServerObjects.dropRole(name: "probe", dialect: pg)
        XCTAssertEqual(dropRole.sql, "DROP ROLE \"probe\"")
        XCTAssertEqual(dropRole.risk, .destructive)
        XCTAssertTrue(dropRole.command?.warnings.contains { $0.contains("REASSIGN OWNED") } == true,
                      "要提醒先处理名下对象：\(dropRole.command?.warnings ?? [])")
    }

    // MARK: 风险分级与统一入口

    func testRiskLevelsPerAction() {
        XCTAssertEqual(ServerObjectAction.createRole.risk, .elevated)
        XCTAssertEqual(ServerObjectAction.alterRole.risk, .elevated)
        XCTAssertEqual(ServerObjectAction.renameRole.risk, .elevated)
        XCTAssertEqual(ServerObjectAction.createTablespace.risk, .elevated)
        XCTAssertEqual(ServerObjectAction.createExtension.risk, .elevated)
        XCTAssertEqual(ServerObjectAction.dropRole.risk, .destructive)
        XCTAssertEqual(ServerObjectAction.dropTablespace.risk, .destructive)
        XCTAssertEqual(ServerObjectAction.dropExtension.risk, .destructive)

        for action in ServerObjectAction.allCases {
            if action.isDestructive {
                XCTAssertEqual(action.risk, .destructive, "\(action.rawValue) 是不可逆操作")
            }
            XCTAssertTrue(action.requiresConfirmation, "\(action.rawValue) 是写操作，一律要确认")
            XCTAssertFalse(ServerObjects.riskText(action.risk).isEmpty)
        }
        XCTAssertTrue(ServerObjects.riskText(.destructive).contains("不可逆"))
    }

    func testPlanDispatcherMatchesIndividualFunctions() {
        let requests: [ServerObjectRequest] = [
            .createRole(RoleSpec(name: "probe", password: "pw")),
            .alterRole(name: "probe", host: "%", password: "pw2", canLogin: nil, isSuperuser: nil),
            .renameRole(name: "probe", host: "%", newName: "probe2"),
            .dropRole(name: "probe", host: "%"),
            .createTablespace(TablespaceSpec(name: "fast", location: "/data/fast")),
            .dropTablespace(name: "fast"),
            .createExtension(ExtensionSpec(name: "hstore", schema: "public")),
            .dropExtension(name: "hstore")
        ]
        let expected: [String?] = [
            ServerObjects.createRole(RoleSpec(name: "probe", password: "pw"), dialect: pg).sql,
            ServerObjects.alterRole(name: "probe", password: "pw2", canLogin: nil, isSuperuser: nil, dialect: pg).sql,
            ServerObjects.renameRole(name: "probe", newName: "probe2", dialect: pg).sql,
            ServerObjects.dropRole(name: "probe", dialect: pg).sql,
            ServerObjects.createTablespace(TablespaceSpec(name: "fast", location: "/data/fast"), dialect: pg).sql,
            ServerObjects.dropTablespace(name: "fast", dialect: pg).sql,
            ServerObjects.createExtension(ExtensionSpec(name: "hstore", schema: "public"), dialect: pg).sql,
            ServerObjects.dropExtension(name: "hstore", dialect: pg).sql
        ]
        for (index, request) in requests.enumerated() {
            let plan = ServerObjects.plan(request, dialect: pg)
            XCTAssertEqual(plan.sql, expected[index], "统一入口必须与专用函数一致：\(request.action.rawValue)")
            XCTAssertEqual(plan.command?.action, request.action)
            XCTAssertEqual(plan.command?.kind, request.kind)
            XCTAssertEqual(plan.command?.targetName, request.targetName)
            XCTAssertEqual(
                plan, ServerObjects.plan(request, dialect: pg),
                "同输入必须给出同一个结果（确定性）"
            )
        }
    }

    func testPlanDispatcherRejectsSemicolonForEveryWriteAction() {
        // 一句话总括：**每个写操作都要能拒绝**（需求原话）。
        let evil = "x; DROP DATABASE postgres"
        let plans: [ServerObjectWritePlan] = [
            ServerObjects.plan(.createRole(RoleSpec(name: evil, password: "pw")), dialect: pg),
            ServerObjects.plan(.alterRole(name: evil, host: "%", password: "pw", canLogin: nil, isSuperuser: nil), dialect: pg),
            ServerObjects.plan(.renameRole(name: evil, host: "%", newName: "ok"), dialect: pg),
            ServerObjects.plan(.dropRole(name: evil, host: "%"), dialect: pg),
            ServerObjects.plan(.createTablespace(TablespaceSpec(name: evil, location: "/data/x")), dialect: pg),
            ServerObjects.plan(.dropTablespace(name: evil), dialect: pg),
            ServerObjects.plan(.createExtension(ExtensionSpec(name: evil)), dialect: pg),
            ServerObjects.plan(.dropExtension(name: evil), dialect: pg)
        ]
        for plan in plans {
            XCTAssertNil(plan.sql, "可疑名字必须让每个写操作都停在这里")
            XCTAssertTrue(plan.rejectionReason?.contains("分号") == true, "理由要可读：\(plan.preview)")
        }
    }

    func testCommandSummaryAndRiskText() {
        let command = ServerObjects.dropRole(name: "probe", dialect: pg).command
        XCTAssertEqual(command?.summary, "删除角色「probe」· 不可逆（高危）")
        XCTAssertEqual(command?.preview, command?.statement)
    }

    func testFormatBytesReusesStatsFormatting() {
        XCTAssertEqual(ServerObjects.formatBytes(1536), DatabaseStats.formatBytes(1536))
        XCTAssertEqual(ServerObjects.formatBytes(0), "0 B")
    }
}
