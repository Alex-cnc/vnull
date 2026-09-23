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
