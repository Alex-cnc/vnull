import Foundation
import Darwin
import DoyahCore

@main
struct DoyahCLI {
    /// 解析 `--cancel-after <秒>`；未指定时返回 nil。
    private static func cancelDelay(arguments: [String]) -> Double? {
        guard let index = arguments.firstIndex(of: "--cancel-after"),
              index + 1 < arguments.count,
              let value = Double(arguments[index + 1]),
              value > 0 else {
            return nil
        }
        return value
    }

    /// `secret` 子命令：把「项目内口令文件」的读写暴露给命令行与脚本。
    ///
    /// **为什么要有它**：口令格式（MD5 派生密钥 + XOR 混淆）只该有**一份实现**，
    /// 而且必须在 Core 里被测住。验收脚本要取密码时调用它，而不是在 bash / python 里再抄一遍
    /// —— 抄一份就会漂移，漂移的后果是"密码读不出来"这种最难查的故障。
    ///
    /// 用法：
    ///   DoyahCLI secret set --id <连接 UUID> [--stdin]      # 从 stdin 读口令（避免出现在命令行历史里）
    ///   DoyahCLI secret get --id <连接 UUID>                # 打印口令（给脚本用）
    ///   DoyahCLI secret delete --id <连接 UUID>
    ///   DoyahCLI secret path                                 # 打印口令文件路径
    static func runSecretCommand(arguments: [String]) async -> Int32 {
        // `--file <path>`：只针对某一个口令文件操作（多候选之后，验证与排障都需要它 ——
        // 否则读操作会回退到别的候选，"读到了"并不能证明指定那份是好的）。
        let store: FileSecretStore
        if let index = arguments.firstIndex(of: "--file"), index + 1 < arguments.count {
            store = FileSecretStore(fileURL: URL(fileURLWithPath: arguments[index + 1]))
        } else {
            store = FileSecretStore()
        }
        func value(of flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        guard let action = arguments.first else {
            FileHandle.standardError.write(Data("用法：secret <set|get|delete|path> --id <UUID>\n".utf8))
            return 2
        }

        if action == "path" {
            print(store.location().path)
            return 0
        }

        guard let idText = value(of: "--id"), let id = UUID(uuidString: idText) else {
            FileHandle.standardError.write(Data("缺少或非法的 --id <UUID>\n".utf8))
            return 2
        }

        do {
            switch action {
            case "set":
                let data = FileHandle.standardInput.readDataToEndOfFile()
                guard let raw = String(data: data, encoding: .utf8) else {
                    FileHandle.standardError.write(Data("stdin 不是 UTF-8\n".utf8))
                    return 2
                }
                // 去掉末尾换行：`echo` 会带上它，而口令不该被一个换行毁掉。
                let password = raw.hasSuffix("\n") ? String(raw.dropLast()) : raw
                try store.setPassword(password, for: id)
                print("已写入：\(store.location().path)")
                return 0
            case "get":
                guard let password = try store.password(for: id) else { return 1 }
                print(password)
                return 0
            case "delete":
                try store.deletePassword(for: id)
                return 0
            default:
                FileHandle.standardError.write(Data("未知动作：\(action)\n".utf8))
                return 2
            }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    static func main() async {
        let environment = ProcessInfo.processInfo.environment
        let arguments = Array(CommandLine.arguments.dropFirst())

        if arguments.first == "secret" {
            let code = await runSecretCommand(arguments: Array(arguments.dropFirst()))
            exit(code)
        }

        // agent-sql：无界面地跑一遍「自然语言 → SQL」通道（NFR-AI-06 的本地端点验证入口）。
        // 为什么 CLI 要有它：**"指向本地端点即零外发"这件事必须能被脚本验证** ——
        // 图形界面里点一下不算证据，能跑脚本、能核对统一外发日志才算。
        if arguments.first == "agent-sql" {
            let code = await runAgentSQLCommand(
                arguments: Array(arguments.dropFirst()),
                client: OpenAICompatibleClient(
                    transport: EgressRecordingTransport(
                        origin: "CLI · 自然语言生成 SQL",
                        wrapped: URLSessionTransport()
                    )
                )
            )
            exit(code)
        }

        let host = environment["PGHOST"] ?? "127.0.0.1"
        let port = Int(environment["PGPORT"] ?? "5432") ?? 5432
        let username = environment["PGUSER"] ?? "postgres"
        let password = environment["PGPASSWORD"]
        let database = environment["PGDATABASE"] ?? ""
        let sslMode = SSLMode(rawValue: environment["PGSSLMODE"] ?? "prefer") ?? .prefer

        let config = ConnectionConfig(
            name: "CLI",
            dbType: .postgresql,
            host: host,
            port: port,
            database: database,
            username: username,
            sslMode: sslMode,
            timeout: 10
        )

        print("PostgreSQL 连接测试")
        print("目标：\(username)@\(host):\(port)/\(database.isEmpty ? "<default>" : database)")
        print("SSL：\(sslMode.rawValue)")
        print("")

        let service = PostgresService(config: config, password: password)

        let serverInfo: ServerInfo
        do {
            serverInfo = try await service.connect()
            print("连接成功")
            print("server_version: \(serverInfo.version)")
            print("database:      \(serverInfo.database)")
            print("user:          \(serverInfo.user)")
            print("")
        } catch {
            print("连接失败")
            print("")
            print("简要信息：\(error.localizedDescription)")
            print("")
            print("调试详情：")
            print(String(reflecting: error))
            exit(1)
        }

        // --tree [--columns]：验证元数据 / 对象树链路
        // 层级：server(0) → database(1) → schema(2) → table/view(3) → column(4)
        if arguments.contains("--tree") {
            let includeColumns = arguments.contains("--columns")
            let maxDepth = includeColumns ? 4 : 3
            do {
                let serverLabel = "\(username)@\(host):\(port)"
                var extraServices: [String: any DatabaseService] = [:]
                var metadataCache: [String: MetadataService] = [:]

                /// 取某个数据库的元数据服务；非当前库会按需建立独立连接。
                func metadata(for database: String) async throws -> MetadataService {
                    if let cached = metadataCache[database] {
                        return cached
                    }

                    let databaseService: any DatabaseService
                    if database == serverInfo.database {
                        databaseService = service
                    } else if let cachedService = extraServices[database] {
                        databaseService = cachedService
                    } else {
                        var derived = config
                        derived.database = database
                        let newService = PostgresService(config: derived, password: password)
                        _ = try await newService.connect()
                        extraServices[database] = newService
                        databaseService = newService
                    }

                    let created = MetadataService(
                        service: databaseService,
                        dialect: PostgresDialect(),
                        databaseName: database,
                        serverLabel: serverLabel
                    )
                    metadataCache[database] = created
                    return created
                }

                func printTree(_ object: DatabaseObject, depth: Int) async {
                    let indent = String(repeating: "  ", count: depth)
                    if let detail = object.detail, !detail.isEmpty {
                        print("\(indent)\(object.kind.rawValue) \(object.name): \(detail)")
                    } else {
                        print("\(indent)\(object.kind.rawValue) \(object.name)")
                    }

                    guard depth < maxDepth else { return }

                    let database = object.database ?? serverInfo.database
                    do {
                        let tree = try await metadata(for: database)
                        let children = try await tree.loadChildren(of: object)
                        for child in children.prefix(50) {
                            await printTree(child, depth: depth + 1)
                        }
                        if children.count > 50 {
                            print("\(indent)  … 还有 \(children.count - 50) 个对象")
                        }
                    } catch {
                        print("\(indent)  ⚠️ \(error.localizedDescription)")
                    }
                }

                let rootTree = try await metadata(for: serverInfo.database)
                let roots = try await rootTree.loadRoot()
                for root in roots {
                    await printTree(root, depth: 0)
                }

                for (_, extraService) in extraServices {
                    await extraService.disconnect()
                }
                await service.disconnect()
                print("")
                print("对象树加载完成。")
                return
            } catch {
                print("对象树加载失败")
                print("简要信息：\(error.localizedDescription)")
                print("调试详情：")
                print(String(reflecting: error))
                await service.disconnect()
                exit(3)
            }
        }

        // --can-create-database：验证「当前用户能否建库」的探测链路（FR-META-11）。
        if arguments.contains("--can-create-database") {
            let dialect = PostgresDialect()
            guard let query = dialect.databaseCreationPrivilegeQuery() else {
                print("canCreateDatabase: unknown（该方言未实现探测）")
                await service.disconnect()
                return
            }

            do {
                var rawValue: String?
                for try await event in service.execute(query, options: .default) {
                    if case .resultSet(let result) = event {
                        rawValue = result.rows.first?.first ?? nil
                    }
                }

                let allowed = PrivilegeProbe.databaseCreationAllowed(from: rawValue)
                let text = allowed.map { $0 ? "true" : "false" } ?? "unknown"
                print("canCreateDatabase: \(text)（原始值：\(rawValue ?? "NULL")）")
                await service.disconnect()
                return
            } catch {
                print("建库权限探测失败")
                print("简要信息：\(error.localizedDescription)")
                await service.disconnect()
                exit(4)
            }
        }

        // backup：备份 / 恢复的**真实执行**（FR-IO-04）。
        // 走 `BackupCommand` 生成 argv（**不经过 shell**）+ `BackupExecutor` 起进程，
        // 密码只经 `PGPASSWORD` 环境变量传给子进程，不进 argv。
        if arguments.first == "backup" {
            let code = await runBackupCommand(
                arguments: Array(arguments.dropFirst()),
                environment: environment
            )
            exit(code)
        }

        // export：**流式**导出（FR-RES-13 的「取」那一半）。
        // 走服务端游标逐页取、逐页写盘：内存占用与总行数无关，也不用 OFFSET 翻页（大表上那是 O(n²)）。
        if arguments.contains("--export") || arguments.first == "export" {
            let code = await runExportCommand(
                arguments: arguments.filter { $0 != "export" },
                service: service,
                dialect: PostgresDialect()
            )
            await service.disconnect()
            exit(code)
        }

        // synth：合成数据（FR-AI-07）。默认**只导出 SQL 到 stdout**，`--write` 才真写库。
        if arguments.first == "synth" {
            let code = await runSynthCommand(
                arguments: Array(arguments.dropFirst()),
                service: service,
                serverInfo: serverInfo
            )
            await service.disconnect()
            exit(code)
        }

        let sql = resolveSQL(arguments: arguments) ?? "SELECT version(), current_database(), current_user;"

        print("SQL：")
        print(sql)
        print("")

        // --cancel-after <秒>：用于验证服务端取消（FR-EXEC-08）。
        let cancelDelay = Self.cancelDelay(arguments: arguments)

        do {
            // CLI 也走**句柄化**取消：`--cancel-after` 验证的正是"停止能不能下发到服务端"，
            // 拿不到句柄就没法定向，也就验证不了这条契约。
            let handle = ExecutionHandle()
            let stream = service.execute(sql, options: .default, handle: handle)

            let canceller: Task<Void, Never>? = cancelDelay.map { delay in
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    let outcome = await service.cancel(handle)
                    print("cancel: 触发服务端取消 → \(outcome)")
                }
            }
            defer { canceller?.cancel() }

            for try await event in stream {
                switch event {
                case .started(let index):
                    print("--- statement \(index + 1) ---")
                case .resultSet(let result):
                    // 先按原有契约打出「无结果集」，再补一行影响行数：
                    // 两行信息不重复（一个说"没有表格"，一个说"写了几行"），
                    // 而验收脚本 `test-local-query-path.sh` 断言的是前者 —— 不该为了措辞去改验收契约。
                    if result.columns.isEmpty {
                        print("(no result set)")
                    }
                    if let affected = result.affectedRows {
                        // 影响行数随结果对象上报（R-32：通道只有这一条）
                        print("affectedRows: \(affected)")
                    }
                    if !result.columns.isEmpty {
                        print(result.columns.map { "\($0.name):\($0.typeName)" }.joined(separator: " | "))
                        for row in result.rows {
                            print(row.map { $0 ?? "NULL" }.joined(separator: " | "))
                        }
                    }
                case .notice(let message):
                    print("notice: \(message)")
                case .finished(let summary):
                    let duration = String(format: "%.3f", summary.duration)
                    print("finished: \(summary.statementCount) statement(s), \(duration)s")
                }
            }

            await service.disconnect()
            print("")
            print("查询执行完成。")
        } catch {
            print("查询失败")
            print("")
            print("简要信息：\(error.localizedDescription)")
            print("")
            print("调试详情：")
            print(String(reflecting: error))
            await service.disconnect()
            exit(2)
        }
    }

    /// `synth --table <表> [--schema S] --rows N [--seed S] [--write] [--overwrite] [--preview N] [--spec 文件.json]`
    ///
    /// 规格来源：`--spec` 给 JSON（`SyntheticTableSpec`，可手写可复用），否则**按表结构自动推断**
    /// （主键用序列、非空列不给 NULL —— 保证生成的数据插得进去）。
    /// 默认只把 INSERT 语句打到 stdout（**不执行**）；`--write` 才真写库，写库前会把语句摊开。
    private static func runSynthCommand(
        arguments: [String],
        service: any DatabaseService,
        serverInfo: ServerInfo
    ) async -> Int32 {
        func value(for flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        guard let table = value(for: "--table") else {
            print("用法：synth --table <表> [--schema S] --rows N [--seed S] [--write] [--overwrite] [--preview N] [--spec 文件.json]")
            return 64
        }
        let schema = value(for: "--schema")
        let rowCount = Int(value(for: "--rows") ?? "100") ?? 100
        let seed = UInt64(value(for: "--seed") ?? "1") ?? 1
        let previewLimit = Int(value(for: "--preview") ?? "3") ?? 3

        let dialect = PostgresDialect()
        let spec: SyntheticTableSpec
        if let specPath = value(for: "--spec") {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: specPath))
                spec = try JSONDecoder().decode(SyntheticTableSpec.self, from: data)
            } catch {
                print("读取规格失败：\(error.localizedDescription)")
                return 65
            }
        } else {
            // 读表结构 → 推断规格。
            guard let query = dialect.tableStructureQuery(table: table, schema: schema) else {
                print("该数据库类型不支持读表结构，无法自动推断规格（可改用 --spec）")
                return 65
            }
            var columns: [SyntheticSpecBuilder.ColumnShape] = []
            do {
            for try await event in service.execute(query, options: .default) {
                if case .resultSet(let result) = event {
                    columns = result.rows.compactMap { row -> SyntheticSpecBuilder.ColumnShape? in
                        guard row.indices.contains(0), let name = row[0], !name.isEmpty else { return nil }
                        return SyntheticSpecBuilder.ColumnShape(
                            name: name,
                            typeName: row.indices.contains(1) ? (row[1] ?? "text") : "text",
                            isNullable: (row.indices.contains(2) ? (row[2] ?? "YES") : "YES").uppercased() != "NO",
                            isPrimaryKey: (row.indices.contains(4) ? (row[4] ?? "NO") : "NO").uppercased() == "YES"
                        )
                    }
                }
            }
            } catch {
                print("读表结构失败：\(error.localizedDescription)")
                return 66
            }
            guard !columns.isEmpty else {
                print("读不到 \(table) 的列结构（表不存在？）")
                return 66
            }
            spec = SyntheticSpecBuilder.spec(
                table: table,
                schema: schema,
                columns: columns,
                rowCount: rowCount,
                seed: seed
            )
            print("按表结构推断出 \(columns.count) 列规则（主键→序列、非空列不给 NULL）")
        }

        let issues = SyntheticDataGenerator.issues(in: spec)
        if !issues.isEmpty {
            print("规格有问题：")
            for issue in issues { print("  · \(issue)") }
            return 67
        }

        do {
            let rows = try SyntheticDataGenerator.generate(spec)
            print("已生成 \(rows.count) 行（seed=\(spec.seed)，同 seed + 同规格必然得到同一批行）")
            for row in rows.prefix(max(0, previewLimit)) {
                print("  " + row.map { $0 ?? "NULL" }.joined(separator: " | "))
            }

            guard let sql = SyntheticDataGenerator.insertStatements(
                rows: rows,
                spec: spec,
                writeMode: arguments.contains("--overwrite") ? .overwrite : .append,
                dialect: dialect
            ) else {
                print("生成 INSERT 失败")
                return 67
            }

            if !arguments.contains("--write") {
                print("")
                print("（未加 --write，只输出 SQL）")
                print(sql)
                return 0
            }

            print("")
            print("将执行：\(sql.split(separator: "\n").count) 行 SQL（首行：\(sql.split(separator: "\n").first ?? "")）")
            var affected = 0
            for try await event in service.execute(sql, options: .default) {
                if case .resultSet(let result) = event { affected += result.affectedRows ?? 0 }
            }
            print("写入完成：影响 \(affected) 行")
            return 0
        } catch {
            print("生成 / 写入失败：\(error.localizedDescription)")
            return 68
        }
    }

    /// `backup --kind dump|dumpall|restore --out <路径> [--database 库] [--host H] [--port P] [--user U]
    ///         [--format plain|custom|directory] [--jobs N] [--tool <pg_dump 绝对路径>] [--clean] [--dry-run]`
    ///
    /// 为什么 CLI 也要有这条：备份是"必须有人真的跑一遍才知道对不对"的功能，
    /// 而图形界面里点一次没法进回归脚本。`--dry-run` 只打印将要执行的命令行（密码显示为 `***`）。
    private static func runBackupCommand(
        arguments: [String],
        environment: [String: String]
    ) async -> Int32 {
        func value(for flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        let kindRaw = (value(for: "--kind") ?? "dump").lowercased()
        let kind: BackupPlan.Kind
        switch kindRaw {
        case "dump": kind = .dump
        case "dumpall", "dump-all": kind = .dumpAll
        case "restore": kind = .restore
        default:
            print("--kind 只支持 dump / dumpall / restore")
            return 64
        }

        let format: BackupCommand.Format
        switch (value(for: "--format") ?? "plain").lowercased() {
        case "plain": format = .plain
        case "custom": format = .custom
        case "directory", "dir": format = .directory
        default:
            print("--format 只支持 plain / custom / directory")
            return 64
        }

        guard let outputPath = value(for: "--out") else {
            print("缺少 --out <路径>")
            return 64
        }

        let host = value(for: "--host") ?? environment["PGHOST"] ?? "127.0.0.1"
        let port = Int(value(for: "--port") ?? environment["PGPORT"] ?? "5432") ?? 5432
        let user = value(for: "--user") ?? environment["PGUSER"]
        let database = value(for: "--database") ?? environment["PGDATABASE"]
        let password = environment["PGPASSWORD"]

        let plan = BackupPlan(
            kind: kind,
            target: BackupCommand.Target(host: host, port: port, user: user, database: database),
            format: format,
            filePath: outputPath,
            jobs: value(for: "--jobs").flatMap(Int.init),
            noOwner: arguments.contains("--no-owner"),
            clean: arguments.contains("--clean"),
            rolesOnly: arguments.contains("--roles-only"),
            globalsOnly: arguments.contains("--globals-only"),
            noRolePasswords: arguments.contains("--no-role-passwords"),
            // `--tool` 允许指定绝对路径：GUI / CI 的 PATH 里通常没有 pg_dump（本机就如此）。
            executableName: value(for: "--tool") ?? BackupPlan.defaultExecutable(for: kind)
        )

        print("命令：\(plan.displayCommand(password: password))")
        if arguments.contains("--dry-run") {
            print("（--dry-run：不执行）")
            return 0
        }

        // 前置版本检查（FR-IO-04）：`pg_dump` 只能处理不比自己新的服务器 ——
        // 不先查一次，用户会等到跑到一半才看到一句并不直观的服务端报错。
        if !arguments.contains("--no-version-check") {
            let serverVersion = await fetchServerVersion(host: host, port: port, user: user, database: database, password: password)
            let toolVersion = await fetchToolVersion(plan: plan, password: password)
            let compatibility = BackupToolCheck.evaluate(toolVersion: toolVersion, serverVersion: serverVersion)
            if !compatibility.isUsable, !arguments.contains("--force") {
                if let diagnosis = BackupToolCheck.diagnosis(for: compatibility, toolName: plan.executableName) {
                    print(diagnosis)
                }
                print("（如确认要试：加 --force；跳过检查：加 --no-version-check）")
                return 65
            }
        }

        do {
            let result = try await BackupExecutor().execute(plan, password: password) { line in
                print("  \(line)")
            }
            if result.isFailure {
                print("执行失败（退出码 \(result.exitCode)）：")
                print(result.failureSummary ?? "")
                return 1
            }
            print("完成：\(result.outputLineCount) 行输出。")
            return 0
        } catch {
            print("无法执行：\(error.localizedDescription)")
            return 68
        }
    }

    /// 取服务器版本（只为前置检查；拿不到就返回 nil，由判定逻辑说"不确定"）。
    private static func fetchServerVersion(
        host: String,
        port: Int,
        user: String?,
        database: String?,
        password: String?
    ) async -> DatabaseVersion? {
        var config = ConnectionConfig(
            name: "backup-check",
            dbType: .postgresql,
            host: host,
            port: port,
            database: database ?? "",
            username: user ?? "",
            sslMode: .prefer,
            timeout: 10
        )
        config.database = database ?? "postgres"
        let service = PostgresService(config: config, password: password)
        do {
            _ = try await service.connect()
            defer { Task { await service.disconnect() } }
            var raw: String?
            for try await event in service.execute("SHOW server_version", options: .default) {
                if case .resultSet(let result) = event {
                    raw = result.rows.first?.first ?? nil
                }
            }
            await service.disconnect()
            guard let raw else { return nil }
            return PostgresDialect().parseServerVersion(raw)
        } catch {
            await service.disconnect()
            return nil
        }
    }

    /// 执行 `<tool> --version` 并解析。
    private static func fetchToolVersion(plan: BackupPlan, password: String?) async -> DatabaseVersion? {
        var output = ""
        let runner = FoundationProcessRunner()
        _ = try? await runner.run(
            executable: plan.executableName,
            arguments: ["--version"],
            environment: password.map { ["PGPASSWORD": $0] } ?? [:]
        ) { line in
            output += line + "\n"
        }
        return BackupToolCheck.parseToolVersion(output)
    }

    /// `agent-sql --endpoint http://127.0.0.1:11434 --model qwen2.5:7b "指令" [--schema t1,t2] [--api-key K] [--show-egress]`
    ///
    /// 输出：模型的 SQL、解释、护栏判定、配额账本，以及（可选）统一外发日志里刚记下的条目 ——
    /// 后者是"零外发 / 最小外发"的**可核对证据**，而不是一句承诺。
    private static func runAgentSQLCommand(
        arguments: [String],
        client: any LLMClient
    ) async -> Int32 {
        func value(for flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        guard let endpoint = value(for: "--endpoint") else {
            print("用法：agent-sql --endpoint <OpenAI 兼容端点> --model <模型名> \"指令\" [--schema 表1,表2] [--api-key K] [--show-egress]")
            return 64
        }
        guard let model = value(for: "--model") else {
            print("缺少 --model")
            return 64
        }
        // 指令是第一个不以 `--` 开头的自由参数。
        let flagsWithValue: Set<String> = ["--endpoint", "--model", "--schema", "--api-key"]
        var instruction: String?
        var skipNext = false
        for argument in arguments {
            if skipNext { skipNext = false; continue }
            if flagsWithValue.contains(argument) { skipNext = true; continue }
            if argument.hasPrefix("--") { continue }
            instruction = argument
            break
        }
        guard let instruction, !instruction.isEmpty else {
            print("缺少指令文本")
            return 64
        }

        let tables = (value(for: "--schema") ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // `--disabled` 用来验证 NFR-AI-02 / AC-AI-01 的那条硬承诺：
        // **总开关关闭时一个请求都不发**（不是"发了再报错"）。
        let isEnabled = !arguments.contains("--disabled")
        let configuration = AgentConfiguration(
            isEnabled: isEnabled,
            endpoint: endpoint,
            model: model,
            guardPolicy: .readOnlyDefault
        )
        let apiKey = value(for: "--api-key")

        print("端点：\(endpoint)")
        print("本地端点判定：\(configuration.requiresAPIKey ? "否（需要 API Key）" : "是（免 API Key）")")
        print("")

        do {
            let result = try await AgentSQLGenerator.generate(
                request: AgentSQLGenerator.Request(
                    instruction: instruction,
                    schema: AgentSQLGenerator.SchemaSummary(tables: tables.map {
                        AgentSQLGenerator.SchemaSummary.Table(name: $0, columns: [])
                    }),
                    currentStatement: nil
                ),
                configuration: configuration,
                apiKey: apiKey,
                policy: .readOnlyDefault,
                ledger: .empty,
                client: client
            )

            print("SQL：")
            print(result.sql)
            if let explanation = result.explanation, !explanation.isEmpty {
                print("")
                print("解释：")
                print(explanation)
            }
            print("")
            print("护栏判定：\(result.guardAssessment.verdict)")
            print("配额账本：请求 \(result.quotaLedger.requestCount) 次 / \(result.quotaLedger.totalTokens) token")
            print("是否已执行：\(result.isExecuted ? "是（不该发生）" : "否")")

            if arguments.contains("--show-egress") {
                let entries = (try? await EgressLog.shared.entries(limit: 5)) ?? []
                print("")
                print("统一外发日志（最近 \(entries.count) 条）：")
                for entry in entries {
                    print("  \(entry.kind.rawValue) → \(entry.target) [\(entry.outcome.rawValue)] \(entry.origin)")
                }
            }
            return 0
        } catch {
            print("生成失败：\(error.localizedDescription)")
            return 67
        }
    }

    /// `export --query "SELECT …" --out 文件 [--format csv|json|tsv|markdown|insert] [--fetch-size N] [--table 名]`
    ///
    /// 为什么 CLI 也要有这条路径：图形界面里导出大表是"用户点一下"的事，而**验证它真的流式**
    /// 需要一个能脚本化、能测内存的入口 —— 这条命令就是这个入口。
    private static func runExportCommand(
        arguments: [String],
        service: any DatabaseService,
        dialect: PostgresDialect
    ) async -> Int32 {
        func value(for flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        guard let query = value(for: "--query") ?? value(for: "-c") else {
            print("用法：export --query \"SELECT …\" --out <文件> [--format csv|json|tsv|markdown|insert] [--fetch-size N] [--table 名]")
            return 64
        }
        guard let outputPath = value(for: "--out") else {
            print("缺少 --out <文件>")
            return 64
        }

        let format: ResultExportFormat
        switch (value(for: "--format") ?? "csv").lowercased() {
        case "csv": format = .csv
        case "json": format = .json
        case "tsv": format = .tsv
        case "markdown", "md": format = .markdown
        case "insert", "sql": format = .sqlInsert
        default:
            print("不支持的格式（csv / json / tsv / markdown / insert）")
            return 64
        }

        let fetchSize = Int(value(for: "--fetch-size") ?? "") ?? CursorPaging.defaultPageSize
        guard fetchSize > 0 else {
            print("--fetch-size 必须大于 0")
            return 64
        }

        let plan: CursorPagingPlan
        switch CursorPaging.plan(query: query, pageSize: fetchSize) {
        case .success(let value):
            plan = value
        case .failure(let error):
            print("无法导出：\(error.localizedDescription)")
            return 65
        }

        /// 单条语句执行到底，取最后的结果集（`BEGIN` / `DECLARE` 这类没有结果集，返回空壳）。
        func run(_ sql: String) async throws -> QueryResult {
            var last: QueryResult?
            for try await event in service.execute(sql, options: .default) {
                if case .resultSet(let result) = event { last = result }
            }
            return last ?? QueryResult(
                columns: [],
                rows: [],
                affectedRows: nil,
                executionTime: 0,
                isTruncated: false,
                truncationLimit: nil
            )
        }

        let url = URL(fileURLWithPath: outputPath)
        let fetcher = CursorFetcher(plan: plan, execute: { try await run($0) })
        var writer: ResultStreamWriter?

        do {
            try await fetcher.open()

            // 列信息要**第一页**才有（游标不会提前告诉我们列是什么），所以 writer 在这里才建。
            guard let first = try await fetcher.nextPage() else {
                print("没有取到任何结果集")
                await fetcher.close()
                return 66
            }

            let streamWriter = ResultStreamWriter(
                targetURL: url,
                format: format,
                columns: first.columns,
                tableName: value(for: "--table") ?? "table_name",
                dialect: dialect
            )
            writer = streamWriter
            try streamWriter.begin()
            try streamWriter.write(first.rows)

            while let page = try await fetcher.nextPage() {
                try streamWriter.write(page.rows)
            }

            let report = try streamWriter.finish()
            print("导出完成：\(report.rowCount) 行 / \(report.byteCount) 字节 / \(await fetcher.pageCount) 页")
            print("文件：\(url.path)")
            print("取数方式：服务端游标逐页（每页 \(fetchSize) 行），内存占用与总行数无关")
            return 0
        } catch {
            writer?.abort()
            await fetcher.close()
            print("导出失败：\(error.localizedDescription)")
            return 67
        }
    }

    /// 支持三种输入方式：`-c "SQL"`、`--command "SQL"`，或从标准输入管道读取。
    private static func resolveSQL(arguments: [String]) -> String? {
        if let commandIndex = arguments.firstIndex(where: { $0 == "-c" || $0 == "--command" }),
           commandIndex + 1 < arguments.count {
            return arguments[commandIndex + 1]
        }

        if isatty(STDIN_FILENO) == 0 {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            if let text = String(data: data, encoding: .utf8),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }

        return nil
    }
}
