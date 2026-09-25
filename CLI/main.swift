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

        // archive-add：用**产品的归档写入器**追加一条记录（FR-EDIT-31）。
        // 存在的理由：记忆层的验证必须用真归档格式 —— 手编格式验的是"我以为的格式"，
        // 本轮就踩过（手写文件解析出 0 条）。
        if arguments.first == "archive-add" {
            let code = runArchiveAddCommand(arguments: Array(arguments.dropFirst()))
            exit(code)
        }

        // memory：查询记忆（FR-AI-13）—— 从归档 .sql 建索引、按前缀给补全候选。
        // 不需要数据库连接：**事实源是本地归档文件**，索引是纯派生缓存。
        // specs：任务定义的版本化 / diff / 回滚 / 重跑语义（FR-AI-11）。不需要数据库连接。
        if arguments.first == "specs" {
            exit(runSpecsCommand(arguments: Array(arguments.dropFirst())))
        }

        // terminal-palette：打印内嵌终端的深 / 浅两套色板与实测对比度（FR-EDIT-29）。
        // 为什么要有它：配色不该只存在于代码里 —— 这个出口让**设计稿、文档与代码同源**，
        // 也让"某个槽位对底色的对比度是多少"这句话可以被脚本复算，而不是靠肉眼估。
        if arguments.first == "terminal-palette" {
            exit(runTerminalPaletteCommand(arguments: Array(arguments.dropFirst())))
        }

        // terminal-modes：终端输入编码与设备查询应答（FR-EDIT-29 的"输入 / 应答"证据出口）。
        // 为什么要有它：鼠标上报（?1002/?1006）、DECCKM、DA1 / DSR / DECRQM / XTVERSION
        // 全是"一串字节"的事，界面里看不出来 —— 给个能脚本化、能对着规范核对的出口。
        if arguments.first == "terminal-modes" {
            exit(runTerminalModesCommand(arguments: Array(arguments.dropFirst())))
        }

        // code-tokens：工作区代码编辑器的"语言层"证据出口（FR-EDIT-36）。
        // 着色与补全在界面里只能靠眼睛看，而"哪个词算关键字"是可以逐条核对的 ——
        // 给个能脚本化、能对着语言定义核的出口。
        if arguments.first == "code-tokens" {
            exit(runCodeTokensCommand(arguments: Array(arguments.dropFirst())))
        }

        // tunnel：SSH 隧道的可复跑出口（FR-CONN-18）。
        // 为什么要有它：隧道成不成、参数对不对、清理干不干净，**在界面里只能靠"连不上"来感知**；
        // 命令行能给出一条可断言、可脚本化的路径（脚本用替身 ssh 做端到端转发验证）。
        if arguments.first == "tunnel" {
            exit(runTunnelCommand(arguments: Array(arguments.dropFirst())))
        }

        // mysql：FR-DRV-09 的可脚本化出口。
        //
        // 为什么单开一个子命令而不是往 PG 那条默认路径里塞分支：默认路径从环境变量到
        // `--tree` 全是 PostgreSQL 专用的（`PostgresService` 写死在里面），
        // 硬塞会让"哪条路径走哪个驱动"变成靠读代码才知道的事。这里给 MySQL 一条**自己的**路。
        if arguments.first == "mysql" || arguments.first == "gbase8a" {
            let type = arguments.first == "gbase8a" ? "gbase8a" : "mysql"
            let code = await runMySQLCommand(arguments: Array(arguments.dropFirst()), defaultType: type)
            exit(code)
        }

        // diagnose：FR-AI-03 的可脚本化出口（取证 → 组装上下文 → 解析模型回复）。
        if arguments.first == "diagnose" {
            let code = await runDiagnoseCommand(arguments: Array(arguments.dropFirst()))
            exit(code)
        }

        // maintain：FR-AI-04 的可脚本化出口（计划解析 → 逐条审阅 → 批准后才执行）。
        if arguments.first == "maintain" {
            let code = await runMaintainCommand(arguments: Array(arguments.dropFirst()))
            exit(code)
        }

        // mcp：FR-AI-10 的可脚本化出口（serve = 我们当 server；call = 我们当 host）。
        if arguments.first == "mcp" {
            let code = await runMCPCommand(arguments: Array(arguments.dropFirst()))
            exit(code)
        }

        if arguments.first == "memory" {
            let code = runMemoryCommand(arguments: Array(arguments.dropFirst()))
            exit(code)
        }

        // connections：列出已保存的连接及其环境标签 / 颜色（FR-CONN-16）。
        // 为什么要它：标签是"存在配置里、显示在界面上"的东西，**界面没法进脚本**，
        // 于是"写进去的东西读得回来"需要一条命令行出口。
        if arguments.first == "connections" {
            let code = await runConnectionsCommand(arguments: Array(arguments.dropFirst()))
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

        // `--json` = 机器可读：**不打任何横幅**。人类可读的问候语混进 JSON 里，
        // 调用方就得先"猜哪一行开始是数据"—— 那是最容易被写错的解析逻辑（本轮脚本就中招了）。
        let isMachineReadable = arguments.contains("--json")
        if !isMachineReadable {
            print("PostgreSQL 连接测试")
            print("目标：\(username)@\(host):\(port)/\(database.isEmpty ? "<default>" : database)")
            print("SSL：\(sslMode.rawValue)")
            print("")
        }

        let service = PostgresService(config: config, password: password)

        let serverInfo: ServerInfo
        do {
            serverInfo = try await service.connect()
            if !isMachineReadable {
                print("连接成功")
                print("server_version: \(serverInfo.version)")
                print("database:      \(serverInfo.database)")
                print("user:          \(serverInfo.user)")
                print("")
            }
        } catch {
            print("连接失败")
            print("")
            // 可读化（R-46 / FR-META-10）：人话 + 建议 + 错误码；原始串留在下面的调试详情里，
            // **不丢信息** —— 排查时"到底是哪个 SQLSTATE"才是关键。
            let failure = ConnectionFailure.describe(
                error,
                target: ConnectionFailure.Target(host: host, port: port, database: database, username: username)
            )
            if let failure {
                print(failure.fullText)
            } else {
                print("简要信息：\(error.localizedDescription)")
            }
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

        // fk-nav：外键引用导航（FR-DATA-06）。扫全库外键建一张图，再给跳转目标。
        if arguments.first == "fk-nav" {
            let code = await runForeignKeyNavCommand(arguments: Array(arguments.dropFirst()), service: service)
            await service.disconnect()
            exit(code)
        }

        // keepalive：连接保活心跳的诊断入口（FR-CONN-20）。按间隔真发若干次心跳并汇报。
        if arguments.first == "keepalive" {
            let code = await runKeepAliveCommand(arguments: Array(arguments.dropFirst()), service: service)
            await service.disconnect()
            exit(code)
        }

        // stats：数据库统计指标（FR-DIAG-04）。四类指标各一条只读查询。
        if arguments.first == "stats" {
            let code = await runStatsCommand(arguments: Array(arguments.dropFirst()), service: service)
            await service.disconnect()
            exit(code)
        }

        // server-objects：服务器级对象管理（FR-SESS-03）。只读列出 + 写操作的「预览 / 确认」。
        // 默认只打印将要执行的语句（dry-run），只有显式 `--yes` 才真执行 —— 与 Safe Mode
        // 「先看后做」同一纪律；`--dry-run` 可以显式把 `--yes` 压回预览。
        if arguments.first == "server-objects" {
            let code = await runServerObjectsCommand(
                arguments: Array(arguments.dropFirst()),
                service: service
            )
            await service.disconnect()
            exit(code)
        }

        // slow-queries：慢查询排行（FR-DIAG-03）。扩展没装时**给出怎么装**，而不是抛原始错误。
        if arguments.first == "slow-queries" {
            let code = await runSlowQueriesCommand(
                arguments: Array(arguments.dropFirst()),
                service: service,
                serverInfo: serverInfo
            )
            await service.disconnect()
            exit(code)
        }

        // row：单行竖排详情（FR-DATA-05）。等价于 psql 的 expanded display，
        // 用来在无界面环境里核对"长 JSON / 二进制 / NULL 到底长什么样"。
        if arguments.first == "row" {
            let code = await runRowCommand(arguments: Array(arguments.dropFirst()), service: service)
            await service.disconnect()
            exit(code)
        }

        // schema-snapshot：把一个库的结构导出成 JSON（FR-DDL-04 的一半）。
        // 为什么做成"导出再比"而不是一次连两个库：两个库常常不在同一次调用里
        // （不同连接 / 不同机器 / 不同时间），快照落文件才能随时比、也能进版本库。
        if arguments.first == "schema-snapshot" {
            let code = await runSchemaSnapshotCommand(arguments: Array(arguments.dropFirst()), service: service)
            await service.disconnect()
            exit(code)
        }

        // er-diagram：ER 图 / 关系图（FR-DDL-05）。由外键元数据生成图模型，
        // 导出 mermaid / dot / json —— 图能被外部工具渲染与核对，"布局是不是每次都在跳"
        // 也能靠这个出口脚本化验证。
        if arguments.first == "er-diagram" {
            let code = await runERDiagramCommand(arguments: Array(arguments.dropFirst()), service: service)
            await service.disconnect()
            exit(code)
        }

        // schema-diff：比较两个快照并生成同步脚本。**不需要数据库连接**，走离线文件。
        if arguments.first == "schema-diff" {
            exit(runSchemaDiffCommand(arguments: Array(arguments.dropFirst())))
        }

        // row-edit：结果集内联编辑（FR-DATA-04）。默认**只预览 DML**，`--apply` 才真写库。
        if arguments.first == "row-edit" {
            let code = await runRowEditCommand(arguments: Array(arguments.dropFirst()), service: service)
            await service.disconnect()
            exit(code)
        }

        // search-objects：全库对象搜索（FR-META-12）。一次元数据查询 + 客户端匹配。
        if arguments.first == "search-objects" {
            let code = await runObjectSearchCommand(
                arguments: Array(arguments.dropFirst()),
                service: service
            )
            await service.disconnect()
            exit(code)
        }

        // import：CSV / JSON 导入（FR-IO-03）。默认**只做映射与预检、打印语句**，`--write` 才真写库。
        if arguments.first == "import" {
            let code = await runImportCommand(
                arguments: Array(arguments.dropFirst()),
                service: service
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

        // 查询参数（FR-EXEC-17）：`--param name=value[:type]`，类型缺省为 text。
        // 绑定发生在**执行之前**，且只替换代码区的占位符（字符串 / 注释里的不动）。
        var boundSQL = sql
        let rawParams = Self.parameterFlags(arguments: arguments)
        if !rawParams.isEmpty {
            var values: [String: (type: SQLParameters.ValueType, raw: String)] = [:]
            for entry in rawParams {
                values[entry.name] = (entry.type, entry.value)
            }
            switch SQLParameters.bind(sql: sql, values: values) {
            case .success(let bound):
                boundSQL = bound.sql
                if !bound.unusedNames.isEmpty {
                    print("提示：这些参数没有在 SQL 里用到 —— \(bound.unusedNames.joined(separator: "、"))")
                }
            case .failure(let error):
                print("参数绑定失败：\(error.localizedDescription)")
                exit(70)
            }
        } else if SQLParameters.hasParameters(sql) {
            let names = SQLParameters.extract(from: sql).map(\.identifier)
            print("这条 SQL 需要参数，但没有提供：\(names.joined(separator: "、"))")
            print("用法：--param 名字=值[:text|number|boolean|null]")
            exit(70)
        }

        print("SQL：")
        print(boundSQL)
        print("")

        // --cancel-after <秒>：用于验证服务端取消（FR-EXEC-08）。
        let cancelDelay = Self.cancelDelay(arguments: arguments)

        do {
            // CLI 也走**句柄化**取消：`--cancel-after` 验证的正是"停止能不能下发到服务端"，
            // 拿不到句柄就没法定向，也就验证不了这条契约。
            let handle = ExecutionHandle()
            let stream = service.execute(boundSQL, options: .default, handle: handle)

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

    /// 整表导出的 `SELECT`：不手写 SQL 也能导整张表（FR-IO-02）。
    ///
    /// 排序不指定 —— 大表上 `ORDER BY` 会让服务端先排完再吐，反而更慢也更吃内存。
    static func tableSelect(_ table: String, schema: String?, dialect: PostgresDialect) -> String {
        "SELECT * FROM " + SQLGenerator.qualifiedName(table: table, schema: schema, dialect: dialect)
    }

    /// 整库导出：把 schema 下每张表各导出一个文件。
    ///
    /// 逐表串行（不并发）：客户端与数据库的连接是共享的，并发导出只会互相抢带宽，
    /// 还会让"导出到哪一步了"变得难说清。
    static func exportAllTables(
        schema: String?,
        directory: String,
        formatName: String,
        fetchSize: Int,
        service: any DatabaseService,
        dialect: PostgresDialect,
        encoding: ResultExportEncoding = .utf8
    ) async -> Int32 {
        let schemaName = schema ?? "public"
        let listSQL = """
        SELECT table_name FROM information_schema.tables
        WHERE table_schema = '\(schemaName.replacingOccurrences(of: "'", with: "''"))'
          AND table_type = 'BASE TABLE'
        ORDER BY table_name
        """
        var tables: [String] = []
        do {
            for try await event in service.execute(listSQL, options: .default) {
                if case .resultSet(let result) = event {
                    tables = result.rows.compactMap { $0.first ?? nil }.filter { !$0.isEmpty }
                }
            }
        } catch {
            print("列出表失败：\(error.localizedDescription)")
            return 66
        }
        guard !tables.isEmpty else {
            print("\(schemaName) 下没有表可导出")
            return 66
        }

        let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            print("创建目录失败：\(error.localizedDescription)")
            return 66
        }

        let ext: String
        switch formatName.lowercased() {
        case "json": ext = "json"
        case "tsv": ext = "tsv"
        case "markdown", "md": ext = "md"
        case "insert", "sql": ext = "sql"
        default: ext = "csv"
        }

        print("整库导出：\(schemaName) 下 \(tables.count) 张表 → \(directoryURL.path)")
        var failures = 0
        for table in tables {
            let file = directoryURL.appendingPathComponent("\(table).\(ext)")
            let code = await exportQueryToFile(
                query: tableSelect(table, schema: schema, dialect: dialect),
                outputPath: file.path,
                formatName: formatName,
                fetchSize: fetchSize,
                tableName: table,
                service: service,
                dialect: dialect,
                quiet: false,
                encoding: encoding
            )
            if code != 0 { failures += 1 }
        }

        if failures > 0 {
            print("完成但有 \(failures) 张表导出失败")
            return 68
        }
        print("整库导出完成：\(tables.count) 张表")
        return 0
    }

    /// `slow-queries [--sort total|mean|calls] [--limit N] [--json]`
    private static func runSlowQueriesCommand(
        arguments: [String],
        service: any DatabaseService,
        serverInfo: ServerInfo
    ) async -> Int32 {
        func value(for flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        let sort: SlowQueryReport.Sort
        switch (value(for: "--sort") ?? "total").lowercased() {
        case "total", "total_time", "totalTime".lowercased(): sort = .totalTime
        case "mean", "mean_time", "meanTime".lowercased(): sort = .meanTime
        case "calls": sort = .calls
        default:
            print("--sort 只支持 total / mean / calls")
            return 64
        }
        let limit = Int(value(for: "--limit") ?? "") ?? 20

        /// 执行一条语句取最后结果集。
        func run(_ sql: String) async throws -> QueryResult {
            var last: QueryResult?
            for try await event in service.execute(sql, options: .default) {
                if case .resultSet(let result) = event { last = result }
            }
            return last ?? QueryResult(columns: [], rows: [], affectedRows: nil,
                                       executionTime: 0, isTruncated: false, truncationLimit: nil)
        }

        do {
            // 先查扩展：没装是很常见的状态，要给"怎么装"而不是原始报错。
            let check = try await run(SlowQueryReport.extensionCheckQuery)
            guard SlowQueryReport.isExtensionInstalled(check) else {
                print(SlowQueryReport.missingExtensionMessage)
                return 3   // 与"查询失败"区分开的退出码：环境不具备 ≠ 命令写错
            }

            // `ServerInfo.version` 是原始字符串（如 `16.2`）→ 用方言解析出主版本，
            // 排行查询要按它决定列名（PG 13 起 `total_time` 改名为 `total_exec_time`）。
            let serverVersion = PostgresDialect().parseServerVersion(serverInfo.version)
            let sql = SlowQueryReport.query(sort: sort, limit: limit, serverMajor: serverVersion.major)
            let result = try await run(sql)
            let entries = SlowQueryReport.entries(from: result)

            if arguments.contains("--json") {
                let payload = entries.map { entry -> [String: Any] in
                    ["query": entry.query, "calls": entry.calls, "totalMillis": entry.totalMillis,
                     "meanMillis": entry.meanMillis, "rows": entry.rows]
                }
                if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
                   let text = String(data: data, encoding: .utf8) {
                    print(text)
                    return 0
                }
            }

            print("慢查询排行（按\(sort.displayName)，前 \(entries.count) 条，服务端 \(serverInfo.version)）")
            for (index, entry) in entries.enumerated() {
                let position = String(format: "%2d", index + 1)
                print("\(position). 调用 \(entry.calls) 次 · 总 \(SlowQueryReport.formatDuration(millis: entry.totalMillis))"
                      + " · 平均 \(SlowQueryReport.formatDuration(millis: entry.meanMillis)) · 返回 \(entry.rows) 行")
                print("    \(entry.display())")
            }
            return entries.isEmpty ? 1 : 0
        } catch {
            print("读取慢查询失败：\(error.localizedDescription)")
            return 67
        }
    }

    /// `row --table <表> [--schema S] --where "id = 1" [--limit 1] [--json]`
    ///
    /// 竖排输出（`列名 | 类型 | 值摘要` + 值正文），长 JSON 会自动美化、二进制给摘要。
    /// `--json` 输出结构化结果，便于脚本断言。
    private static func runRowCommand(
        arguments: [String],
        service: any DatabaseService
    ) async -> Int32 {
        func value(for flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        guard let table = value(for: "--table") else {
            print("用法：row --table <表> [--schema S] --where \"条件\" [--limit N] [--json]")
            return 64
        }
        let schema = value(for: "--schema")
        let whereClause = value(for: "--where")
        let limit = Int(value(for: "--limit") ?? "") ?? 1

        let target = SQLGenerator.qualifiedName(table: table, schema: schema, dialect: PostgresDialect())
        var sql = "SELECT * FROM \(target)"
        if let whereClause, !whereClause.isEmpty {
            // 条件原样拼入（与"按条件浏览"同一纪律）：**含分号一律拒绝**，不做聪明改写。
            guard !whereClause.contains(";") else {
                print("--where 里不能有分号（只允许单条表达式）")
                return 64
            }
            sql += " WHERE \(whereClause)"
        }
        sql += " LIMIT \(max(1, limit));"

        do {
            var result: QueryResult?
            for try await event in service.execute(sql, options: .default) {
                if case .resultSet(let value) = event { result = value }
            }
            guard let result else {
                print("没有取到结果集")
                return 66
            }
            guard let firstRow = result.rows.first else {
                print("没有匹配的行")
                return 1
            }

            let fields = CellInspector.row(columns: result.columns, row: firstRow)
            if arguments.contains("--json") {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let payload = fields.map { ["column": $0.columnName, "type": $0.typeName,
                                            "summary": $0.value.summary(language: .simplifiedChinese), "value": $0.value.display] }
                if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
                   let text = String(data: data, encoding: .utf8) {
                    print(text)
                    return 0
                }
            }

            print("行详情（\(fields.count) 列）：")
            for field in fields {
                print("  \(field.columnName) [\(field.typeName)]：\(field.value.summary)")
                if field.value.shape != .null && !field.value.display.isEmpty {
                    for line in field.value.display.split(separator: "\n") {
                        print("      \(line)")
                    }
                }
            }
            return 0
        } catch {
            print("读取行失败：\(error.localizedDescription)")
            return 67
        }
    }

    /// `archive-add --dir <目录> --sql "…" --connection 名 [--database 名] [--runs N] [--at ISO8601]`
    private static func runArchiveAddCommand(arguments: [String]) -> Int32 {
        func value(for flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
                return nil
            }
            return arguments[index + 1]
        }

        guard let directory = value(for: "--dir"),
              let sql = value(for: "--sql"),
              let connection = value(for: "--connection")
        else {
            print("用法：archive-add --dir <目录> --sql \"…\" --connection 名 [--database 名] [--runs N] [--at ISO8601]")
            return 64
        }

        let formatter = ISO8601DateFormatter()
        let date = value(for: "--at").flatMap { formatter.date(from: $0) } ?? Date()
        let entry = SQLArchiveEntry(
            sql: sql,
            firstExecutedAt: date,
            lastExecutedAt: date,
            runCount: Int(value(for: "--runs") ?? "1") ?? 1,
            connection: connection,
            database: value(for: "--database") ?? "app"
        )

        do {
            let store = SQLArchiveStore(directory: URL(fileURLWithPath: directory))
            let total = try store.append(entry, on: date)
            print("已追加归档记录（当天累计 \(total) 条）")
            return 0
        } catch {
            print("写入归档失败：\(error.localizedDescription)")
            return 66
        }
    }

    /// `memory --dir <归档目录> [--prefix "SELECT * FROM o"] [--connection 名] [--json]`
    ///
    /// 不带 `--prefix` 时列出记忆概览（骨架 / 次数 / 跨天 / 连接）。
    /// `specs`：任务定义的版本化、diff、回滚与重跑语义（FR-AI-11）。
    ///
    /// 保存走 `DataTaskStore.save` —— 版本化挂在那里（唯一收口点），所以这条命令
    /// 与界面改定义走的是**同一条历史**。
    /// 把命令行里的外观偏好写法解成枚举（宽容：`follow` / `system` 都认）。
    private static func terminalAppearance(from raw: String?) -> TerminalAppearance {
        guard let raw = raw?.lowercased() else { return .followSystem }
        switch raw {
        case "follow", "followsystem", "system", "auto": return .followSystem
        case "dark", "alwaysdark": return .alwaysDark
        case "light", "alwayslight": return .alwaysLight
        default: return .followSystem
        }
    }

    /// `terminal-modes [--json] [--feed <转义串>]`
    ///
    /// 不带参数：打印各模式的**编码对照表**（鼠标按下 / 松开 / 拖动 / 滚轮、两种编码；
    /// **鼠标路由**（本机 / 转发，含 ⌥ 与右键的反向规则）；DECCKM 两种键序；四类查询应答）。
    /// 带 `--feed`：把这段字节喂进真实的屏幕模型，打印**模式位与回给 PTY 的字节** ——
    /// 也就是说，验的是解析器而不是纯函数（两者都要对）。
    /// `tunnel --ssh-host <h> [--ssh-port 22] --ssh-user <u> [--ssh-agent | --ssh-key <path> | --ssh-password <口令>]
    ///         --target-host <h> --target-port <p> [--local-port <n>] [--hold <秒>] [--json]`
    ///
    /// 行为：起隧道 → 打印本地端点 → 保持（默认到被信号打断；给了 `--hold` 就等这么多秒）→ 收干净。
    /// 退出码：0 成功；2 参数不对；1 隧道起不来（stderr 带 ssh 的输出，已脱敏）。
    /// `doyah mcp serve | call`：MCP 两个方向的可脚本化出口（FR-AI-10）。
    ///
    /// - `serve`：我们**当 server**，从 stdin 读 JSON-RPC 行、往 stdout 写回复。
    ///   能力**继承当前会话**（用环境变量里的 PG* 连一次；没连上就只给元数据类工具，其余如实拒），
    ///   写操作要预先用 `--allow <工具名>` 放行（等价于界面上点过一次"允许"），每一次调用都进审计。
    /// - `call`：我们**当 host**，起一个外部 MCP 服务器进程，走"握手 → 列工具 → 调工具"最小闭环。
    ///   批处理式：把请求一次写完、关掉 stdin、读回全部回复（真实服务器在 stdin 关闭后会退出）。
    private static func runMCPCommand(arguments: [String]) async -> Int32 {
        func value(for flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let mode = arguments.first else {
            FileHandle.standardError.write(Data(("用法：mcp serve [--read-only] [--approve-write <SQL>] [--approve-call <工具名>|<JSON>] [--audit <文件>]\n"
                + "      mcp call --command <外部服务器命令> [--tool <工具名>] [--args <JSON>]\n").utf8))
            return 2
        }
        switch mode {
        case "serve": return await runMCPServe(arguments: Array(arguments.dropFirst()))
        case "call": return await runMCPCall(arguments: Array(arguments.dropFirst()))
        case "pending": return runMCPPending(arguments: Array(arguments.dropFirst()))
        case "decide": return runMCPDecide(arguments: Array(arguments.dropFirst()))
        default:
            FileHandle.standardError.write(Data("mcp 只支持 serve / call / pending / decide\n".utf8))
            return 2
        }
    }

    /// `doyah mcp pending`：列出待审批的外部调用（界面面板与脚本都看这一份）。
    private static func runMCPPending(arguments: [String]) -> Int32 {
        func value(for flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        let queue = value(for: "--approval-queue").map { MCPApprovalStore(directory: URL(fileURLWithPath: $0)) }
            ?? MCPApprovalStore.defaultStore()
        do {
            let pending = try queue.pending()
            if arguments.contains("--json") {
                let items = pending.map { request in
                    "{\"id\":\(jsonQuoted(request.id)),\"client\":\(jsonQuoted(request.client)),"
                        + "\"tool\":\(jsonQuoted(request.tool)),\"sql\":\(request.sql.map(jsonQuoted) ?? "null")}"
                }
                print("{\"pending\":[" + items.joined(separator: ",") + "]}")
            } else if pending.isEmpty {
                print("没有待审批的外部调用")
            } else {
                for request in pending {
                    print("\(request.id)  \(request.client) → \(request.tool)")
                    if let sql = request.sql { print("    SQL: \(sql)") }
                    print("    理由: \(request.reason)")
                }
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("读审批队列失败：\(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    /// `doyah mcp decide <id> --allow|--deny`：写一条决定（等价于界面上点一下）。
    private static func runMCPDecide(arguments: [String]) -> Int32 {
        func value(for flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        let positional = arguments.filter { !$0.hasPrefix("--") }
        // 第一个位置参数可能是 `decide` 之后的 id；`--approval-queue` 的值也要排除。
        let queuePath = value(for: "--approval-queue")
        let candidates = positional.filter { $0 != queuePath }
        guard let requestID = candidates.first else {
            FileHandle.standardError.write(Data("用法：mcp decide <请求 id> --allow|--deny [--approval-queue <目录>]\n".utf8))
            return 2
        }
        let approved = arguments.contains("--allow")
        guard approved || arguments.contains("--deny") else {
            FileHandle.standardError.write(Data("要明确写 --allow 或 --deny（没有默认：不确认就不放行）\n".utf8))
            return 2
        }
        let queue = queuePath.map { MCPApprovalStore(directory: URL(fileURLWithPath: $0)) }
            ?? MCPApprovalStore.defaultStore()
        do {
            try queue.decide(requestID: requestID, approved: approved)
            print(approved ? "已允许 \(requestID)" : "已拒绝 \(requestID)")
            return 0
        } catch {
            FileHandle.standardError.write(Data("写决定失败：\(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    private static func runMCPServe(arguments: [String]) async -> Int32 {
        func value(for flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        let isReadOnly = arguments.contains("--read-only")
        // **按次批准**：`--approve-write <SQL>` 只放行这一条语句；
        // `--approve-call <工具名>|<JSON 参数>` 放行其它工具的一次具体调用。
        // 不再有"按工具名全放行"的开关 —— 那等于把逐次审批变成一次总批准（脚本实测抓到过）。
        var approvedCalls: Set<String> = []
        if let sql = value(for: "--approve-write") {
            approvedCalls.insert(
                MCPToolCatalog.callFingerprint(
                    tool: MCPToolCatalog.querySQL,
                    arguments: .object(["sql": .string(sql)])
                )
            )
        }
        if let call = value(for: "--approve-call") {
            let parts = call.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2,
               let data = String(parts[1]).data(using: .utf8),
               let raw = try? JSONSerialization.jsonObject(with: data) {
                approvedCalls.insert(
                    MCPToolCatalog.callFingerprint(tool: String(parts[0]), arguments: MCPValue(any: raw))
                )
            } else {
                FileHandle.standardError.write(Data("--approve-call 需要 <工具名>|<JSON 参数>\n".utf8))
                return 2
            }
        }
        let auditPath = value(for: "--audit")
        // 界面审批通道（FR-AI-10 的界面那一半）：需要审批的调用**入队并等**，
        // 由界面（或 `doyah mcp decide`）写决定。没配队列时保持"直接拒绝"的老行为。
        let approvalQueue: MCPApprovalStore? = value(for: "--approval-queue").map {
            MCPApprovalStore(directory: URL(fileURLWithPath: $0))
        } ?? (arguments.contains("--app-approval") ? MCPApprovalStore.defaultStore() : nil)
        let approvalTimeout = TimeInterval(value(for: "--approval-timeout") ?? "120") ?? 120

        // 当前会话：环境变量里的连接。**连不上就不另开连接**，能力如实降级。
        var service: PostgresService?
        var capabilities = MCPServerSession.Capabilities(
            hasConnection: false,
            isReadOnly: isReadOnly,
            target: "(未连接)",
            approvedCalls: approvedCalls
        )
        let environment = ProcessInfo.processInfo.environment
        if environment["PGHOST"] != nil || environment["PGUSER"] != nil {
            let config = makeEnvironmentConfig(name: "CLI mcp")
            let created = PostgresService(config: config, password: environment["PGPASSWORD"])
            do {
                let info = try await created.connect()
                service = created
                capabilities = MCPServerSession.Capabilities(
                    hasConnection: true,
                    isReadOnly: isReadOnly,
                    target: "\(config.username)@\(config.host):\(config.port)/\(info.database)",
                    approvedCalls: approvedCalls
                )
            } catch {
                FileHandle.standardError.write(Data("（连接失败，能力降级为仅元数据）：\(error.localizedDescription)\n".utf8))
            }
        }

        var session = MCPServerSession(capabilities: capabilities)
        func audit(_ entry: MCPAuditEntry) {
            FileHandle.standardError.write(Data(("审计 \(entry.jsonText)\n").utf8))
            guard let auditPath else { return }
            if let handle = FileHandle(forWritingAtPath: auditPath) {
                handle.seekToEndOfFile()
                handle.write(Data((entry.jsonText + "\n").utf8))
                try? handle.close()
            } else {
                try? (entry.jsonText + "\n").write(toFile: auditPath, atomically: true, encoding: .utf8)
            }
        }

        while let line = readLine(strippingNewline: true) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let outcome = session.handle(line: line)
            // 配了审批队列时，"需要审批"的那一条**先不回**：等界面点完再回**唯一一个**回复。
            // （一个请求回两个响应会违反 JSON-RPC，而且客户端会先收到"需要审批"、
            //   后面真正的结果被当成多余报文丢掉 —— 脚本第一版就是这么把它抓出来的。）
            let needsApproval = session.audit.last?.outcome == "needs-approval"
            let deferToApprovalQueue = approvalQueue != nil && needsApproval
            if !deferToApprovalQueue {
                for reply in outcome.replies {
                    print(reply.encode())
                    fflush(stdout)
                }
            }
            if let last = session.audit.last { audit(last) }

            guard let invocation = outcome.invocation else {
                // 需要审批的调用：入队、等人点、再决定。
                if let approvalQueue, deferToApprovalQueue {
                    if let approved = await waitForApproval(
                        queue: approvalQueue,
                        client: session.clientName,
                        invocation: pendingInvocation(from: line),
                        timeout: approvalTimeout,
                        audit: audit
                    ) {
                        if approved {
                            let result = await runMCPInvocation(
                                pendingInvocation(from: line), service: service, config: makeEnvironmentConfig(name: "CLI mcp")
                            )
                            if let reply = session.finish(
                                pendingInvocation(from: line), text: result.text, isError: result.isError
                            ) {
                                print(reply.encode())
                                fflush(stdout)
                            }
                            if let last = session.audit.last { audit(last) }
                        } else {
                            // 拒绝 / 超时：**如实回一个错误内容**，不是静默不响应。
                            let text = LocalizedStrings.text(.mcpApprovalDenied, language: .simplifiedChinese)
                            if let reply = session.finish(pendingInvocation(from: line), text: text, isError: true) {
                                print(reply.encode())
                                fflush(stdout)
                            }
                            if let last = session.audit.last { audit(last) }
                        }
                    }
                }
                continue
            }
            let result = await runMCPInvocation(invocation, service: service, config: makeEnvironmentConfig(name: "CLI mcp"))
            if let reply = session.finish(invocation, text: result.text, isError: result.isError) {
                print(reply.encode())
                fflush(stdout)
            }
            if let last = session.audit.last { audit(last) }
        }
        await service?.disconnect()
        return 0
    }

    /// 从客户端报文里取出工具名与参数（"需要审批"的那一次）。
    private static func pendingInvocation(from line: String) -> MCPServerSession.Invocation {
        guard case .success(.request(let id, _, let params)) = MCPMessage.decode(line) else {
            return MCPServerSession.Invocation(tool: "", arguments: .object([:]), requestID: nil)
        }
        return MCPServerSession.Invocation(
            tool: params["name"]?.stringValue ?? "",
            arguments: params["arguments"] ?? .object([:]),
            requestID: id
        )
    }

    /// 入队等人点：轮询决定文件，直到有决定或超时。
    /// 超时**返回拒绝**（`false`）而不是"当作同意" —— 无人确认时默认不放行。
    private static func waitForApproval(
        queue: MCPApprovalStore,
        client: String,
        invocation: MCPServerSession.Invocation,
        timeout: TimeInterval,
        audit: (MCPAuditEntry) -> Void
    ) async -> Bool? {
        let fingerprint = MCPToolCatalog.callFingerprint(tool: invocation.tool, arguments: invocation.arguments)
        let sql = invocation.arguments["sql"]?.stringValue
        let tool = MCPToolCatalog.tool(named: invocation.tool)
        let reason = tool.map {
            LocalizedStrings.format(.mcpNeedsApproval, language: .simplifiedChinese, $0.name)
        } ?? "需要审批"
        do {
            let request = try queue.enqueue(
                client: client,
                tool: invocation.tool,
                argumentsSummary: invocation.arguments.jsonText,
                fingerprint: fingerprint,
                sql: sql,
                reason: reason
            )
            FileHandle.standardError.write(Data("待审批：\(request.id)（\(invocation.tool)）—— 在界面上点允许 / 拒绝\n".utf8))
            audit(MCPAuditEntry(client: client, tool: invocation.tool, argumentsSummary: "queued", outcome: "waiting-approval"))
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let decision = try queue.decision(for: request.id) {
                    audit(
                        MCPAuditEntry(
                            client: client,
                            tool: invocation.tool,
                            argumentsSummary: invocation.arguments.jsonText,
                            outcome: decision ? "approved-by-user" : "denied-by-user"
                        )
                    )
                    return decision
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            audit(MCPAuditEntry(client: client, tool: invocation.tool, argumentsSummary: "timeout", outcome: "approval-timeout"))
            return false
        } catch {
            FileHandle.standardError.write(Data("审批队列不可用：\(error.localizedDescription)\n".utf8))
            return false
        }
    }

    /// 执行一次工具调用（会话只决定"能不能"，执行在这里）。
    private static func runMCPInvocation(
        _ invocation: MCPServerSession.Invocation,
        service: PostgresService?,
        config: ConnectionConfig
    ) async -> (text: String, isError: Bool) {
        guard let service else {
            return ("当前没有已连接的会话：外部调用一律不另开连接", true)
        }
        let arguments = invocation.arguments
        switch invocation.tool {
        case MCPToolCatalog.querySQL:
            guard let sql = arguments["sql"]?.stringValue else {
                return ("缺少参数 sql", true)
            }
            return await runMCPQuery(service: service, sql: sql)

        case MCPToolCatalog.listObjects:
            let dialect = PostgresDialect()
            let metadata = MetadataService(service: service, dialect: dialect, databaseName: config.database, serverLabel: config.host)
            do {
                let databases = try await metadata.loadChildren(
                    of: DatabaseObject(id: "server", name: config.host, kind: DatabaseObject.Kind.server)
                )
                var lines: [String] = []
                for database in databases.prefix(20) {
                    lines.append(database.name)
                }
                return (lines.joined(separator: "\n"), false)
            } catch {
                return (error.localizedDescription, true)
            }

        case MCPToolCatalog.describeTable:
            guard let table = arguments["table"]?.stringValue else {
                return ("缺少参数 table", true)
            }
            let sql = PostgresDialect().listColumnsQuery(table: table, schema: arguments["schema"]?.stringValue)
            return await runMCPQuery(service: service, sql: sql)

        case MCPToolCatalog.exportResult:
            guard let sql = arguments["sql"]?.stringValue, let path = arguments["path"]?.stringValue else {
                return ("缺少参数 sql / path", true)
            }
            let result = await runMCPQuery(service: service, sql: sql)
            guard !result.isError else { return result }
            do {
                try result.text.write(toFile: path, atomically: true, encoding: .utf8)
                let rows = result.text.split(separator: "\n").count
                return ("已导出 \(rows) 行到 \(path)", false)
            } catch {
                return ("写文件失败：\(error.localizedDescription)", true)
            }

        default:
            return ("没有暴露这个工具：\(invocation.tool)", true)
        }
    }

    private static func runMCPQuery(service: PostgresService, sql: String) async -> (text: String, isError: Bool) {
        do {
            var lines: [String] = []
            for try await event in service.execute(sql, options: .default) {
                if case .resultSet(let result) = event {
                    if !result.columns.isEmpty {
                        lines.append(result.columns.map(\.name).joined(separator: "\t"))
                    }
                    for row in result.rows {
                        lines.append(row.map { $0 ?? "NULL" }.joined(separator: "\t"))
                    }
                    if let affected = result.affectedRows {
                        lines.append("影响行数：\(affected)")
                    }
                }
            }
            return (lines.isEmpty ? "（没有结果）" : lines.joined(separator: "\n"), false)
        } catch {
            return (error.localizedDescription, true)
        }
    }

    private static func runMCPCall(arguments: [String]) async -> Int32 {
        func value(for flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let command = value(for: "--command") else {
            FileHandle.standardError.write(Data("用法：mcp call --command <外部服务器命令> [--tool <工具名>] [--args <JSON>]\n".utf8))
            return 2
        }

        var client = MCPClientSession()
        let initialize = client.initializeRequest()
        let initialized = MCPMessage.notification(method: "notifications/initialized", params: .object([:]))
        let list = client.toolsListRequest()

        var outbound = [initialize.encode(), initialized.encode(), list.encode()]
        if let tool = value(for: "--tool") {
            let argsText = value(for: "--args") ?? "{}"
            let args: MCPValue
            if let data = argsText.data(using: .utf8),
               let raw = try? JSONSerialization.jsonObject(with: data) {
                args = MCPValue(any: raw)
            } else {
                FileHandle.standardError.write(Data("--args 不是合法 JSON\n".utf8))
                return 2
            }
            outbound.append(client.toolsCallRequest(tool: tool, arguments: args).encode())
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data("起不来外部服务器：\(error.localizedDescription)\n".utf8))
            return 1
        }
        stdinPipe.fileHandleForWriting.write(Data((outbound.joined(separator: "\n") + "\n").utf8))
        try? stdinPipe.fileHandleForWriting.close()

        let output = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errors = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(decoding: output, as: UTF8.self)
        for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            client.receive(line: String(line))
        }
        if let errorText = String(data: errors, encoding: .utf8), !errorText.isEmpty {
            FileHandle.standardError.write(Data(errorText.utf8))
        }

        print("server=\(client.serverName) protocol=\(client.protocolVersion)")
        print("tools=" + client.tools.map(\.name).joined(separator: ","))
        if let result = client.lastResult { print("result=\(result)") }
        if let error = client.lastError { print("error=\(error)") }
        return client.hasError() ? 1 : 0
    }

    /// `doyah maintain`：维护任务编排的可脚本化出口。
    ///
    /// 三段分开，**没有"跳过审批直接跑"的开关**：
    ///   ① 解析 + 审阅（默认只打印计划与每条的理由）；
    ///   ② `--approve m1,m3` 或 `--approve all` 才把任务置为已批准；
    ///   ③ `--execute` 才真的下发（且只下发"已批准"的那些）。
    ///
    /// 为什么把"批准"和"执行"拆成两个开关：需求原文要求「逐次审批」「可预览、可编辑、可拒绝」——
    /// 一个开关就把这三件事糊在一起，用户没法拒绝其中一条。
    private static func runMaintainCommand(arguments: [String]) async -> Int32 {
        func value(for flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        guard let path = value(for: "--plan") else {
            FileHandle.standardError.write(Data(("用法：maintain --plan <计划文件> [--approve all|m1,m3] "
                + "[--reject m2] [--execute] [--read-only] [--sandboxed] "
                + "[--allow-multiple-high-cost] [--json]\n").utf8))
            return 2
        }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            FileHandle.standardError.write(Data("读不到计划文件：\(path)\n".utf8))
            return 2
        }

        let isJSON = arguments.contains("--json")
        let policy = MaintenancePolicy(
            allowMultipleHighCost: arguments.contains("--allow-multiple-high-cost"),
            isReadOnly: arguments.contains("--read-only"),
            isSandboxed: arguments.contains("--sandboxed")
        )
        var review = MaintenancePlanner.makePlan(from: text, policy: policy)

        if let rejectList = value(for: "--reject") {
            review = MaintenancePlanner.reject(review, ids: splitIDs(rejectList))
        }
        if let approveList = value(for: "--approve") {
            let ids: [String]? = approveList.lowercased() == "all" ? nil : splitIDs(approveList)
            review = MaintenancePlanner.approve(review, ids: ids)
        }

        var executed: [(id: String, ok: Bool, detail: String)] = []
        if arguments.contains("--execute") {
            let service = PostgresService(config: makeEnvironmentConfig(name: "CLI maintain"), password: ProcessInfo.processInfo.environment["PGPASSWORD"])
            do {
                _ = try await service.connect()
            } catch {
                if isJSON {
                    print("{\"ok\":false,\"error\":\(jsonQuoted(error.localizedDescription))}")
                } else {
                    print("连接失败：\(error.localizedDescription)")
                }
                return 1
            }
            for task in review.executableTasks(isSandboxed: policy.isSandboxed) {
                guard let sql = task.sql else { continue }
                do {
                    for try await event in service.execute(sql, options: .default) {
                        if case .resultSet(let result) = event, let affected = result.affectedRows {
                            _ = affected
                        }
                    }
                    review = MaintenancePlanner.record(review, taskID: task.id)
                    executed.append((task.id, true, sql))
                } catch {
                    review = MaintenancePlanner.record(review, taskID: task.id, failureReason: error.localizedDescription)
                    executed.append((task.id, false, error.localizedDescription))
                }
            }
            await service.disconnect()
        }

        if isJSON {
            var json = "{"
            json += "\"ok\":true"
            json += ",\"tasks\":["
            json += review.tasks.map { task in
                let state: String
                switch task.state {
                case .pending: state = "pending"
                case .approved: state = "approved"
                case .rejected: state = "rejected"
                case .executed: state = "executed"
                case .failed: state = "failed"
                }
                let sql = task.sql.map(jsonQuoted) ?? "null"
                let command = task.command.map(jsonQuoted) ?? "null"
                return "{\"id\":\(jsonQuoted(task.id)),\"kind\":\(jsonQuoted(task.kind.rawValue)),"
                    + "\"summary\":\(jsonQuoted(task.summary)),\"risk\":\(jsonQuoted(task.risk.rawValue)),"
                    + "\"highCost\":\(task.isHighCost),\"needsApproval\":\(task.requiresApproval),"
                    + "\"state\":\(jsonQuoted(state)),\"sql\":\(sql),\"command\":\(command),"
                    + "\"executable\":\(task.isExecutable(isSandboxed: policy.isSandboxed)),"
                    + "\"notes\":[" + task.reviewNotes.map(jsonQuoted).joined(separator: ",") + "]}"
            }.joined(separator: ",")
            json += "],\"unparsable\":[" + review.unparsableLines.map(jsonQuoted).joined(separator: ",") + "]"
            json += ",\"planNotes\":[" + review.notes.map(jsonQuoted).joined(separator: ",") + "]"
            json += ",\"executed\":["
            json += executed.map { item in
                "{\"id\":\(jsonQuoted(item.id)),\"ok\":\(item.ok),\"detail\":\(jsonQuoted(item.detail))}"
            }.joined(separator: ",")
            json += "]}"
            print(json)
        } else {
            print("== 计划（\(review.tasks.count) 条）==")
            for task in review.tasks {
                let state: String
                switch task.state {
                case .pending: state = "待批"
                case .approved: state = "已批准"
                case .rejected: state = "已拒绝"
                case .executed: state = "已执行"
                case .failed(let reason): state = "失败（\(reason)）"
                }
                print("\(task.id) [\(task.kind.rawValue)] \(state) — \(task.summary)")
                if let sql = task.sql { print("    SQL: \(sql)") }
                if let command = task.command { print("    命令: \(command)") }
                for note in task.reviewNotes { print("    · \(note)") }
            }
            for line in review.unparsableLines { print("✗ 没看懂：\(line)") }
            for note in review.notes { print("· \(note)") }
            for item in executed {
                print(item.ok ? "✅ \(item.id) 已执行" : "❌ \(item.id) 失败：\(item.detail)")
            }
        }
        return 0
    }

    private static func splitIDs(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 按**已保存连接的名字**取配置与口令（FR-CONN-02 + NFR-SEC-01 的脚本化用法）。
    ///
    /// 为什么要有它：口令最安全的传递方式不是"命令行参数"也不是"贴进聊天"，而是
    /// **在界面上输入一次、存进本机凭据库**，脚本按名字取用。于是：
    ///   · 仓库里没有口令、命令行历史里没有口令、脚本里没有口令；
    ///   · 界面上的"测试连接"与脚本连的是**同一份配置**（少一处漂移）。
    /// 取不到就如实返回 nil，由调用方给清楚的话（不静默回退到别的连接）。
    static func savedConnection(named name: String) async -> (config: ConnectionConfig, password: String?)? {
        let home = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = home.appendingPathComponent(DoyahIdentity.applicationSupportDirectoryName, isDirectory: true)
        let store = ConnectionStore(directoryURL: directory)
        guard let configs = try? await store.load(),
              let config = configs.first(where: { $0.name == name }) else {
            return nil
        }
        let password = (try? FileSecretStore().password(for: config.id)) ?? nil
        return (config, password)
    }

    /// 从环境变量造一份连接配置（与默认路径同一口径）。
    private static func makeEnvironmentConfig(name: String) -> ConnectionConfig {
        let environment = ProcessInfo.processInfo.environment
        return ConnectionConfig(
            name: name,
            dbType: .postgresql,
            host: environment["PGHOST"] ?? "127.0.0.1",
            port: Int(environment["PGPORT"] ?? "5432") ?? 5432,
            database: environment["PGDATABASE"] ?? "",
            username: environment["PGUSER"] ?? "postgres",
            sslMode: SSLMode(rawValue: environment["PGSSLMODE"] ?? "prefer") ?? .prefer,
            timeout: 10
        )
    }

    /// `doyah diagnose`：把"对话式诊断"里**可以离线验证的两段**做成命令行出口 ——
    /// ① 取证与上下文组装（对真实库跑 `EXPLAIN` / 锁查询 / 统计，如实标注哪些没拿到）；
    /// ② 解析模型回复（`--advice-file` 传入一份回复文本，据此验"无依据断言必须被拒"与建议 SQL 的审批裁决）。
    ///
    /// **为什么要有 ②**：真实模型端点在本环境不可用，但"结论必须有依据"这条纪律
    /// 是**我们这一侧的判决**，必须有可复跑的验证方式 —— 否则它只是一句写在文档里的话。
    private static func runDiagnoseCommand(arguments: [String]) async -> Int32 {
        func value(for flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        guard let sql = value(for: "--sql") else {
            FileHandle.standardError.write(Data(("用法：diagnose --sql <语句> [--question <问题>] "
                + "[--advice-file <模型回复文件>] [--read-only] [--json]\n").utf8))
            return 2
        }

        let isJSON = arguments.contains("--json")
        let question = value(for: "--question") ?? "这条查询为什么慢？"
        let dialect: any SQLDialect = PostgresDialect()

        let environment = ProcessInfo.processInfo.environment
        let host = environment["PGHOST"] ?? "127.0.0.1"
        let port = Int(environment["PGPORT"] ?? "5432") ?? 5432
        let username = environment["PGUSER"] ?? "postgres"
        let password = environment["PGPASSWORD"]
        let database = environment["PGDATABASE"] ?? ""
        let config = ConnectionConfig(
            name: "CLI diagnose",
            dbType: .postgresql,
            host: host,
            port: port,
            database: database,
            username: username,
            sslMode: SSLMode(rawValue: environment["PGSSLMODE"] ?? "prefer") ?? .prefer,
            timeout: 10
        )

        let service = PostgresService(config: config, password: password)
        do {
            let info = try await service.connect()
            var evidence: [DiagnosisEvidence] = []
            let plan = DiagnosisContextBuilder.evidencePlan(for: sql, dialect: dialect)
            for (index, item) in plan.enumerated() {
                let id = DiagnosisContextBuilder.evidenceID(index: index)
                if item.kind == .statement {
                    // 语句本身不是"跑出来的"证据，但它同样要有编号（模型要引用它）。
                    evidence.append(
                        DiagnosisContextBuilder.makeEvidence(
                            id: id, kind: .statement, sql: item.sql, rows: []
                        )
                    )
                    continue
                }
                do {
                    let rows = try await runDiagnoseQuery(service: service, sql: item.sql)
                    evidence.append(
                        DiagnosisContextBuilder.makeEvidence(
                            id: id, kind: item.kind, sql: item.sql, rows: rows
                        )
                    )
                } catch {
                    // 取不到就是取不到：把**服务端说的话**带上（"扩展没装"和"权限不够"要分得开）。
                    evidence.append(
                        DiagnosisContextBuilder.makeEvidence(
                            id: id, kind: item.kind, sql: item.sql, rows: nil,
                            failureReason: error.localizedDescription
                        )
                    )
                }
            }
            await service.disconnect()

            let context = DiagnosisContext(
                question: question,
                target: "\(username)@\(host):\(port)/\(database.isEmpty ? "<default>" : database)（\(info.version)）",
                evidence: evidence
            )

            var adviceReport: DiagnosisAdviceReport?
            if let path = value(for: "--advice-file") {
                guard let reply = try? String(contentsOfFile: path, encoding: .utf8) else {
                    FileHandle.standardError.write(Data("读不到模型回复文件：\(path)\n".utf8))
                    return 2
                }
                var policy = ExecutionSafetyPolicy(isEnabled: true)
                if arguments.contains("--read-only") { policy.isReadOnly = true }
                adviceReport = DiagnosisAdvice.parse(
                    reply: reply,
                    context: context,
                    databaseType: dialect.databaseType,
                    policy: policy
                )
            }

            if isJSON {
                var json = "{"
                json += "\"ok\":true"
                json += ",\"evidence\":["
                json += evidence.map { item in
                    let rows = item.rows.map { row in
                        "[" + row.map { jsonQuoted($0 ?? "NULL") }.joined(separator: ",") + "]"
                    }.joined(separator: ",")
                    return "{\"id\":\(jsonQuoted(item.id)),\"kind\":\(jsonQuoted(item.kind.displayName)),"
                        + "\"available\":\(item.isAvailable),\"truncated\":\(item.isTruncated),"
                        + "\"note\":\(jsonQuoted(item.note)),\"rows\":[\(rows)]}"
                }.joined(separator: ",")
                json += "]"
                json += ",\"unavailable\":["
                json += context.unavailable.map { jsonQuoted($0.id) }.joined(separator: ",")
                json += "]"
                if let adviceReport {
                    json += ",\"advice\":["
                    json += adviceReport.items.map { item in
                        let decision: String
                        switch item.decision {
                        case .allow: decision = "allow"
                        case .needsConfirmation: decision = "needsConfirmation"
                        case .refused: decision = "refused"
                        case nil: decision = "none"
                        }
                        let sql = item.suggestedSQL.map(jsonQuoted) ?? "null"
                        return "{\"conclusion\":\(jsonQuoted(item.conclusion)),"
                            + "\"citations\":[" + item.citations.map(jsonQuoted).joined(separator: ",") + "],"
                            + "\"sql\":\(sql),\"decision\":\(jsonQuoted(decision))}"
                    }.joined(separator: ",")
                    json += "],\"rejected\":["
                    json += adviceReport.rejections.map { rejection in
                        let reason: String
                        switch rejection.reason {
                        case .missingCitations: reason = "missingCitations"
                        case .unknownCitation(let id): reason = "unknownCitation:\(id)"
                        case .unparsable: reason = "unparsable"
                        }
                        return "{\"line\":\(jsonQuoted(rejection.line)),\"reason\":\(jsonQuoted(reason))}"
                    }.joined(separator: ",")
                    json += "]"
                }
                json += "}"
                print(json)
            } else {
                print(context.boundedPromptText())
                if let adviceReport {
                    print("")
                    print("== 解析结果 ==")
                    for item in adviceReport.items {
                        print("· \(item.conclusion)（依据 \(item.citations.joined(separator: ","))）")
                        if let suggested = item.suggestedSQL {
                            print("  建议：\(suggested)")
                        }
                    }
                    for rejection in adviceReport.rejections {
                        print("✗ 已拒绝：\(rejection.line)（\(rejection.reason)）")
                    }
                }
            }
            return 0
        } catch {
            if isJSON {
                print("{\"ok\":false,\"error\":\(jsonQuoted(error.localizedDescription))}")
            } else {
                print("取证失败：\(error.localizedDescription)")
            }
            return 1
        }
    }

    /// 跑一条取证查询，把行收成字符串（NULL 保持 nil，"没有值"与"空串"要分得开）。
    private static func runDiagnoseQuery(service: PostgresService, sql: String) async throws -> [[String?]] {
        var rows: [[String?]] = []
        for try await event in service.execute(sql, options: .default) {
            if case .resultSet(let result) = event {
                rows.append(contentsOf: result.rows)
            }
        }
        return rows
    }

    /// JSON 字符串字面量（含引号）。**不自己写转义表**：引号 / 反斜杠 / 控制字符的规则
    /// 写错一处就会产出别人解析不了的 JSON，交给 Foundation 最稳。
    private static func jsonQuoted(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        // JSONSerialization 给的是 `["…"]`，去掉外层的方括号就是单个字符串字面量。
        return String(text.dropFirst().dropLast())
    }

    /// `doyah mysql`：连一个 MySQL 库、可选跑一条查询，按人读或 JSON 输出。
    ///
    /// 存在的理由与 `tunnel` 一样：界面里"能不能连上"只能靠眼睛，**命令行能给出一条可断言的路径** ——
    /// 本机没有 MySQL 实例时，脚本用**假 MySQL 服务器**（真跑 MySQL 线协议）把整条链路验一遍。
    private static func runMySQLCommand(arguments: [String], defaultType: String = "mysql") async -> Int32 {
        func value(for flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        // `--connection <名字>`：host / port / user / 库 / 口令全部取自已保存的连接
        // （口令在界面上输过一次就够，脚本与命令历史里都不出现）。
        if let name = value(for: "--connection") {
            guard let saved = await savedConnection(named: name) else {
                FileHandle.standardError.write(Data("找不到名为 \(name) 的已保存连接（先在上面的界面里建一条）\n".utf8))
                return 2
            }
            guard saved.config.dbType == .mysql || saved.config.dbType == .gbase8a else {
                FileHandle.standardError.write(Data("连接 \(name) 的类型是 \(saved.config.dbType.displayName)，不是 MySQL 协议族\n".utf8))
                return 2
            }
            var arguments = arguments
            arguments.append(contentsOf: ["--host", saved.config.host])
            arguments.append(contentsOf: ["--port", String(saved.config.port)])
            arguments.append(contentsOf: ["--user", saved.config.username])
            arguments.append(contentsOf: ["--database", saved.config.database])
            if let password = saved.password, !password.isEmpty {
                arguments.append(contentsOf: ["--password", password])
            } else {
                // **取不到口令要说话**：以前是静默地按"没口令"去连，如果服务端其实要求口令，
                // 用户看到的会是认证失败或（更糟）一直等 —— 而真正该做的是先在界面上输一次口令。
                // 不直接退出：确实存在无口令的本地账号，所以只警告、继续。
                FileHandle.standardError.write(Data(
                    ("提示：连接 \(name) 没有已保存的口令。如果它需要口令，请先在界面上编辑该连接并输入一次（留空 = 不改动已存口令）。\n").utf8
                ))
            }
            return await runMySQLCommand(arguments: arguments)
        }

        guard let host = value(for: "--host"), let username = value(for: "--user") else {
            FileHandle.standardError.write(Data(("用法：mysql --connection <已保存连接名> 或 --host <h> [--port 3306] --user <u> "
                + "[--password <口令>] [--database <库>] [--ssl-mode disable|prefer|require] "
                + "[--sql <语句>] [--timeout 秒] [--json]\n").utf8))
            return 2
        }

        let port = Int(value(for: "--port") ?? "3306") ?? 3306
        let database = value(for: "--database") ?? ""
        let sslMode = SSLMode(rawValue: value(for: "--ssl-mode") ?? "prefer") ?? .prefer
        let isJSON = arguments.contains("--json")
        let typeName = value(for: "--type") ?? defaultType
        guard let dbType = DatabaseType(rawValue: typeName), dbType != .postgresql else {
            FileHandle.standardError.write(Data("--type 只支持 mysql / gbase8a\n".utf8))
            return 2
        }
        let config = ConnectionConfig(
            name: "\(dbType.displayName) CLI",
            dbType: dbType,
            host: host,
            port: port,
            database: database,
            username: username,
            sslMode: sslMode,
            timeout: Int(value(for: "--timeout") ?? "10") ?? 10
        )

        let service = DatabaseServiceFactory.make(for: config, password: value(for: "--password"))

        let info: ServerInfo
        do {
            info = try await service.connect()
        } catch {
            if isJSON {
                print("{\"ok\":false,\"error\":\(jsonQuoted(error.localizedDescription))}")
            } else {
                print("连接失败：\(error.localizedDescription)")
            }
            return 1
        }

        var resultRows: [[String]] = []
        var resultColumns: [String] = []
        var affected: Int?
        if let sql = value(for: "--sql") {
            do {
                var statements = 0
                for try await event in service.execute(sql, options: .default) {
                    switch event {
                    case .started:
                        statements += 1
                    case .resultSet(let result):
                        resultColumns = result.columns.map(\.name)
                        resultRows = result.rows.map { $0.map { $0 ?? "NULL" } }
                        affected = result.affectedRows
                    case .finished, .notice:
                        break
                    }
                }
                _ = statements
            } catch {
                if isJSON {
                    print("{\"ok\":false,\"error\":\(jsonQuoted(error.localizedDescription))}")
                } else {
                    print("执行失败：\(error.localizedDescription)")
                }
                await service.disconnect()
                return 1
            }
        }

        if isJSON {
            let columns = resultColumns.map(jsonQuoted).joined(separator: ",")
            let rows = resultRows.map { row in
                "[" + row.map(jsonQuoted).joined(separator: ",") + "]"
            }.joined(separator: ",")
            let affectedText = affected.map(String.init) ?? "null"
            var json = "{"
            json += "\"ok\":true"
            json += ",\"version\":\(jsonQuoted(info.version))"
            json += ",\"database\":\(jsonQuoted(info.database))"
            json += ",\"user\":\(jsonQuoted(info.user))"
            json += ",\"columns\":["
            json += columns
            json += "],\"rows\":["
            json += rows
            json += "],\"affectedRows\":\(affectedText)"
            json += "}"
            print(json)
        } else {
            print("连接成功")
            print("server_version: \(info.version)")
            print("database:       \(info.database)")
            print("user:           \(info.user)")
            if !resultColumns.isEmpty {
                print(resultColumns.joined(separator: "\t"))
                for row in resultRows {
                    print(row.joined(separator: "\t"))
                }
            }
            if let affected {
                print("影响行数：\(affected)")
            }
        }

        await service.disconnect()
        return 0
    }

    private static func runTunnelCommand(arguments: [String]) -> Int32 {
        func value(for flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        guard let sshHost = value(for: "--ssh-host"),
              let sshUser = value(for: "--ssh-user"),
              let targetHost = value(for: "--target-host"),
              let targetPortText = value(for: "--target-port"),
              let targetPort = Int(targetPortText) else {
            FileHandle.standardError.write(Data(("用法：tunnel --ssh-host <h> [--ssh-port 22] --ssh-user <u> "
                + "[--ssh-agent | --ssh-key <path> | --ssh-password <口令>] "
                + "--target-host <h> --target-port <p> [--local-port <n>] [--hold <秒>] [--json]\n").utf8))
            return 2
        }

        let authentication: SSHTunnelConfig.Authentication
        if arguments.contains("--ssh-agent") {
            authentication = .agent
        } else if let key = value(for: "--ssh-key") {
            authentication = .privateKey(path: key, isEncrypted: false)
        } else if value(for: "--ssh-password") != nil {
            authentication = .password
        } else {
            authentication = .agent
        }

        let config = SSHTunnelConfig(
            host: sshHost,
            port: Int(value(for: "--ssh-port") ?? "22") ?? 22,
            username: sshUser,
            authentication: authentication,
            hostKeyPolicy: arguments.contains("--strict-host-key") ? .strict : .acceptNew,
            connectTimeoutSeconds: Int(value(for: "--timeout") ?? "15") ?? 15
        )
        let issues = config.issues()
        guard issues.isEmpty else {
            FileHandle.standardError.write(Data("SSH 隧道配置不完整：\(issues)\n".utf8))
            return 2
        }

        guard let localPort = Int(value(for: "--local-port") ?? "") ?? freeLocalPort() else {
            FileHandle.standardError.write(Data("找不到空闲的本地端口\n".utf8))
            return 1
        }

        // known_hosts 放我们自己的目录：不动用户的 ~/.ssh/known_hosts（与 App 侧同一口径）。
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let knownHosts = base
            .appendingPathComponent(DoyahIdentity.applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("known_hosts", isDirectory: false)

        let tunnel = SSHTunnelProcess(
            config: config,
            target: SSHTunnelTarget(host: targetHost, port: targetPort),
            localPort: localPort,
            knownHostsPath: knownHosts.path,
            password: value(for: "--ssh-password"),
            executable: ProcessInfo.processInfo.environment["DOYAH_SSH_BINARY"] ?? "/usr/bin/ssh",
            isPortOpen: { host, port in isLocalPortOpen(host: host, port: port) }
        )

        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0
        Task {
            do {
                try await tunnel.start()
                if arguments.contains("--json") {
                    let payload: [String: Any] = [
                        "localPort": localPort,
                        "targetHost": targetHost,
                        "targetPort": targetPort,
                        "ssh": config.displayName,
                        "state": "ready",
                    ]
                    if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
                       let text = String(data: data, encoding: .utf8) {
                        print(text)
                    }
                } else {
                    print("隧道就绪：127.0.0.1:\(localPort) → \(targetHost):\(targetPort)（经 \(config.displayName)）")
                }
                fflush(stdout)
                let hold = Double(value(for: "--hold") ?? "")
                if let hold {
                    try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
                } else {
                    // 没给 --hold：等信号（Ctrl-C / kill），像普通隧道命令那样挂着
                    while true { try? await Task.sleep(nanoseconds: 500_000_000) }
                }
                tunnel.stop()
                semaphore.signal()
            } catch {
                FileHandle.standardError.write(Data("隧道起不来：\(error.localizedDescription)\n".utf8))
                let diagnostics = tunnel.diagnosticText
                if !diagnostics.isEmpty {
                    FileHandle.standardError.write(Data("ssh 输出：\n\(diagnostics)\n".utf8))
                }
                exitCode = 1
                semaphore.signal()
            }
        }
        semaphore.wait()
        return exitCode
    }

    /// 本机端口有没有人在监听（隧道就绪判定）。
    private static func isLocalPortOpen(host: String, port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr(host == "localhost" ? "127.0.0.1" : host)
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// 让系统给一个空闲端口（bind 到 0 再读回来）。
    private static func freeLocalPort() -> Int? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(descriptor, socketAddress, &length)
            }
        }
        guard named == 0 else { return nil }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    /// `code-tokens [--detect <路径>] [--language <raw>] [--text <代码> | --file <路径>] [--complete <前缀>]`
    ///
    /// 三个用途：① 判语言（`--detect`）；② 打印着色记号表（哪一段被认成什么）；
    /// ③ 打印补全候选（`--complete`）。全是纯函数，所以脚本里能直接断言。
    private static func runCodeTokensCommand(arguments: [String]) -> Int32 {
        func value(for flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        if let path = value(for: "--detect") {
            let language = TextLanguage.detect(path: path)
            print("\(path) → \(language.rawValue)（\(language.displayName)）")
            return language == .plainText ? 1 : 0
        }

        guard let raw = value(for: "--language"), let language = TextLanguage(rawValue: raw) else {
            print("用法：code-tokens --detect <路径> | --language <id> [--text <代码> | --file <路径>] [--complete <前缀>]")
            print("语言 id：" + TextLanguage.allCases.map(\.rawValue).joined(separator: " / "))
            return 2
        }

        var text = value(for: "--text") ?? ""
        if let file = value(for: "--file") {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: file)) else {
                print("读不到文件：\(file)")
                return 2
            }
            guard let decoded = try? TextFileDecoder.decode(data) else {
                print("解不出文本（可能不是文本文件）：\(file)")
                return 2
            }
            text = decoded.text
            print("文件：\(file)（编码 \(decoded.encoding.shortName)\(decoded.isFallback ? "，非 UTF-8" : "")）")
        }

        print("语言：\(language.rawValue)（\(language.displayName)）")
        let tokens = CodeLexer.tokens(in: text, language: language)
        let highlighted = tokens.filter { $0.kind.isHighlighted }
        print("记号 \(tokens.count) 个，其中着色 \(highlighted.count) 个：")
        for token in highlighted {
            print("  \(token.kind.rawValue)\t\(String(text[token.range]))")
        }

        if let prefix = value(for: "--complete") {
            let items = CodeCompletion.suggestions(
                prefix: prefix,
                language: language,
                documentWords: CodeCompletion.words(in: text, language: language)
            )
            print("补全（前缀 \(prefix)，\(items.count) 条）：" + items.map(\.label).joined(separator: " "))
        }
        return 0
    }

    private static func runTerminalModesCommand(arguments: [String]) -> Int32 {
        func value(for flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        if let feed = value(for: "--feed") {
            let screen = TerminalScreen(columns: 80, rows: 24)
            // 注入调色板：`OSC 10/11/12` 的颜色查询要有颜色才能回答（不注入时按设计不回答）。
            screen.paletteProvider = { TerminalPalette.deepSeaDark }
            screen.feed(text: feed)
            let responses = screen.drainResponses()
            if arguments.contains("--json") {
                let payload: [String: Any] = [
                    "applicationCursorKeys": screen.isApplicationCursorKeysEnabled,
                    "originMode": screen.isOriginModeEnabled,
                    "focusReporting": screen.isFocusReportingEnabled,
                    "mouseTracking": screen.mouseTrackingMode.rawValue,
                    "sgrMouse": screen.isSGRMouseEnabled,
                    "bracketedPaste": screen.isBracketedPasteEnabled,
                    "cursorRow": screen.cursorRow,
                    "cursorColumn": screen.cursorColumn,
                    "responses": visible(responses),
                ]
                if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
                   let text = String(data: data, encoding: .utf8) {
                    print(text)
                }
                return 0
            }
            print("喂入：\(visible(Array(feed.utf8)))")
            print("模式：DECCKM \(screen.isApplicationCursorKeysEnabled ? "开" : "关") · "
                  + "DECOM \(screen.isOriginModeEnabled ? "开" : "关") · "
                  + "焦点上报 \(screen.isFocusReportingEnabled ? "开" : "关") · "
                  + "鼠标 \(screen.mouseTrackingMode.displayName) · "
                  + "SGR 编码 \(screen.isSGRMouseEnabled ? "开" : "关")")
            print("光标形状：\(screen.requestedCursor?.description() ?? "（前台程序未要求，用用户偏好）")")
            print("光标：行 \(screen.cursorRow + 1) 列 \(screen.cursorColumn + 1)")
            print("回给 PTY：\(responses.isEmpty ? "（无）" : visible(responses))")
            return 0
        }

        print("终端输入与设备应答（FR-EDIT-29）—— 括号里是规范出处")
        print("")
        print("鼠标上报（xterm ctlseqs：DECSET 1000 / 1002 / 1003 + 1006）")
        let events: [(String, TerminalInput.MouseEvent)] = [
            ("左键按下 (10,5)", .init(action: .press, button: .left, column: 10, row: 5)),
            ("左键松开 (10,5)", .init(action: .release, button: .left, column: 10, row: 5)),
            ("中键按下 (3,2)", .init(action: .press, button: .middle, column: 3, row: 2)),
            ("右键按下 (1,1)", .init(action: .press, button: .right, column: 1, row: 1)),
            ("按住左键拖动 (12,6)", .init(action: .motion, button: .left, column: 12, row: 6)),
            ("⌃+滚轮上 (4,4)", .init(action: .wheelUp, button: .left, modifiers: .control, column: 4, row: 4)),
            ("滚轮下 (4,4)", .init(action: .wheelDown, button: .left, column: 4, row: 4)),
        ]
        for (label, event) in events {
            print("  \(label)：旧式 \(visible(TerminalInput.mouseReport(event, sgr: false)))"
                  + " ｜ SGR \(visible(TerminalInput.mouseReport(event, sgr: true)))")
        }
        print("  上报判定：?1000 只报按下/松开/滚轮、?1002 拖动才报移动、?1003 任何移动都报")
        for mode in TerminalInput.MouseTrackingMode.allCases {
            let press = TerminalInput.MouseEvent(action: .press, button: .left, column: 1, row: 1)
            let motion = TerminalInput.MouseEvent(action: .motion, button: .left, column: 1, row: 1)
            print("    \(mode.displayName)：按下 \(TerminalInput.shouldReport(press, mode: mode) ? "报" : "不报")"
                  + " · 移动 \(TerminalInput.shouldReport(motion, mode: mode) ? "报" : "不报")")
        }
        print("")
        print("鼠标路由（FR-EDIT-29：⌥ = 强制本地；右键**反向**，默认归本机）")
        let routes: [(String, Bool, Bool)] = [
            ("前台未接管鼠标", false, false),
            ("前台接管鼠标（?1002 / ?1006）", true, false),
            ("前台接管鼠标 + ⌥", true, true),
        ]
        for (label, reporting, option) in routes {
            let drag = TerminalInput.route(mouseReportingActive: reporting, optionHeld: option) == .program
                ? "转发给程序" : "本机选字"
            let wheel = TerminalInput.route(mouseReportingActive: reporting, optionHeld: option) == .program
                ? "转发给程序" : "本机滚动"
            let right = TerminalInput.rightClickRoute(mouseReportingActive: reporting, optionHeld: option) == .program
                ? "转发给程序" : "本机菜单"
            print("  \(label)：拖动 → \(drag) · 滚轮 → \(wheel) · 右键 → \(right)")
        }
        print("")
        print("光标键（xterm ctlseqs：DECCKM ?1）")
        for key in TerminalInput.CursorKey.allCases {
            print("  \(key.rawValue)：普通 \(visible(TerminalInput.cursorKey(key, applicationCursorKeys: false)))"
                  + " ｜ 应用模式 \(visible(TerminalInput.cursorKey(key, applicationCursorKeys: true)))")
        }
        print("")
        print("光标形状（xterm ctlseqs：DECSCUSR，CSI Ps SP q；0/1 同义）")
        for parameter in 0...6 {
            let appearance = TerminalCursorAppearance.fromDECSCUSR(parameter)
            print("  Ps=\(parameter) → \(appearance?.description() ?? "（认不出，保持原状）")")
        }
        print("")
        print("颜色查询应答（xterm ctlseqs：OSC 10 / 11 / 12）")
        let probe = TerminalPalette.deepSeaDark
        print("  OSC 10;? → OSC 10;rgb:\(ScreenProbe.sixteenBit(probe.foreground)) ST（前景）")
        print("  OSC 11;? → OSC 11;rgb:\(ScreenProbe.sixteenBit(probe.background)) ST（背景）")
        print("  OSC 12;? → OSC 12;rgb:\(ScreenProbe.sixteenBit(probe.cursor)) ST（光标）")
        print("  未注入调色板时**不回答**：与其瞎报一个颜色，不如让程序退回自己的默认")
        print("")
        print("设备查询应答（xterm ctlseqs：DA1 / DA2 / DSR / DECRQM / XTVERSION）")
        print("  DA1（CSI c）        → \(visible(TerminalInput.primaryDeviceAttributes()))")
        print("  DA2（CSI > c）      → \(visible(TerminalInput.secondaryDeviceAttributes()))")
        print("  DSR 5（CSI 5 n）    → \(visible(TerminalInput.statusReportOK()))")
        print("  DSR 6（CSI 6 n）    → \(visible(TerminalInput.cursorPositionReport(row: 7, column: 3)))")
        print("  DECRQM ?1000 已置位 → \(visible(TerminalInput.modeReport(parameter: 1000, isPrivate: true, state: .set)))")
        print("  DECRQM ?9999 不认识 → \(visible(TerminalInput.modeReport(parameter: 9999, isPrivate: true, state: .notRecognized)))")
        print("  XTVERSION（CSI > q）→ \(visible(TerminalInput.terminalVersion(name: DoyahIdentity.terminalVersionName)))")
        return 0
    }

    /// 解析「时刻」参数：接受 `yyyy-MM-dd`（按当天 0 点）与 ISO 8601。
    ///
    /// 只给天数时按 **0 点**算而不是当天结束：生命周期判据本来就是按**自然日**差的，
    /// 差半天不该改变结论（用 23:59 会让人以为"多算了今天"）。
    static func parseMoment(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: trimmed) { return date }
        let dayOnly = DateFormatter()
        dayOnly.locale = Locale(identifier: "en_US_POSIX")
        dayOnly.timeZone = .current
        dayOnly.dateFormat = "yyyy-MM-dd"
        return dayOnly.date(from: trimmed)
    }

    /// 把字节渲染成可读形式（ESC → `ESC`、控制字符 → `\xNN`），便于脚本 grep 与人工核对。
    private static func visible(_ bytes: [UInt8]) -> String {
        var text = ""
        for byte in bytes {
            switch byte {
            case 0x1B: text += "ESC"
            case 0x09: text += "\\t"
            case 0x0D: text += "\\r"
            case 0x0A: text += "\\n"
            case 0x20...0x7E: text.append(Character(UnicodeScalar(byte)))
            default: text += String(format: "\\x%02X", byte)
            }
        }
        return text
    }

    /// `terminal-palette [--json]`：打印终端色板（FR-EDIT-29 的配色证据出口）。
    private static func runTerminalPaletteCommand(arguments: [String]) -> Int32 {
        let names = [
            "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
            "bright black", "bright red", "bright green", "bright yellow",
            "bright blue", "bright magenta", "bright cyan", "bright white"
        ]
        func value(for flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        // 外观偏好与字号：与 App 里那两项设置**同源**（Core 的 `TerminalAppearance` / `TerminalFontSize`）。
        // `--system` 模拟系统当前外观，用来证明"覆盖态不受系统影响"这件事真的成立。
        let appearance = Self.terminalAppearance(from: value(for: "--appearance"))
        let systemIsDark = (value(for: "--system") ?? "dark").lowercased() != "light"
        let requestedFontSize = Int(value(for: "--font-size") ?? "") ?? TerminalFontSize.default
        let fontSize = TerminalFontSize.clamped(requestedFontSize)

        // 不带任何外观参数时**两套都打**（给人看色板用）；一旦指定了偏好 / 系统外观 / 字号，
        // 就只打**解析出来的那一套** —— 否则"我选的到底生效没有"要在一堆输出里找。
        let selected = arguments.contains("--appearance")
            || arguments.contains("--system")
            || arguments.contains("--font-size")
        let palettes = selected
            ? [appearance.palette(systemIsDark: systemIsDark)]
            : [TerminalPalette.deepSeaDark, TerminalPalette.deepSeaLight]

        if arguments.contains("--json") {
            var payload: [[String: Any]] = []
            payload.append([
                // `kind` 让机器消费者一眼分清"解析元数据"与"色板实体"，
                // 而不是靠"有没有某个键"去猜（Gate 与 Linux 侧都用它筛选）。
                "kind": "resolution",
                "appearance": appearance.rawValue,
                "systemIsDark": systemIsDark,
                "resolvedIsDark": appearance.resolvesToDark(systemIsDark: systemIsDark),
                "fontSize": fontSize,
                "fontSizeClamped": fontSize != requestedFontSize
            ])
            for palette in palettes {
                payload.append([
                    "kind": "palette",
                    "name": palette.name,
                    "isDark": palette.isDark,
                    "background": palette.background.hexString,
                    "foreground": palette.foreground.hexString,
                    "cursor": palette.cursor.hexString,
                    "selection": palette.selectionBackground.hexString,
                    "foregroundContrast": String(format: "%.2f", TerminalPalette.contrastRatio(palette.foreground, palette.background)),
                    "ansi": palette.ansi.enumerated().map { index, color in
                        [
                            "index": index,
                            "name": names[index],
                            "hex": color.hexString,
                            "contrast": String(format: "%.2f", TerminalPalette.contrastRatio(color, palette.background)),
                            "backgroundSlot": TerminalPalette.isBackgroundSlot(index: index, isDark: palette.isDark)
                        ] as [String: Any]
                    }
                ])
            }
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
                print(String(decoding: data, as: UTF8.self))
                return 0
            }
            return 2
        }

        print("外观偏好 \(appearance.rawValue) · 系统外观 \(systemIsDark ? "深色" : "浅色")"
              + " → 实际使用 \(appearance.resolvesToDark(systemIsDark: systemIsDark) ? "深色" : "浅色")"
              + " · 字号 \(fontSize) pt\(fontSize != requestedFontSize ? "（请求 \(requestedFontSize)，已夹到区间）" : "")")
        print("")
        for palette in palettes {
            print("=== \(palette.name)（\(palette.isDark ? "深色" : "浅色")）===")
            print("  背景 \(palette.background.hexString)   前景 \(palette.foreground.hexString)"
                  + "（对比度 \(format(TerminalPalette.contrastRatio(palette.foreground, palette.background)))）")
            print("  光标 \(palette.cursor.hexString)（对底色 \(format(TerminalPalette.contrastRatio(palette.cursor, palette.background)))）"
                  + "   选中底 \(palette.selectionBackground.hexString)"
                  + "（选中底上的字 \(format(TerminalPalette.contrastRatio(palette.foreground, palette.selectionBackground)))）")
            print("  槽位  名称             色值       对底色对比度")
            for (index, color) in palette.ansi.enumerated() {
                let ratio = TerminalPalette.contrastRatio(color, palette.background)
                let note = TerminalPalette.isBackgroundSlot(index: index, isDark: palette.isDark) ? "（背景槽）" : ""
                let label = names[index].padding(toLength: 15, withPad: " ", startingAt: 0)
                print(String(format: "  %2d    %@  %@    %@%@", index, label as NSString, color.hexString as NSString, format(ratio) as NSString, note))
            }
            print("")
        }
        print("口径：当正文用的槽位对底色 ≥ 4.5（WCAG AA）；前景对底色 ≥ 7；四个背景槽按各自的设计要求（见 Core/TerminalPalette 注释）。")
        return 0

        func format(_ value: Double) -> String {
            String(format: "%.2f", value)
        }
    }

    private static func runSpecsCommand(arguments: [String]) -> Int32 {
        func value(for flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        let directory = URL(fileURLWithPath: value(for: "--dir") ?? FileManager.default.currentDirectoryPath)
        let versions = SpecVersionStore(directoryURL: directory)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // `--rerun-mode <模式> [--task-file <json>]`：打印幂等语义与判定（不写任何东西）
        if let rawMode = value(for: "--rerun-mode") {
            guard let mode = RerunMode(rawValue: rawMode) else {
                print("未知的重跑语义：\(rawMode)（可用：\(RerunMode.allCases.map(\.rawValue).joined(separator: " / "))）")
                return 64
            }
            print(RerunPolicy.describe(mode))
            guard let file = value(for: "--task-file"),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: file)),
                  let definition = try? decoder.decode(DataTaskDefinition.self, from: data) else {
                print("（给了 --task-file 才能判定与任务写入模式是否一致）")
                return 0
            }
            let verdict = RerunPolicy.evaluate(mode: mode, definition: definition)
            for blocker in verdict.blockers { print("❌ " + blocker) }
            for warning in verdict.warnings { print("⚠️ " + warning) }
            return verdict.isAllowed ? 0 : 3
        }

        // `--save <json>`：保存定义（自动记版本）
        if let file = value(for: "--save") {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: file)),
                  let definition = try? decoder.decode(DataTaskDefinition.self, from: data) else {
                print("读取任务定义失败：\(file)（需要 DataTaskDefinition 的 JSON）")
                return 66
            }
            let store = DataTaskStore(directoryURL: directory)
            let semaphore = DispatchSemaphore(value: 0)
            var code: Int32 = 0
            Task {
                do {
                    try await store.save(definition)
                    let all = versions.versions(taskID: definition.id)
                    print("已保存「\(definition.name)」：当前共 \(all.count) 个版本"
                          + (all.last.map { "（最新 v\($0.number)）" } ?? ""))
                    code = 0
                } catch {
                    print("保存失败：\(error.localizedDescription)")
                    code = 1
                }
                semaphore.signal()
            }
            semaphore.wait()
            return code
        }

        guard let taskIDString = value(for: "--task"), let taskID = UUID(uuidString: taskIDString) else {
            print("用法：specs --dir <目录> --task <任务 UUID> [--history | --diff <a> <b> | --rollback <n>]")
            print("      specs --dir <目录> --save <定义.json>")
            print("      specs --rerun-mode <overwrite|append|resume> [--task-file <定义.json>]")
            return 64
        }

        // `--history`
        if arguments.contains("--history") {
            let history = versions.versions(taskID: taskID)
            if arguments.contains("--json") {
                let payload = history.map { version -> [String: Any] in
                    ["number": version.number, "name": version.definition.name,
                     "specs": version.specs, "note": version.note ?? "",
                     "savedAt": ISO8601DateFormatter().string(from: version.savedAt)]
                }
                if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
                   let text = String(data: data, encoding: .utf8) {
                    print(text)
                    return history.isEmpty ? 1 : 0
                }
            }
            print("共 \(history.count) 个版本：")
            for version in history {
                print("  v\(version.number)\t\(version.definition.name)\t\(version.specs.prefix(40))"
                      + (version.note.map { "\t[\($0)]" } ?? ""))
            }
            return history.isEmpty ? 1 : 0
        }

        // `--diff <a> <b>`
        if let first = value(for: "--diff") {
            guard let index = arguments.firstIndex(of: "--diff"), index + 2 < arguments.count,
                  let a = Int(first), let b = Int(arguments[index + 2]) else {
                print("--diff 需要两个版本号：--diff <a> <b>")
                return 64
            }
            guard let left = versions.version(taskID: taskID, number: a),
                  let right = versions.version(taskID: taskID, number: b) else {
                print("找不到版本（v\(a) / v\(b)）")
                return 1
            }
            let changes = SpecDiff.changes(between: left.definition, and: right.definition)
            if changes.isEmpty {
                print("v\(a) 与 v\(b) 没有差异")
                return 1
            }
            print("v\(a) → v\(b) 共 \(changes.count) 处改动：")
            for change in changes { print("  " + change.description) }
            return 0
        }

        // `--rollback <n>`：把旧版本**再存一次**（历史留痕，不是删掉后面的版本）
        if let rawNumber = value(for: "--rollback"), let number = Int(rawNumber) {
            guard let version = versions.version(taskID: taskID, number: number) else {
                print("找不到版本 v\(number)")
                return 1
            }
            let store = DataTaskStore(directoryURL: directory)
            let target = version.definition
            var code: Int32 = 0
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                do {
                    try await store.save(target)
                    print("已回滚到 v\(number)（内容以**新版本**记入历史，旧版本仍可查）")
                    code = 0
                } catch {
                    print("回滚失败：\(error.localizedDescription)")
                    code = 1
                }
                semaphore.signal()
            }
            semaphore.wait()
            return code
        }

        print("请指定 --history / --diff / --rollback 之一")
        return 64
    }

    private static func runMemoryCommand(arguments: [String]) -> Int32 {
        func value(for flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
                return nil
            }
            return arguments[index + 1]
        }

        guard let directory = value(for: "--dir") else {
            print("用法：memory --dir <归档目录> [--prefix \"…\"] [--connection 名] [--completion [--dialect …]] [--routines] [--show 指纹] [--delete 指纹] [--clear --yes] [--promote 指纹] [--general] [--general-remove id] [--retention [--apply --yes]] [--veto 指纹] [--unveto 指纹] [--keep-literal 指纹 字面量] [--json]")
            return 64
        }

        let index = QueryMemory.buildIndex(directory: URL(fileURLWithPath: directory))
        if !index.skippedFiles.isEmpty {
            print("跳过 \(index.skippedFiles.count) 个文件（空 / 非归档格式 / 读不了）：\(index.skippedFiles.joined(separator: "、"))")
        }
        print("从 \(index.parsedEntryCount) 条归档记录派生出 \(index.memories.count) 条记忆")

        // ── 人工决定（FR-AI-14）：否决 / 取消否决 / 把误判的常量标回字面量 ──
        //    这些是**人显式触发**的动作，所以允许写文件；评估本身仍是纯函数（不落盘、不建任务）。
        let decisionsDirectory = URL(fileURLWithPath: directory)
        var loadedDecisions = MemoryDecisionsStore.load(from: decisionsDirectory)
        if !loadedDecisions.warnings.isEmpty {
            for warning in loadedDecisions.warnings { print("⚠️ 记忆决定：\(warning)") }
        }
        var decisionsDirty = false

        if let fingerprint = value(for: "--veto") {
            loadedDecisions.decisions.veto(fingerprint: fingerprint)
            decisionsDirty = true
            print("已否决：\(fingerprint)（长期生效，跨进程有效）")
        }
        if let fingerprint = value(for: "--unveto") {
            loadedDecisions.decisions.unveto(fingerprint: fingerprint)
            decisionsDirty = true
            print("已取消否决：\(fingerprint)")
        }
        if let flagIndex = arguments.firstIndex(of: "--keep-literal"), flagIndex + 2 < arguments.count {
            let fingerprint = arguments[flagIndex + 1]
            let literal = arguments[flagIndex + 2]
            loadedDecisions.decisions.keepLiteral(fingerprint: fingerprint, literal: literal)
            decisionsDirty = true
            print("已保留字面量：\(fingerprint) → \(literal)（只改模板渲染，不改聚类与频次）")
        }
        if decisionsDirty {
            do {
                try MemoryDecisionsStore.save(loadedDecisions.decisions, to: decisionsDirectory)
            } catch {
                print("⚠️ 记忆决定写入失败：\(error)")
                return 1
            }
        }

        // ── 治理（FR-AI-15）：可检视 / 可删除 / 可整层清空 / 可解释 ──

        // `--show`：这条记忆的来路与"为什么记了它 / 为什么它被忘了"
        if let fingerprint = value(for: "--show") {
            guard let memory = index.memories.first(where: { $0.fingerprint == fingerprint }) else {
                print("没有这条记忆：\(fingerprint)")
                return 1
            }
            // 「一年只用一次但很关键」的巡检脚本按人工钉住处理（CLI 里没有界面，用 --kind 指定）
            let kind = MemoryKind(rawValue: value(for: "--kind") ?? "") ?? .routine
            let verdict = RetentionPolicy.standard.evaluate(
                kind: kind,
                stats: MemoryStats(memory: memory),
                now: Date()
            )
            for line in MemoryExplanation.describe(memory: memory, kind: kind, verdict: verdict) {
                print("  " + line)
            }
            return 0
        }

        // `--delete` / `--clear`：治理必须作用在**归档**上（记忆层只是派生索引）
        if let fingerprint = value(for: "--delete") {
            do {
                let report = try SQLArchiveEditor.removeEntries(
                    matchingFingerprint: fingerprint,
                    in: decisionsDirectory
                )
                print("已删除 \(report.removedEntryCount) 条归档记录（\u{66f4}改文件：\(report.changedFiles.joined(separator: "、"))；剩余 \(report.remainingEntryCount) 条）")
                print("重建索引后该记忆不会再出现（\u{7eaf}\u{6d3e}\u{751f}\u{7f13}\u{5b58}）")
                return report.didChangeAnything ? 0 : 1
            } catch {
                print("删除失败：\(error.localizedDescription)")
                return 1
            }
        }

        if arguments.contains("--clear") {
            // 清空是不可逆的：**必须显式确认**，否则拒绝且不动归档一个字节
            guard arguments.contains("--yes") else {
                print("拒绝：整层清空不可逆，请确认后加 `--yes`（当前未改动任何文件）")
                return 64
            }
            do {
                let report = try SQLArchiveEditor.removeAll(in: decisionsDirectory)
                print("已清空归档：删除 \(report.removedEntryCount) 条记录 / \(report.changedFiles.count) 个文件")
                return 0
            } catch {
                print("清空失败：\(error.localizedDescription)")
                return 1
            }
        }

        // `--promote`：通用层提升 + 脱敏闸 + **落盘**（FR-AI-15 验收④）。
        // `--dry-run` 只打印判定（脱敏闸不过时**绝不落盘**）。
        if let fingerprint = value(for: "--promote") {
            guard let memory = index.memories.first(where: { $0.fingerprint == fingerprint }) else {
                print("没有这条记忆：\(fingerprint)")
                return 1
            }
            let dialectName = value(for: "--dialect") == "gbase8a" ? "gbase8a" : "postgresql"
            let dialect = SQLDialectFactory.make(for: dialectName == "gbase8a" ? .gbase8a : .postgresql)
            guard let generalized = MemoryPromotion.generalize(sql: memory.latestSQL, dialect: dialect) else {
                print("这条语句不适合提升到通用层")
                return 1
            }
            let verdict = MemoryPromotion.check(
                original: memory.latestSQL,
                generalized: generalized,
                dialect: dialect
            )
            print("通用写法：\(generalized)")
            print("脱敏闸：\(verdict.reason)")
            if !verdict.isAllowed {
                print("拒绝落盘：通用写法里仍带着具体标识符或取值（\(verdict.leakedTerms.joined(separator: "、"))）")
                return 1
            }
            if arguments.contains("--dry-run") {
                print("（--dry-run：只打印判定，未写 \(GeneralMemoryLayer.fileName)）")
                return 0
            }
            var layer = GeneralMemoryStore.load(from: decisionsDirectory).layer
            let promoted = layer.promote(
                template: generalized,
                dialect: dialectName,
                sourceFingerprint: fingerprint
            )
            do {
                try GeneralMemoryStore.save(layer, to: decisionsDirectory)
            } catch {
                print("通用层写入失败：\(error.localizedDescription)")
                return 1
            }
            print("已落盘：\(GeneralMemoryLayer.fileName)（第 \(promoted.useCount) 次提升同一条写法，共 \(layer.memories.count) 条通用经验）")
            return 0
        }

        // `--general`：列出通用层（可检视）
        if arguments.contains("--general") {
            let loaded = GeneralMemoryStore.load(from: decisionsDirectory)
            for warning in loaded.warnings { print("⚠️ 通用层：\(warning)") }
            if arguments.contains("--json") {
                let payload: [String: Any] = [
                    "count": loaded.layer.memories.count,
                    "memories": loaded.layer.memories.map { memory -> [String: Any] in
                        [
                            "id": memory.id,
                            "template": memory.template,
                            "dialect": memory.dialect,
                            "useCount": memory.useCount,
                            "sources": memory.sourceFingerprints
                        ]
                    }
                ]
                if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted]),
                   let text = String(data: data, encoding: .utf8) {
                    print(text)
                }
                return 0
            }
            if loaded.layer.isEmpty {
                print("通用层为空（还没提升过任何写法；用 --promote <指纹> 提升一条）")
                return 0
            }
            print("通用层共 \(loaded.layer.memories.count) 条（文件：\(GeneralMemoryLayer.fileName)，可检视 / 可删除）")
            for memory in loaded.layer.memories {
                print("  · \(memory.id)  [\(memory.dialect)]  提升 \(memory.useCount) 次")
                print("      \(memory.template)")
            }
            return 0
        }

        // `--general-remove`：删掉一条通用经验（**只影响通用层**，不动归档与记忆）
        if let id = value(for: "--general-remove") {
            var layer = GeneralMemoryStore.load(from: decisionsDirectory).layer
            guard layer.remove(id: id) else {
                print("通用层没有这条：\(id)")
                return 1
            }
            do {
                try GeneralMemoryStore.save(layer, to: decisionsDirectory)
            } catch {
                print("通用层写入失败：\(error.localizedDescription)")
                return 1
            }
            print("已从通用层删除：\(id)（剩余 \(layer.memories.count) 条；归档与记忆层未受影响）")
            return 0
        }

        // `--retention`：生命周期**执行者**（FR-AI-15）。
        // 默认只打印计划；`--apply --yes` 才真删归档 —— 与 `--clear` / `--delete` 同一条纪律。
        if arguments.contains("--retention") {
            // `--now`：按指定时刻评估（**预演**用：想看看"再过半年哪些会被忘"）。
            // 不传就按当前时间；只写到天时按当天 0 点算。
            let now = value(for: "--now").flatMap(Self.parseMoment) ?? Date()
            let plan = MemoryGovernance.plan(memories: index.memories, now: now)
            if arguments.contains("--json") {
                let payload: [String: Any] = [
                    "policy": ["idleDays": plan.policy.idleDays, "lowUseRunCount": plan.policy.lowUseRunCount],
                    "forgettable": plan.forgettable.map { item -> [String: Any] in
                        [
                            "fingerprint": item.fingerprint,
                            "kind": item.kind.rawValue,
                            "reason": item.verdict.reason,
                            "classification": item.classificationReason,
                            "runCount": item.runCount,
                            "dayCount": item.dayCount
                        ]
                    },
                    "retainedCount": plan.retained.count
                ]
                if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted]),
                   let text = String(data: data, encoding: .utf8) {
                    print(text)
                }
                return 0
            }
            for line in plan.describe() { print(line) }

            guard arguments.contains("--apply") else {
                print("")
                print("（默认只打印计划。确认要删就加 `--apply --yes`；删的是**归档记录**，不可撤销）")
                return plan.forgettable.isEmpty ? 0 : 0
            }
            guard arguments.contains("--yes") else {
                print("")
                print("拒绝：按计划删除归档不可撤销，请确认后加 `--yes`（当前未改动任何文件）")
                return 64
            }
            guard !plan.forgettable.isEmpty else {
                print("没有可遗忘的条目，未改动任何文件")
                return 0
            }

            var removed = 0
            var changed: [String] = []
            for item in plan.forgettable {
                do {
                    let report = try SQLArchiveEditor.removeEntries(
                        matchingFingerprint: item.fingerprint,
                        in: decisionsDirectory
                    )
                    removed += report.removedEntryCount
                    changed.append(contentsOf: report.changedFiles)
                } catch {
                    print("删除失败（\(item.fingerprint)）：\(error.localizedDescription)")
                    return 1
                }
            }
            print("已按计划删除 \(removed) 条归档记录（改动文件：\(Array(Set(changed)).sorted().joined(separator: "、"))）")
            return 0
        }

        // ── 例行候选（FR-AI-14）──
        if arguments.contains("--routines") {
            let report = RoutineCandidate.evaluate(index: index, decisions: loadedDecisions.decisions)
            if arguments.contains("--json") {
                let payload: [String: Any] = [
                    "candidates": report.candidates.map { candidate -> [String: Any] in
                        [
                            "fingerprint": candidate.fingerprint,
                            "template": candidate.template,
                            "runs": candidate.runCount,
                            "days": candidate.dayCount,
                            "concentrationPercent": candidate.concentration.percent,
                            "windowStartHour": candidate.concentration.startHour,
                            "variants": candidate.variantCount,
                            "slotSamples": candidate.slotSamples,
                            "connections": candidate.connections.sorted()
                        ]
                    },
                    "assessments": report.assessments.map { assessment -> [String: Any] in
                        [
                            "fingerprint": assessment.fingerprint,
                            "isCandidate": assessment.isCandidate,
                            "reasons": assessment.reasons,
                            "runs": assessment.runCount,
                            "days": assessment.dayCount
                        ]
                    },
                    "vetoed": report.vetoedFingerprints
                ]
                if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
                   let text = String(data: data, encoding: .utf8) {
                    print(text)
                    return report.candidates.isEmpty ? 1 : 0
                }
            }
            print("例行候选：\(report.candidates.count) 条（被否决 \(report.vetoedFingerprints.count) 条）")
            for candidate in report.candidates {
                print("  [执行 \(candidate.runCount) 次 · \(candidate.dayCount) 天 · 集中 \(candidate.concentration.percent)%"
                      + "（\(candidate.concentration.startHour) 点起 \(candidate.concentration.windowHours) 小时）"
                      + " · 变体 \(candidate.variantCount) 条]")
                print("      \(candidate.template)")
                for (ordinal, samples) in candidate.slotSamples.enumerated() {
                    print("      槽位 \(ordinal + 1) 样例：\(samples.joined(separator: " / "))")
                }
            }
            // 未达标的也列出来（含"为什么不是候选"）—— 这层只产建议，所以理由必须可见
            let blocked = report.assessments.filter { !$0.isCandidate }
            if !blocked.isEmpty {
                print("未达标（\(blocked.count) 条）：")
                for assessment in blocked.prefix(10) {
                    print("  \(assessment.reasons.joined(separator: "；"))")
                }
            }
            return report.candidates.isEmpty ? 1 : 0
        }

        if let prefix = value(for: "--prefix") {
            // `--completion`：输出**编辑器里实际会看到的候选**（方言关键字 + 当前连接的记忆），
            // 顺序就是 UI 里的顺序 —— 让「记忆会不会顶掉关键字」这类规则可以被脚本核对（FR-AI-13 S4）。
            if arguments.contains("--completion") {
                let dialect = SQLDialectFactory.make(
                    for: value(for: "--dialect") == "gbase8a" ? .gbase8a : .postgresql
                )
                let connection = value(for: "--connection")
                let candidates = QueryCompletion.suggestions(
                    prefix: prefix,
                    dialect: dialect,
                    memory: index,
                    connection: connection
                )
                if arguments.contains("--json") {
                    let dialectKeys = Set(
                        QueryCompletion.dialectMatches(prefix: prefix, dialect: dialect).map { $0.lowercased() }
                    )
                    let payload = candidates.map { candidate -> [String: Any] in
                        ["text": candidate, "source": dialectKeys.contains(candidate.lowercased()) ? "dialect" : "memory"]
                    }
                    if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
                       let text = String(data: data, encoding: .utf8) {
                        print(text)
                        return candidates.isEmpty ? 1 : 0
                    }
                }
                print("编辑器补全（前缀「\(prefix)」\(connection.map { "，连接「\($0)」" } ?? "")，方言 \(dialect.databaseType.rawValue)）：\(candidates.count) 条")
                let dialectKeys = Set(
                    QueryCompletion.dialectMatches(prefix: prefix, dialect: dialect).map { $0.lowercased() }
                )
                for (position, candidate) in candidates.enumerated() {
                    let source = dialectKeys.contains(candidate.lowercased()) ? "关键字" : "记忆"
                    print("  \(position + 1). [\(source)] \(candidate.replacingOccurrences(of: "\n", with: " "))")
                }
                return candidates.isEmpty ? 1 : 0
            }

            let suggestions = QueryMemory.suggestions(
                prefix: prefix,
                in: index,
                connection: value(for: "--connection"),
                limit: 10
            )
            if arguments.contains("--json") {
                let payload = suggestions.map { suggestion -> [String: Any] in
                    ["sql": suggestion.sql, "score": suggestion.score, "runs": suggestion.memory.runCount]
                }
                if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
                   let text = String(data: data, encoding: .utf8) {
                    print(text)
                    return suggestions.isEmpty ? 1 : 0
                }
            }
            print("补全候选（前缀「\(prefix)」\(value(for: "--connection").map { "，连接「\($0)」" } ?? "")）：\(suggestions.count) 条")
            for suggestion in suggestions {
                let memory = suggestion.memory
                print("  [\(suggestion.score)] 执行 \(memory.runCount) 次 · \(memory.days.count) 天 · 连接 \(memory.connections.sorted().joined(separator: "/"))")
                print("      \(suggestion.sql.replacingOccurrences(of: "\n", with: " "))")
            }
            return suggestions.isEmpty ? 1 : 0
        }

        // `--json`：**清单也要有机器可读出口**。
        // 为什么补：验证脚本此前只能按缩进数去"猜"指纹，缩进一变就假失败 ——
        // 脚本解析人类可读文本是错的做法，出口本身该是机器可读的。
        if arguments.contains("--json") {
            let payload = index.memories.map { memory -> [String: Any] in
                [
                    "fingerprint": memory.fingerprint,
                    "sql": memory.latestSQL,
                    "runs": memory.runCount,
                    "days": memory.days.sorted(),
                    "variants": memory.variantCount,
                    "connections": memory.connections.sorted()
                ]
            }
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                print(text)
                return index.isEmpty ? 1 : 0
            }
        }

        for memory in index.memories {
            print("  \(String(format: "%4d", memory.runCount)) 次 · \(memory.days.count) 天 · \(memory.variantCount) 个变体 · "
                  + "\(memory.connections.sorted().joined(separator: "/"))")
            print("      \(QueryMemory.coarseFingerprint(memory.latestSQL))")
        }
        return index.isEmpty ? 1 : 0
    }

    /// `connections [--dir <配置目录>] [--json]`
    ///
    /// 默认读应用数据目录（与 App 一致）；`--dir` 用于验证脚本指向临时目录。
    private static func runConnectionsCommand(arguments: [String]) async -> Int32 {
        func value(for flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        let store = ConnectionStore(directoryURL: value(for: "--dir").map { URL(fileURLWithPath: $0) })
        do {
            let (configurations, summary) = try await store.loadWithReport()
            if arguments.contains("--json") {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(configurations)
                print(String(data: data, encoding: .utf8) ?? "")
                return 0
            }

            // `--check <连接名> --sql "…"`：把「这条语句在这个连接上能不能跑」做成可脚本化的判定。
            // 为什么要这个出口：只读是**客户端**保护，只有真正走一遍判定才算验过 ——
            // 光看配置文件里有 `isReadOnly: true` 证明不了任何东西。
            if let name = value(for: "--check") {
                guard let configuration = configurations.first(where: { $0.name == name }) else {
                    print("没有这个连接：\(name)")
                    return 66
                }
                guard let sql = value(for: "--sql") else {
                    print("用法：connections --check <连接名> --sql \"…\" [--dir …]")
                    return 64
                }
                let decision = ExecutionSafety.check(
                    sql: sql,
                    databaseType: configuration.dbType,
                    policy: ExecutionSafetyPolicy(
                        isEnabled: false,
                        isReadOnly: configuration.isReadOnly
                    )
                )
                switch decision {
                case .allow:
                    print("允许：\(configuration.name)\(configuration.isReadOnly ? "（只读）" : "") 上可以执行")
                    return 0
                case .refused(let reasons, let statements):
                    print("拒绝：\(reasons.joined(separator: " "))")
                    for statement in statements { print("  · \(statement)") }
                    return 3
                case .needsConfirmation(let reasons, _, _):
                    print("需要确认：\(reasons.joined(separator: "；"))")
                    return 4
                }
            }

            // `--show-startup <连接名>`：打印连接建立后会执行的**逐条**启动 SQL（拆分结果）
            if let name = value(for: "--show-startup") {
                guard let configuration = configurations.first(where: { $0.name == name }) else {
                    print("没有这个连接：\(name)")
                    return 66
                }
                let statements = configuration.startupStatements
                print("\(configuration.name)：启动 SQL \(statements.count) 条")
                for statement in statements { print("  · \(statement)") }
                return statements.isEmpty ? 1 : 0
            }

            // `--by-group`：按分组打印。顺序由 `ConnectionGrouping` 定（与侧边栏同一份聚合），
            // 所以这里能断言"未分组永远最后"这类语义 —— 而不是靠界面肉眼看。
            if arguments.contains("--by-group") {
                let sections = ConnectionGrouping.sections(configurations)
                print("分组：\(sections.count) 组 / \(configurations.count) 条连接")
                for section in sections {
                    let title = section.group ?? ConnectionGrouping.ungroupedTitle
                    print("\(title)（\(section.connections.count)）")
                    for connection in section.connections {
                        print("    \(connection.name)\t\(connection.endpointDescription)")
                    }
                }
                return sections.isEmpty ? 1 : 0
            }

            // `--import-url <postgres://…>`：一行建连（FR-CONN-19）。
            // 默认**只解析并展示**；`--save` 才写入配置文件（**不含密码** —— 密码只进本项目的密钥存储）。
            if let raw = value(for: "--import-url") {
                switch ConnectionURL.parse(raw, name: value(for: "--name")) {
                case .failure(let error):
                    print("URL 解析失败：\(error.localizedDescription)")
                    return 64
                case .success(let imported):
                    var lines: [String] = []
                    lines.append("解析结果：\(imported.configuration.name)")
                    lines.append("  \(imported.configuration.endpointDescription)  库=\(imported.configuration.database)")
                    lines.append("  SSL=\(imported.configuration.sslMode.rawValue)")
                    if imported.password != nil {
                        lines.append("  ⚠️ URL 里带了密码：它**不会**写入配置文件（密码只进本项目的密钥存储，DR-02）")
                    }
                    for ignored in imported.ignoredParameters {
                        lines.append("  （不认识的参数已忽略：\(ignored)）")
                    }
                    if arguments.contains("--save") {
                        var all = configurations
                        if let index = all.firstIndex(where: { $0.name == imported.configuration.name }) {
                            all[index] = imported.configuration
                        } else {
                            all.append(imported.configuration)
                        }
                        do {
                            try await store.save(all)
                            lines.append("  已保存（不含密码）")
                        } catch {
                            print("保存失败：\(error.localizedDescription)")
                            return 66
                        }
                    } else {
                        lines.append("  （未保存；加 --save 写入配置文件）")
                    }
                    print(lines.joined(separator: "\n"))
                    return 0
                }
            }

            // `--export-url <连接名>`：导出成一行 URL，**不含密码**。
            if let name = value(for: "--export-url") {
                guard let configuration = configurations.first(where: { $0.name == name }) else {
                    print("没有这个连接：\(name)")
                    return 66
                }
                print(ConnectionURL.url(for: configuration))
                return 0
            }

            // `--export-bundle <文件>`：导出配置包（换机迁移），**不含密码**。
            if let path = value(for: "--export-bundle") {
                let bundle = ConnectionBundle(connections: configurations)
                do {
                    try bundle.encoded().write(to: URL(fileURLWithPath: path))
                    print("已导出 \(configurations.count) 条连接配置 → \(path)（不含密码）")
                    return 0
                } catch {
                    print("导出失败：\(error.localizedDescription)")
                    return 66
                }
            }

            print("连接配置：\(configurations.count) 条（文件 \(await store.fileLocation().path)）")
            if summary.didMigrate {
                print("（本次读入时迁移了 \(summary.migrated.count) 条）")
            }
            for configuration in configurations {
                let environment = configuration.environment?.rawValue ?? "—"
                let color = configuration.colorTag?.rawValue ?? "—"
                let readOnly = configuration.isReadOnly ? "这是只读连接" : "可写"
                let startup = configuration.startupStatements.count
                let group = configuration.normalizedGroup ?? "—"
                print("  \(configuration.name)\t\(configuration.endpointDescription)\t环境=\(environment)\t颜色=\(color)\t组=\(group)\t\(readOnly)\t启动 SQL \(startup) 条")
            }
            return 0
        } catch {
            print("读取连接配置失败：\(error.localizedDescription)")
            return 66
        }
    }

    /// `search-objects <关键词> [--schema S] [--limit N] [--kind table|view|column|function]`
    ///
    /// 为什么 CLI 要有它：全库搜索的正确性（跨 schema、列的 `表.列` 形态、排序）**必须能脚本化验证**，
    /// 而不是靠人在界面里看一眼。
    /// `keepalive [--interval N] [--pings M] [--disabled]`
    ///
    /// 这条命令的价值是**可验证**：真实发若干次心跳、报告成功与失败，
    /// 而"空闲多久才发"的判定留在 Core 的纯函数里（另有单测）。
    private static func runKeepAliveCommand(
        arguments: [String],
        service: any DatabaseService
    ) async -> Int32 {
        func value(for flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
                return nil
            }
            return arguments[index + 1]
        }

        let policy = KeepAlivePolicy(
            isEnabled: !arguments.contains("--disabled"),
            intervalSeconds: Int(value(for: "--interval") ?? "") ?? 5
        )
        print("保活策略：\(policy.isEnabled ? "开启" : "关闭")，间隔 \(policy.intervalSeconds) 秒")

        guard policy.isEnabled else {
            print("（已关闭：不会发送任何心跳）")
            return 0
        }

        let pings = max(0, Int(value(for: "--pings") ?? "") ?? 1)
        let statement = KeepAlivePolicy.statement(for: .postgresql)
        var record = KeepAliveRecord()
        let idle = Date(timeIntervalSince1970: 0)

        for index in 1...max(1, pings) {
            // 用"很久以前的活动时间"驱动判定：让 Core 的 shouldPing 真的参与决策，
            // 而不是这里直接循环发 —— 否则命令就没在验那条判据。
            guard KeepAliveScheduler.shouldPing(lastActivity: idle, now: Date(), policy: policy) else {
                print("第 \(index) 次：按策略还不到时候（不该发）")
                return 1
            }
            do {
                _ = try await runQueryForKeepAlive(statement, on: service)
                record.record(success: true, at: Date())
                print("第 \(index) 次：\(statement) 成功")
            } catch {
                record.record(success: false, at: Date(), failure: error.localizedDescription)
                print("第 \(index) 次：失败（\(error.localizedDescription)）")
            }
            if index < pings {
                try? await Task.sleep(nanoseconds: UInt64(policy.intervalSeconds) * 1_000_000_000)
            }
        }
        print("汇总：\(record.summary)")
        return record.isHealthy ? 0 : 1
    }

    private static func runQueryForKeepAlive(
        _ sql: String,
        on service: any DatabaseService
    ) async throws -> Int {
        var rows = 0
        for try await event in service.execute(sql, options: .default) {
            if case .resultSet(let result) = event { rows = result.rows.count }
        }
        return rows
    }

    /// `fk-nav --table T --column C [--value V] [--limit N] [--json]`
    ///
    /// 为什么要扫全库：**反向导航**（谁引用了我）必须知道别的表的外键，
    /// 只看本表约束是查不出来的。小库上这是几十条元数据查询，够用；
    /// 大库要缓存（属后续）。**没有可跳转目标时返回非零** —— 界面据此决定不显示入口。
    private static func runForeignKeyNavCommand(
        arguments: [String],
        service: any DatabaseService
    ) async -> Int32 {
        func value(for flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
                return nil
            }
            return arguments[index + 1]
        }
        guard let table = value(for: "--table"), let column = value(for: "--column") else {
            print("用法：fk-nav --table <表> --column <列> [--schema S] [--value V] [--limit N] [--json]")
            return 64
        }
        let schema = value(for: "--schema") ?? "public"
        let dialect = PostgresDialect()

        func run(_ sql: String) async -> QueryResult? {
            var result: QueryResult?
            do {
                for try await event in service.execute(sql, options: .default) {
                    if case .resultSet(let value) = event { result = value }
                }
            } catch {
                return nil
            }
            return result
        }

        // 1) 列出所有表（反向导航要知道别人）
        guard let tablesResult = await run(dialect.listTablesQuery(database: "", schema: schema)) else {
            print("列不出表（该方言可能不支持）")
            return 66
        }
        let tables = tablesResult.rows.compactMap { row -> String? in
            row.indices.contains(0) ? row[0] : nil
        }

        // 2) 逐表读约束，解析出外键边
        var edges: [ForeignKeyNavigation.Edge] = []
        for name in tables {
            guard let query = dialect.tableConstraintsQuery(table: name, schema: schema),
                  let result = await run(query) else { continue }
            for row in result.rows {
                let constraintName = row.indices.contains(0) ? row[0] : nil
                let kind = (row.indices.contains(1) ? row[1] : nil) ?? ""
                let definition = (row.indices.contains(2) ? row[2] : nil) ?? ""
                if let edge = ForeignKeyNavigation.parseEdge(
                    constraintName: constraintName,
                    kind: kind,
                    definition: definition,
                    table: name,
                    schema: schema,
                    // 同 schema 的引用在 `pg_get_constraintdef` 里是**不带 schema** 的
                    // （`REFERENCES customers(id)`）—— 这里让它继承源表的 schema：
                    // 否则跳转语句会落到 `search_path` 上，换个会话就可能跳错库。
                    defaultSchema: schema
                ) {
                    edges.append(edge)
                }
            }
        }

        let options = ForeignKeyNavigation.options(table: table, column: column, edges: edges, schema: schema)
        let limit = Int(value(for: "--limit") ?? "") ?? 200

        if arguments.contains("--json") {
            let payload: [String: Any] = [
                "table": table,
                "column": column,
                "edges": edges.count,
                "options": options.map { option -> [String: Any] in
                    var item: [String: Any] = [
                        "direction": option.direction.rawValue,
                        "targetTable": option.targetTable,
                        "targetColumn": option.targetColumn,
                        "title": option.title
                    ]
                    if let value = value(for: "--value") {
                        item["query"] = ForeignKeyNavigation.query(
                            option: option, value: value, limit: limit, dialect: dialect
                        )
                    }
                    return item
                }
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                print(text)
                return options.isEmpty ? 1 : 0
            }
        }

        print("外键图：\(edges.count) 条边（扫了 \(tables.count) 张表）")
        guard !options.isEmpty else {
            print("\(table).\(column) 没有可跳转的目标（界面据此不显示入口）")
            return 1
        }
        for option in options {
            print("  " + option.title)
            if let value = value(for: "--value") {
                print("      " + ForeignKeyNavigation.query(
                    option: option, value: value, limit: limit, dialect: dialect
                ))
            }
        }
        return 0
    }

    /// `stats [--limit N] [--json]` —— 表大小 / 索引命中率 / 连接数 / 缓存命中率（FR-DIAG-04）。
    private static func runStatsCommand(
        arguments: [String],
        service: any DatabaseService
    ) async -> Int32 {
        func value(for flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
                return nil
            }
            return arguments[index + 1]
        }
        let limit = Int(value(for: "--limit") ?? "") ?? 20
        let dialect = PostgresDialect()

        // 单条查询失败**不该让整个面板空掉**：四类指标各自独立，能显示几类就显示几类。
        func run(_ metric: DatabaseStats.Metric) async -> QueryResult? {
            guard let sql = dialect.databaseStatsQuery(metric, limit: limit) else { return nil }
            var result: QueryResult?
            do {
                for try await event in service.execute(sql, options: .default) {
                    if case .resultSet(let value) = event { result = value }
                }
            } catch {
                print("（\(metric.displayName) 取不到：\(error.localizedDescription)）")
                return nil
            }
            return result
        }

        var sizes: [DatabaseStats.TableSize] = []
        var scans: [DatabaseStats.TableScans] = []
        var connections = DatabaseStats.ConnectionSummary(byState: [:])
        var cacheHit: DatabaseStats.CacheHit?

        if let result = await run(.tableSizes) { sizes = DatabaseStats.tableSizes(from: result, limit: limit) }
        if let result = await run(.indexHitRate) { scans = DatabaseStats.tableScans(from: result, limit: limit) }
        if let result = await run(.connections) { connections = DatabaseStats.connections(from: result) }
        if let result = await run(.cacheHitRate) { cacheHit = DatabaseStats.cacheHit(from: result) }

        if arguments.contains("--json") {
            let payload: [String: Any] = [
                "tableSizes": sizes.map { ["name": $0.name, "bytes": $0.bytes, "display": $0.displaySize] },
                "indexHitRate": scans.map { scan -> [String: Any] in
                    [
                        "name": scan.name,
                        "seqScan": scan.sequential,
                        "idxScan": scan.index,
                        "ratio": scan.indexHitRatio.map { $0 } as Any
                    ]
                },
                "connections": connections.byState,
                "cacheHit": cacheHit.map { ["hits": $0.hits, "reads": $0.reads, "ratio": $0.ratio as Any] } as Any
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                print(text)
                return 0
            }
        }

        print("表大小（前 \(sizes.count) 张）：")
        for size in sizes { print("  \(size.displaySize)\t\(size.name)") }
        print("索引命中率：")
        for scan in scans { print("  \(scan.displayRatio)\t序扫 \(scan.sequential) / 索引扫 \(scan.index)\t\(scan.name)") }
        print("连接数（合计 \(connections.total)）：")
        for item in connections.ordered { print("  \(item.state)\t\(item.count)") }
        if let cacheHit {
            print("缓存命中率：\(cacheHit.displayRatio)（命中 \(cacheHit.hits) / 读 \(cacheHit.reads)）")
        } else {
            print("缓存命中率：无访问数据")
        }
        return 0
    }

    /// `server-objects <roles|tablespaces|extensions|all> [--limit N] [--json] [--dialect …]`
    /// `server-objects create-role --name <角色名> [--password <口令>] [--nologin] [--superuser] [--host <主机>] [--yes]`
    /// `server-objects drop-role --name <角色名> [--host <主机>] [--yes]`
    /// `server-objects create-extension --name <扩展名> [--schema <schema>] [--version <版本>] [--yes]`
    /// `server-objects drop-extension --name <扩展名> [--yes]`
    ///
    /// 三条纪律，与 Core 的 `ServerObjects` 一一对应：
    /// ① **默认 dry-run**：写操作只打印将要执行的语句 / 风险等级 / 提醒，只有显式 `--yes` 才真执行；
    ///    语句由 `ServerObjects.plan` 生成 —— CLI 不自己拼 SQL，免得与界面两套口径。
    /// ② **不支持就说人话**：方言没有这个概念（GBase 的表空间 / 扩展）时打印 Core 给的中文说明，
    ///    一条 SQL 都不发，返回 3（"环境不具备"与"命令写错"用不同退出码区分，照 slow-queries）。
    /// ③ **输入非法直接拒绝**：空名字 / `a; DROP …` 这类注入名由 Core 的校验挡下，打印可读理由，返回 64。
    ///
    /// `--dialect` 只改变**语句构造用的方言**（默认 postgresql），用来核对"不支持的方言会怎么说话"；
    /// 它不会换连接 —— 拿 GBase 口径的查询去 PG 上跑当然会报错，那是调用方自己的选择。
    private static func runServerObjectsCommand(
        arguments: [String],
        service: any DatabaseService
    ) async -> Int32 {
        func value(for flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
                return nil
            }
            return arguments[index + 1]
        }

        let usage = """
        用法：server-objects <roles|tablespaces|extensions|all> [--limit N] [--json]
              server-objects create-role --name <角色名> [--password <口令>] [--nologin] [--superuser] [--host <主机>] [--yes]
              server-objects drop-role --name <角色名> [--host <主机>] [--yes]
              server-objects create-extension --name <扩展名> [--schema <schema>] [--version <版本>] [--yes]
              server-objects drop-extension --name <扩展名> [--yes]
        [--dialect postgresql|gbase8a] 只影响语句构造（用来核对不支持的方言怎么说话），不换连接。
        写操作**默认只预览**；`--dry-run` 显式预览，只有 `--yes` 才真执行。
        """

        guard let action = arguments.first else {
            print(usage)
            return 64
        }

        let dialect: any ServerObjectDialect
        switch value(for: "--dialect") ?? "postgresql" {
        case "gbase8a": dialect = GBaseServerObjectDialect()
        case "postgresql": dialect = PostgresServerObjectDialect()
        default:
            print("--dialect 只支持 postgresql / gbase8a")
            return 64
        }

        // ① 只读列出：roles / tablespaces / extensions / all
        let requestedKinds: [ServerObjectKind]?
        switch action {
        case "roles": requestedKinds = [.role]
        case "tablespaces": requestedKinds = [.tablespace]
        case "extensions": requestedKinds = [.extension]
        case "all": requestedKinds = ServerObjectKind.allCases
        default: requestedKinds = nil
        }

        if let requestedKinds {
            let limit = Int(value(for: "--limit") ?? "") ?? ServerObjects.defaultLimit
            let isJSON = arguments.contains("--json")

            // 一类一个结果：**不支持的那类不查**，只把 Core 给的说明带上来（不发必然报错的 SQL）。
            var sections: [(kind: ServerObjectKind, objects: [ServerObject], reason: String?, note: String?)] = []
            for kind in requestedKinds {
                let plan = ServerObjects.browsePlan(kind, dialect: dialect, limit: limit)
                guard let sql = plan.sql else {
                    sections.append((kind, [], plan.unsupportedReason, nil))
                    continue
                }
                var result: QueryResult?
                do {
                    for try await event in service.execute(sql, options: .default) {
                        if case .resultSet(let value) = event { result = value }
                    }
                } catch {
                    print("（\(kind.displayName) 读取失败：\(error.localizedDescription)）")
                    sections.append((kind, [], nil, plan.note))
                    continue
                }
                let objects = ServerObjects.objects(
                    from: result ?? QueryResult(columns: [], rows: []),
                    kind: kind
                )
                sections.append((kind, objects, nil, plan.note))
            }

            if isJSON {
                let payload: [String: Any] = [
                    "dialect": dialect.databaseType.rawValue,
                    "sections": sections.map { section -> [String: Any] in
                        var entry: [String: Any] = [
                            "kind": section.kind.rawValue,
                            "objects": section.objects.map { object -> [String: Any] in
                                var item: [String: Any] = ["name": object.name, "summary": object.displaySummary]
                                if let owner = object.owner { item["owner"] = owner }
                                if let comment = object.comment { item["comment"] = comment }
                                if let location = object.location { item["location"] = location }
                                if let bytes = object.sizeBytes { item["bytes"] = bytes }
                                if let version = object.version { item["version"] = version }
                                if let schema = object.schema { item["schema"] = schema }
                                if let canLogin = object.canLogin { item["canLogin"] = canLogin }
                                if let isSuperuser = object.isSuperuser { item["isSuperuser"] = isSuperuser }
                                if let status = object.status { item["status"] = status }
                                return item
                            }
                        ]
                        if let reason = section.reason { entry["unsupported"] = reason }
                        if let note = section.note { entry["approximation"] = note }
                        return entry
                    }
                ]
                if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
                   let text = String(data: data, encoding: .utf8) {
                    print(text)
                    return sections.allSatisfy { $0.reason != nil } ? 3 : 0
                }
            }

            var printedAnything = false
            for section in sections {
                if let reason = section.reason {
                    print("\(section.kind.displayName)：不支持 —— \(reason)")
                    continue
                }
                printedAnything = true
                if let note = section.note { print("说明：\(note)") }
                print("\(section.kind.displayName)（\(section.objects.count) 个）：")
                for object in section.objects {
                    print("  \(object.name)\t\(object.displaySummary)")
                }
            }
            if !printedAnything {
                // 全都是"不支持"：说明已经打印过了，但仍要用退出码把"环境不具备"与"跑通了"分开。
                return 3
            }
            return 0
        }

        // ② 写操作：先生成语句（预览），只有 `--yes` 且没给 `--dry-run` 才执行。
        let request: ServerObjectRequest
        switch action {
        case "create-role":
            guard let name = value(for: "--name") else { print(usage); return 64 }
            request = .createRole(
                RoleSpec(
                    name: name,
                    password: value(for: "--password"),
                    canLogin: !arguments.contains("--nologin"),
                    isSuperuser: arguments.contains("--superuser"),
                    host: value(for: "--host") ?? "%"
                )
            )
        case "drop-role":
            guard let name = value(for: "--name") else { print(usage); return 64 }
            request = .dropRole(name: name, host: value(for: "--host") ?? "%")
        case "create-extension":
            guard let name = value(for: "--name") else { print(usage); return 64 }
            request = .createExtension(
                ExtensionSpec(name: name, schema: value(for: "--schema"), version: value(for: "--version"))
            )
        case "drop-extension":
            guard let name = value(for: "--name") else { print(usage); return 64 }
            request = .dropExtension(name: name)
        default:
            print(usage)
            return 64
        }

        switch ServerObjects.plan(request, dialect: dialect) {
        case .rejected(let reason):
            print("已拒绝：\(reason)")
            return 64

        case .unsupported(let reason):
            print("不支持：\(reason)")
            return 3

        case .ready(let command):
            print("将要执行（\(command.action.displayName) · \(ServerObjects.riskText(command.risk))）：")
            print("  \(command.statement)")
            for warning in command.warnings {
                print("  · \(warning)")
            }

            let shouldExecute = arguments.contains("--yes") && !arguments.contains("--dry-run")
            guard shouldExecute else {
                print("（dry-run：未执行。确认无误后加 --yes 真执行）")
                return 0
            }

            do {
                for try await _ in service.execute(command.statement, options: .default) {}
            } catch {
                print("执行失败：\(error.localizedDescription)")
                return 2
            }
            print("已执行：\(command.statement)")
            return 0
        }
    }

    /// `schema-snapshot [--schema S] [--out <文件>] [--json]`
    private static func runSchemaSnapshotCommand(
        arguments: [String],
        service: any DatabaseService
    ) async -> Int32 {
        func value(for flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
                return nil
            }
            return arguments[index + 1]
        }

        let dialect = PostgresDialect()
        let database = ProcessInfo.processInfo.environment["PGDATABASE"] ?? "postgres"
        let schema = value(for: "--schema") ?? "public"

        do {
            var tables: [TableSnapshot] = []
            var listResult: QueryResult?
            for try await event in service.execute(
                dialect.listTablesQuery(database: database, schema: schema),
                options: .default
            ) {
                if case .resultSet(let result) = event { listResult = result }
            }
            let names = (listResult?.rows ?? []).compactMap { row -> String? in
                row.indices.contains(0) ? row[0] : nil
            }
            for name in names.sorted() {
                guard let structureQuery = dialect.tableStructureQuery(table: name, schema: schema) else { continue }
                var structure: QueryResult?
                for try await event in service.execute(structureQuery, options: .default) {
                    if case .resultSet(let result) = event { structure = result }
                }
                let columns = MetadataService.columnDefinitions(from: structure ?? QueryResult(columns: [], rows: []))
                tables.append(TableSnapshot(schema: schema, name: name, columns: columns))
            }

            let snapshot = SchemaSnapshot(label: "\(database).\(schema)", tables: tables)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            if let out = value(for: "--out") {
                try data.write(to: URL(fileURLWithPath: out))
                print("已导出 \(tables.count) 张表的结构 → \(out)")
                return 0
            }
            print(String(data: data, encoding: .utf8) ?? "")
            return 0
        } catch {
            print("导出结构失败：\(error.localizedDescription)")
            return 66
        }
    }

    /// `er-diagram [--schema S] [--format mermaid|dot|json] [--out 文件] [--layout]`
    ///
    /// 不带 `--layout` 只导出图（文本）；带 `--layout` 额外打印各表的层号与坐标 ——
    /// 布局是纯计算，"同一份输入给同一份输出"这条能靠它一眼看出来，也能进脚本断言。
    private static func runERDiagramCommand(
        arguments: [String],
        service: any DatabaseService
    ) async -> Int32 {
        func value(for flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
                return nil
            }
            return arguments[index + 1]
        }

        let dialect = PostgresDialect()
        let database = ProcessInfo.processInfo.environment["PGDATABASE"] ?? "postgres"
        let schema = value(for: "--schema") ?? "public"
        let format = (value(for: "--format") ?? "mermaid").lowercased()

        do {
            // 表与列：与结构快照同一条口径（一次列清单查询 / 一张表）。
            var snapshots: [TableSnapshot] = []
            var listResult: QueryResult?
            for try await event in service.execute(
                dialect.listTablesQuery(database: database, schema: schema),
                options: .default
            ) {
                if case .resultSet(let result) = event { listResult = result }
            }
            let names = (listResult?.rows ?? []).compactMap { row -> String? in
                guard row.indices.contains(0), let name = row[0], !name.isEmpty else { return nil }
                // 视图也画进来？不：ER 图讲的是"表之间的关系"，视图没有外键约束，画上去只会添乱。
                if row.indices.contains(1), let kind = row[1], kind.uppercased().contains("VIEW") { return nil }
                return name
            }
            for name in names.sorted() {
                guard let structureQuery = dialect.tableStructureQuery(table: name, schema: schema) else { continue }
                var structure: QueryResult?
                for try await event in service.execute(structureQuery, options: .default) {
                    if case .resultSet(let result) = event { structure = result }
                }
                snapshots.append(
                    TableSnapshot(
                        schema: schema,
                        name: name,
                        columns: MetadataService.columnDefinitions(from: structure ?? QueryResult(columns: [], rows: []))
                    )
                )
            }

            // 外键：一次查询取回整个 schema。
            var foreignKeys: QueryResult?
            for try await event in service.execute(
                ERDiagramSource.foreignKeysQuery(schema: schema),
                options: .default
            ) {
                if case .resultSet(let result) = event { foreignKeys = result }
            }

            let diagram = ERDiagramSource.diagram(
                snapshots: snapshots,
                foreignKeys: foreignKeys ?? QueryResult(columns: [], rows: [])
            )

            let output: String
            switch format {
            case "mermaid", "mmd": output = diagram.mermaid()
            case "dot", "graphviz": output = diagram.dot()
            case "json": output = diagram.json()
            default:
                print("不支持的导出格式（mermaid / dot / json）：\(format)")
                return 64
            }

            if let out = value(for: "--out") {
                try output.write(to: URL(fileURLWithPath: out), atomically: true, encoding: .utf8)
                print("已导出 ER 图（\(format)）→ \(out)")
            } else {
                print(output, terminator: "")
            }

            if arguments.contains("--layout") {
                let layout = diagram.layout()
                print("")
                print("布局（父子方向：被引用的一方在上层）")
                for node in layout.nodes {
                    print("  第 \(node.layer) 层 · \(node.table) @ (\(Int(node.x)), \(Int(node.y))) \(Int(node.width))×\(Int(node.height))")
                }
                if !layout.cyclicTables.isEmpty {
                    print("  互相引用（无法拓扑排序，已放到最后）：\(layout.cyclicTables.joined(separator: "、"))")
                }
                print("  画布：\(Int(layout.width)) × \(Int(layout.height))")
            }
            return 0
        } catch {
            print("生成 ER 图失败：\(error.localizedDescription)")
            return 66
        }
    }

    /// `schema-diff --left <快照.json> --right <快照.json> [--allow-drop] [--json]`
    ///
    /// `left` 是**期望**结构，`right` 是**要改**的目标库；脚本把 right 改成 left 的形状。
    private static func runSchemaDiffCommand(arguments: [String]) -> Int32 {
        func value(for flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
                return nil
            }
            return arguments[index + 1]
        }
        guard let leftPath = value(for: "--left"), let rightPath = value(for: "--right") else {
            print("用法：schema-diff --left <期望.json> --right <目标.json> [--allow-drop] [--json]")
            return 64
        }
        let decoder = JSONDecoder()
        guard let left = try? decoder.decode(SchemaSnapshot.self, from: Data(contentsOf: URL(fileURLWithPath: leftPath))),
              let right = try? decoder.decode(SchemaSnapshot.self, from: Data(contentsOf: URL(fileURLWithPath: rightPath))) else {
            print("读取快照失败（需要 schema-snapshot 导出的 JSON）")
            return 66
        }

        let plan = SchemaDiffer.plan(
            left: left,
            right: right,
            allowDrop: arguments.contains("--allow-drop"),
            dialect: PostgresDialect()
        )

        if arguments.contains("--json") {
            let payload: [String: Any] = [
                "identical": plan.isIdentical,
                "diffs": plan.diffs.map { ["table": $0.table.qualifiedName, "kind": $0.summary] },
                "statements": plan.statements,
                "skippedDestructive": plan.skippedDestructive
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                print(text)
                return plan.isIdentical ? 0 : 2
            }
        }

        if plan.isIdentical {
            print("两个结构一致，无需同步")
            return 0
        }

        print("差异 \(plan.diffs.count) 处：")
        for diff in plan.diffs {
            print("  \(diff.table.qualifiedName)：\(diff.summary)")
            for change in diff.columnChanges {
                print("      · \(SchemaDiffer.describe(change))\(change.isDestructive ? "（破坏性）" : "")")
            }
        }
        for skipped in plan.skippedDestructive {
            print("  ⚠️ 跳过：\(skipped)")
        }
        print("同步语句 \(plan.statements.count) 条：")
        for statement in plan.statements { print("  " + statement) }
        return 2   // 有差异（便于脚本判定）
    }

    /// `row-edit --table T [--schema S] [--pk col=value …] [--set col=value …] [--insert col=value,…] [--delete] [--json] [--apply]`
    ///
    /// 默认**只打印将要执行的 DML**（与界面里的"提交前预览"同一份语句）；`--apply` 才在**单个事务**里执行，
    /// 任何一条失败即整批回滚 —— 需求原文的两条设计要点（单事务 / 失败整批回滚）就落在这里。
    private static func runRowEditCommand(
        arguments: [String],
        service: any DatabaseService
    ) async -> Int32 {
        func values(for flag: String) -> [String] {
            var result: [String] = []
            for (index, argument) in arguments.enumerated() where argument == flag {
                if index + 1 < arguments.count { result.append(arguments[index + 1]) }
            }
            return result
        }
        func value(for flag: String) -> String? { values(for: flag).first }

        guard let table = value(for: "--table") else {
            print("用法：row-edit --table <表> [--schema S] [--pk 列=值 …] [--set 列=值 …] [--insert 列=值,…] [--delete] [--json] [--apply]")
            return 64
        }
        let schema = value(for: "--schema")
        let dialect = PostgresDialect()

        // 表结构：主键与列类型都从这里来（不靠猜）
        guard let structureQuery = dialect.tableStructureQuery(table: table, schema: schema) else {
            print("当前方言不支持读取表结构，无法安全生成 DML")
            return 66
        }
        var structureResult: QueryResult?
        do {
            for try await event in service.execute(structureQuery, options: .default) {
                if case .resultSet(let value) = event { structureResult = value }
            }
        } catch {
            print("读取表结构失败：\(error)")
            return 66
        }
        guard let structureResult else {
            print("没有取到表结构")
            return 66
        }
        let definitions = MetadataService.columnDefinitions(from: structureResult)
        guard !definitions.isEmpty else {
            print("表 \(table) 没有列（表名是否正确？）")
            return 1
        }
        let columns = definitions.map {
            InlineEdit.Column(
                name: $0.name,
                typeName: $0.typeName,
                isPrimaryKey: $0.isPrimaryKey,
                isNullable: $0.isNullable
            )
        }

        // 行定位：`--pk 列=值`（可多次，复合主键）
        let primaryKeys = columns.filter(\.isPrimaryKey)
        // 三处 `列=值` 的拆分都带 `omittingEmptySubsequences: false`：Swift 的 `split` 默认
        // **丢掉空子串**，于是 `--set note=` 会被拆成 ["note"] 而不是 ["note", ""] ——
        // 那就没法用命令行表达"空串"（而空串与 NULL 必须能区分，这是本项的设计要点之一）。
        let locator = values(for: "--pk").compactMap { pair -> (String, String)? in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
        // 定位行的值：一律按**主键顺序**取，与 `columnNames` 的登记顺序严格一致 ——
        // 顺序错位会让 WHERE 拼到别的列上（这类错误在预览里几乎看不出来）。
        let locatorValues: [String?] = primaryKeys.map { key in
            locator.first { $0.0.lowercased() == key.name.lowercased() }?.1
        }
        let planRows: [[String?]] = [locatorValues]
        let planColumnNames: [String] = primaryKeys.map(\.name)

        // 改动
        var changes: [InlineEdit.Change] = []
        for assignment in values(for: "--set") {
            let parts = assignment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else {
                print("--set 需要写成 列=值：\(assignment)")
                return 64
            }
            changes.append(.update(rowIndex: 0, column: parts[0], value: typed(parts[1], column: parts[0], columns: columns)))
        }
        if let insertList = value(for: "--insert") {
            var payload: [String: InlineEdit.Value] = [:]
            for pair in insertList.split(separator: ",") {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 2 else {
                    print("--insert 需要写成 列=值,列=值：\(insertList)")
                    return 64
                }
                payload[parts[0]] = typed(parts[1], column: parts[0], columns: columns)
            }
            changes.append(.insert(values: payload))
        }
        if arguments.contains("--delete") {
            guard !primaryKeys.isEmpty else {
                print("这张表没有主键，无法安全删除单行")
                return 3
            }
            changes.append(.delete(rowIndex: 0))
        }
        guard !changes.isEmpty else {
            print("没有改动（用 --set / --insert / --delete）")
            return 64
        }
        let plan = InlineEdit.plan(
            table: table,
            schema: schema,
            columnNames: planColumnNames,
            columns: columns,
            rows: planRows,
            changes: changes,
            dialect: dialect,
            language: .simplifiedChinese
        )

        if arguments.contains("--json") {
            let payload: [String: Any] = [
                "applicable": plan.isApplicable,
                "statements": plan.statements,
                "refusals": plan.refusals
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                print(text)
                return plan.isApplicable ? 0 : 3
            }
        }

        if !plan.refusals.isEmpty {
            for refusal in plan.refusals { print("⚠️ \(refusal)") }
            return 3
        }

        print("将执行 \(plan.statements.count) 条语句：")
        for statement in plan.statements { print("  \(statement);") }

        guard arguments.contains("--apply") else {
            print("（预览模式：加 --apply 才真正执行；执行包在单个事务里，任何一条失败即整批回滚）")
            return 0
        }

        do {
            try await service.beginTransaction()
            for statement in plan.statements {
                for try await _ in service.execute(statement, options: .default) {}
            }
            try await service.commit()
            print("已提交 \(plan.statements.count) 条改动（单个事务）")
            return 0
        } catch {
            try? await service.rollback()
            print("已回滚整批：\(error)")
            return 1
        }
    }

    /// 按**列类型**把命令行里的文本变成类型化的值；`NULL`（不分大小写）表示空值。
    /// 注意空串与 NULL 是两回事：`--set note=` 是空串，`--set note=NULL` 才是 NULL。
    private static func typed(
        _ raw: String,
        column: String,
        columns: [InlineEdit.Column]
    ) -> InlineEdit.Value {
        if raw.uppercased() == "NULL" { return .null }
        let typeName = (columns.first { $0.name.lowercased() == column.lowercased() }?.typeName ?? "").lowercased()
        if typeName.contains("bool") {
            return .boolean(raw.lowercased() == "true" || raw == "1")
        }
        let numeric = ["int", "numeric", "decimal", "real", "double", "float", "serial"].contains { typeName.contains($0) }
        if numeric, Double(raw) != nil { return .number(raw) }
        return .text(raw)
    }

    private static func runObjectSearchCommand(
        arguments: [String],
        service: any DatabaseService
    ) async -> Int32 {
        func value(for flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        let flagsWithValue: Set<String> = ["--schema", "--limit", "--kind"]
        var query: String?
        var skipNext = false
        for argument in arguments {
            if skipNext { skipNext = false; continue }
            if flagsWithValue.contains(argument) { skipNext = true; continue }
            if argument.hasPrefix("--") { continue }
            query = argument
            break
        }
        guard let query, !query.isEmpty else {
            print("用法：search-objects <关键词> [--schema S] [--limit N] [--kind table|view|column|function]")
            return 64
        }

        let limit = Int(value(for: "--limit") ?? "") ?? 200
        guard let sql = ObjectSearch.query(schema: value(for: "--schema")) else {
            print("该数据库类型不支持对象搜索")
            return 65
        }

        var hits: [ObjectSearch.Hit] = []
        do {
            for try await event in service.execute(sql, options: .default) {
                if case .resultSet(let result) = event {
                    hits = ObjectSearch.hits(from: result)
                    // 元数据上限（R-11）：到顶了要**说出来**，不假装搜遍了全库。
                    if result.rows.count >= ObjectSearch.defaultLimit {
                        print("提示：元数据已达 \(ObjectSearch.defaultLimit) 行上限，结果可能不完整")
                    }
                }
            }
        } catch {
            print("搜索失败：\(error.localizedDescription)")
            return 66
        }

        var matches = ObjectSearch.search(query, in: hits, limit: limit)
        if let kindFilter = value(for: "--kind")?.lowercased() {
            matches = matches.filter { $0.hit.kind.rawValue == kindFilter }
        }

        print("在 \(hits.count) 个对象里搜「\(query)」：命中 \(matches.count) 条")
        for match in matches {
            let detail = match.hit.detail.map { "  [\($0)]" } ?? ""
            print("  \(match.hit.kind.rawValue)\t\(match.hit.qualifiedName)\(detail)")
        }
        return matches.isEmpty ? 1 : 0
    }

    /// `import --table <表> --file <文件> [--format csv|tsv|json|xlsx] [--delimiter ,] [--sheet N] [--no-header] [--batch N] [--write]`
    ///
    /// 默认**不写库**：先打印列映射、未匹配的列、非法值样例与将执行的语句 ——
    /// 导入是"一次性把大批数据写进去"的动作，先让人看一眼值得。
    private static func runImportCommand(
        arguments: [String],
        service: any DatabaseService
    ) async -> Int32 {
        func value(for flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        guard let table = value(for: "--table") else {
            print("用法：import --table <表> --file <文件> [--format csv|tsv|json|xlsx] [--delimiter ,] [--sheet N] [--no-header] [--batch N] [--copy] [--write]")
            return 64
        }
        guard let path = value(for: "--file") else {
            print("缺少 --file <文件>")
            return 64
        }

        let format = (value(for: "--format") ?? "csv").lowercased()
        let hasHeader = !arguments.contains("--no-header")
        let delimiter = (value(for: "--delimiter") ?? ",").first ?? ","
        let batchSize = Int(value(for: "--batch") ?? "") ?? TableImport.defaultBatchSize
        let dialect = PostgresDialect()
        let schema = value(for: "--schema")

        // xlsx 是二进制工作簿（ZIP + OOXML），**不走文本编码那条路**（FR-IO-06）。
        let parsed: DelimitedTextReader.Result
        if format == "xlsx" || format == "excel" {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                let sheets = try XLSXReader.sheets(data)
                let requested = Int(value(for: "--sheet") ?? "1") ?? 1
                guard requested >= 1, requested <= sheets.count else {
                    let names = sheets.map(\.name).joined(separator: "、")
                    print("工作表序号超出范围：这个文件有 \(sheets.count) 张表（\(names)）")
                    return 64
                }
                let sheet = sheets[requested - 1]
                parsed = XLSXReader.importResult(from: sheet, hasHeader: hasHeader)
                print("Excel 工作表：\(sheet.name)（第 \(requested) / \(sheets.count) 张，共 \(sheet.rows.count) 行）")
                if !sheet.warnings.isEmpty {
                    print("解析告警：")
                    for warning in sheet.warnings.prefix(5) { print("  · \(warning)") }
                }
            } catch {
                print("读取 Excel 失败：\(error.localizedDescription)")
                return 65
            }
        } else {
            // 编码不猜死 UTF-8（FR-IO-07）：中文 Windows 上 Excel / WPS 另存的 CSV 是 GBK / GB18030，
            // 这里按「BOM → 严格 UTF-8 → GB18030」解码，并把实际用的编码**打印出来**。
            let text: String
            do {
                let decoded = try TextFileDecoder.decode(contentsOf: URL(fileURLWithPath: path))
                text = decoded.text
                if decoded.isFallback {
                    print("文本编码：\(decoded.encoding.displayName)（未检测到 UTF-8 BOM，按中文 Windows 代码页读取）")
                }
            } catch {
                print("读取文件失败：\(error.localizedDescription)")
                return 65
            }
            do {
                if format == "json" {
                    parsed = try DelimitedTextReader.readJSON(text)
                } else {
                    parsed = DelimitedTextReader.read(
                        text,
                        options: DelimitedTextReader.Options(delimiter: delimiter, hasHeader: hasHeader)
                    )
                }
            } catch {
                print("解析失败：\(error.localizedDescription)")
                return 65
            }
        }

        // 目标列：读表结构（与 synth 同一口径）。
        guard let query = dialect.tableStructureQuery(table: table, schema: schema) else {
            print("该数据库类型不支持读表结构，无法做列映射")
            return 65
        }
        var targetColumns: [TableImport.TargetColumn] = []
        do {
            for try await event in service.execute(query, options: .default) {
                if case .resultSet(let result) = event {
                    targetColumns = result.rows.compactMap { row -> TableImport.TargetColumn? in
                        guard row.indices.contains(0), let name = row[0], !name.isEmpty else { return nil }
                        return TableImport.TargetColumn(
                            name: name,
                            typeName: row.indices.contains(1) ? (row[1] ?? "text") : "text",
                            isNullable: (row.indices.contains(2) ? (row[2] ?? "YES") : "YES").uppercased() != "NO"
                        )
                    }
                }
            }
        } catch {
            print("读表结构失败：\(error.localizedDescription)")
            return 66
        }
        guard !targetColumns.isEmpty else {
            print("读不到 \(table) 的列结构（表不存在？）")
            return 66
        }

        let plan = TableImport.plan(
            table: table,
            schema: schema,
            sourceHeader: parsed.header,
            targetColumns: targetColumns,
            batchSize: batchSize,
            sourceLayout: hasHeader ? .byName : .byPosition
        )

        print("文件：\(path)（\(format)，\(parsed.rows.count) 行数据）")
        print("列映射：")
        for mapping in plan.mappings {
            let source = mapping.sourceName ?? "—"
            print("  \(source) → \(mapping.targetName)  [\(plan.valueTypes[mapping.targetName]?.displayName ?? "text")]"
                  + (mapping.sourceIndex == nil ? "  (文件里没有，走默认值 / NULL)" : ""))
        }
        if !plan.unknownSourceColumns.isEmpty {
            print("文件里有、表里没有的列（**会被忽略**）：\(plan.unknownSourceColumns.joined(separator: "、"))")
        }
        if !parsed.warnings.isEmpty {
            print("解析告警（前 3 条）：")
            for warning in parsed.warnings.prefix(3) { print("  · \(warning)") }
        }

        guard !plan.isEmpty else {
            print("没有任何列能映射到目标表，导入中止")
            return 67
        }
        // 必填列缺失 → 提前拒绝（继续写必然失败，且可能写进去一半）。
        if !plan.missingRequiredColumns.isEmpty {
            print("这些必填列在文件里没有对应列：\(plan.missingRequiredColumns.joined(separator: "、"))——导入中止")
            return 67
        }
        let invalid = TableImport.invalidValues(rows: parsed.rows, plan: plan)
        if !invalid.isEmpty {
            print("这些值无法按目标列类型转换（前几条）：")
            for problem in invalid.prefix(5) { print("  · \(problem)") }
            print("（这些单元格会写成 NULL；如不想这样，请先修数据）")
        }

        let batches = TableImport.batches(parsed.rows, size: plan.batchSize)
        print("共 \(parsed.rows.count) 行，分 \(batches.count) 批（每批 \(plan.batchSize) 行）")

        // `--copy`：走 `COPY … FROM STDIN`（FR-IO-03 的快路径）。
        // 值 → text 格式的编码由 `CopyTextFormat` 负责（NULL 写 `\N`、空串写空、反斜杠先转义）。
        if arguments.contains("--copy") {
            let rowsForCopy = TableImport.copyRows(rows: parsed.rows, plan: plan)
            let payload = CopyTextFormat.encode(rows: rowsForCopy)
            // 驱动的 COPY 语句会给表名自己加引号，**表达不了 schema 限定名**；
            // 所以给了 --schema 时先在同一个连接上设 search_path。
            if let schema, !schema.isEmpty {
                do {
                    for try await _ in service.execute(
                        "SET search_path TO \(dialect.quoteIdentifier(schema))",
                        options: .default
                    ) {}
                } catch {
                    print("设置 search_path 失败：\(error.localizedDescription)")
                    return 68
                }
            }
            if !arguments.contains("--write") {
                let preview = payload.split(separator: "\n").prefix(2).joined(separator: "\n")
                print("")
                print("（未加 --write，只输出 COPY 数据前两行编码）")
                print(preview)
                return 0
            }
            let started = Date()
            do {
                try await service.copyFromText(
                    table: table,
                    columns: plan.mappings.compactMap { $0.sourceIndex == nil ? nil : $0.targetName },
                    text: payload
                )
            } catch {
                print("COPY 导入失败：\(error.localizedDescription)")
                print("（COPY 在单个 COPY 语句内是原子的：失败即整批未写入，不会留下半截）")
                return 68
            }
            let elapsed = Date().timeIntervalSince(started)
            print("COPY 写入完成：\(parsed.rows.count) 行，用时 \(String(format: "%.2f", elapsed)) 秒")
            return 0
        }

        if !arguments.contains("--write") {
            if let first = batches.first, let sql = TableImport.insertStatement(rows: first, plan: plan, dialect: dialect) {
                print("")
                print("（未加 --write，只输出第一批语句的前几行）")
                print(sql.split(separator: "\n").prefix(3).joined(separator: "\n"))
            }
            return 0
        }

        var written = 0
        for (index, batch) in batches.enumerated() {
            guard let sql = TableImport.insertStatement(rows: batch, plan: plan, dialect: dialect) else {
                print("第 \(index + 1) 批生成语句失败，中止（已写入 \(written) 行）")
                return 68
            }
            do {
                for try await event in service.execute(sql, options: .default) {
                    if case .resultSet(let result) = event { written += result.affectedRows ?? 0 }
                }
            } catch {
                print("第 \(index + 1) 批写入失败：\(error.localizedDescription)")
                print("已写入 \(written) 行（**前面的批次已生效**，请按需清理）")
                return 68
            }
        }
        print("导入完成：写入 \(written) 行")
        return 0
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
            // `--section pre-data|data|post-data`：分段恢复，失败续跑的基础
            section: value(for: "--section"),
            // `--fail-fast`：遇错即停（续跑时必须开，否则不知道停在哪一段）
            exitOnError: arguments.contains("--fail-fast"),
            rolesOnly: arguments.contains("--roles-only"),
            globalsOnly: arguments.contains("--globals-only"),
            noRolePasswords: arguments.contains("--no-role-passwords"),
            // `--tool` 允许指定绝对路径：GUI / CI 的 PATH 里通常没有 pg_dump（本机就如此）。
            executableName: value(for: "--tool") ?? BackupPlan.defaultExecutable(for: kind)
        )

        // `--restore-sections`：**逐段**恢复（结构 → 数据 → 索引/约束），遇错即停并给出续跑命令。
        // 这是 FR-IO-05 的「失败续跑」入口：一次性 `pg_restore` 失败后，
        // 用户面对的是"半截库 + 一堆错误"，而分段跑能明确停在某一段并告诉他下一步做什么。
        if kind == .restore, arguments.contains("--restore-sections") {
            guard database?.isEmpty == false else {
                print("恢复需要 --database <目标库>")
                return 64
            }
            for section in RestoreSection.allCases {
                var sectionPlan = plan
                sectionPlan.section = section.rawValue
                sectionPlan.exitOnError = true
                print("==> \(section.displayName)")
                print("命令：\(sectionPlan.displayCommand(password: password))")
                if arguments.contains("--dry-run") { continue }
                do {
                    let result = try await BackupExecutor().execute(sectionPlan, password: password) { line in
                        print("  \(line)")
                    }
                    if result.isFailure {
                        print("第 \(section.displayName) 段失败（退出码 \(result.exitCode)）：")
                        print(result.failureSummary ?? "")
                        print(RestoreResume.hint(
                            archivePath: outputPath,
                            database: database ?? "",
                            failed: section,
                            jobs: value(for: "--jobs").flatMap(Int.init),
                            clean: arguments.contains("--clean")
                        ))
                        return 1
                    }
                } catch {
                    print("无法执行：\(error.localizedDescription)")
                    return 68
                }
            }
            print("三段全部完成。")
            return 0
        }

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

        let schema = value(for: "--schema")

        // 文本编码（FR-IO-07）：默认 UTF-8；`gbk` / `gb2312` / `ansi` 都落到 GB18030
        // （它是那三种的超集）。名字不认就**报错退出**，不静默退回 UTF-8 —— 否则用户以为
        // 拿到的是 GBK 文件，实际是一份 GBK 工具打不开的 UTF-8。
        let encoding: ResultExportEncoding
        if let raw = value(for: "--encoding") {
            guard let parsed = ResultExportEncoding.parse(raw) else {
                print("--encoding 只支持 utf8 / gb18030（别名：gbk、gb2312、cp936、ansi）")
                return 64
            }
            encoding = parsed
        } else {
            encoding = .utf8
        }
        if encoding != .utf8 {
            let formatName = (value(for: "--format") ?? "csv").lowercased()
            guard formatName == "csv" else {
                print("--encoding \(encoding.shortName) 只对 csv 生效（json / tsv / markdown / insert / xlsx 固定 UTF-8）")
                return 64
            }
            guard encoding.isAvailable else {
                print("当前系统不支持 \(encoding.shortName) 编码，无法导出")
                return 65
            }
        }

        // 模式一：**整库导出**（FR-IO-02）—— 指定 schema 下的每张表各导出一个文件。
        if arguments.contains("--all-tables") {
            guard let directory = value(for: "--out-dir") else {
                print("整库导出需要 --out-dir <目录>")
                return 64
            }
            return await exportAllTables(
                schema: schema,
                directory: directory,
                formatName: value(for: "--format") ?? "csv",
                fetchSize: Int(value(for: "--fetch-size") ?? "") ?? CursorPaging.defaultPageSize,
                service: service,
                dialect: dialect,
                encoding: encoding
            )
        }

        // 模式二：**整表导出**（FR-IO-02）—— 不用手写 SELECT。
        let explicitQuery = value(for: "--query") ?? value(for: "-c")
        let tableName = value(for: "--table")
        guard let query = explicitQuery ?? tableName.map({ tableSelect($0, schema: schema, dialect: dialect) }) else {
            print("用法：export --query \"SELECT …\" | --table <表> | --all-tables --out-dir <目录>")
            print("      --out <文件> [--format csv / json / tsv / markdown / insert / xlsx] [--fetch-size N] [--schema S]")
            print("      [--encoding utf8 | gb18030]（仅 csv；gb18030 给中文 Windows 的 Excel / WPS）")
            return 64
        }
        guard let outputPath = value(for: "--out") else {
            print("缺少 --out <文件>")
            return 64
        }

        // 每页行数（抽出函数时漏掉了这一行，编译当场报「cannot find 'fetchSize' in scope」）。
        let fetchSize = Int(value(for: "--fetch-size") ?? "") ?? CursorPaging.defaultPageSize

        // `insert` 格式必须有目标表名：否则会生成 `INSERT INTO "table_name"` —— 引用一张
        // 不存在的表（本轮实测踩到：脚本照着"看着对的 SQL"执行，报 relation "table_name" does not exist）。
        // **宁可现在报错，也不要产出坏 SQL**。
        if (value(for: "--format") ?? "csv").lowercased().hasPrefix("insert") || (value(for: "--format") ?? "") == "sql",
           tableName == nil {
            print("insert 格式需要 --table <目标表>（否则生成的是引用 `table_name` 的坏 SQL）")
            return 64
        }

        return await exportQueryToFile(
            query: query,
            outputPath: outputPath,
            formatName: value(for: "--format") ?? "csv",
            fetchSize: fetchSize,
            tableName: tableName ?? "table_name",
            service: service,
            dialect: dialect,
            quiet: false,
            encoding: encoding
        )
    }

    /// 把一条查询用**服务端游标**逐页取、**流式**写进文件（FR-RES-13 / FR-IO-02 共用的那条路）。
    ///
    /// 抽成函数的原因：整库导出要按表重复调用它 —— 复制一遍就等于两处各自演化。
    static func exportQueryToFile(
        query: String,
        outputPath: String,
        formatName: String,
        fetchSize: Int,
        tableName: String,
        service: any DatabaseService,
        dialect: PostgresDialect,
        quiet: Bool,
        encoding: ResultExportEncoding = .utf8
    ) async -> Int32 {
        let format: ResultExportFormat
        switch formatName.lowercased() {
        case "csv": format = .csv
        case "json": format = .json
        case "tsv": format = .tsv
        case "markdown", "md": format = .markdown
        case "insert", "sql": format = .sqlInsert
        case "xlsx", "excel": format = .xlsx
        default:
            print("不支持的格式（csv / json / tsv / markdown / insert / xlsx）")
            return 64
        }
        guard fetchSize > 0 else {
            print("--fetch-size 必须大于 0")
            return 64
        }

        let plan: CursorPagingPlan
        switch CursorPaging.plan(query: query, pageSize: fetchSize) {
        case .success(let value): plan = value
        case .failure(let error):
            print("无法导出：\(error.localizedDescription)")
            return 65
        }

        func run(_ sql: String) async throws -> QueryResult {
            var last: QueryResult?
            for try await event in service.execute(sql, options: .default) {
                if case .resultSet(let result) = event { last = result }
            }
            return last ?? QueryResult(columns: [], rows: [], affectedRows: nil, executionTime: 0,
                                       isTruncated: false, truncationLimit: nil)
        }

        let url = URL(fileURLWithPath: outputPath)
        let fetcher = CursorFetcher(plan: plan, execute: { try await run($0) })
        var writer: ResultStreamWriter?

        // xlsx 是二进制工作簿：ZIP 的中央目录要等所有行写完才能落，**天生不能流式**。
        // 取数仍走服务端游标逐页（不 `SELECT *` 一次拉回），只是把行攒起来一次成型 ——
        // 内存占用与结果集本身同量级，这一点在这里说清楚，不假装它也是流式。
        if format.isBinary {
            do {
                try await fetcher.open()
                var rows: [[String?]] = []
                var columns: [ColumnMeta] = []
                while let page = try await fetcher.nextPage() {
                    if columns.isEmpty { columns = page.columns }
                    rows.append(contentsOf: page.rows)
                }
                await fetcher.close()
                let result = QueryResult(
                    columns: columns,
                    rows: rows,
                    affectedRows: nil,
                    executionTime: 0,
                    isTruncated: false,
                    truncationLimit: nil
                )
                let payload = try ResultExporter.data(for: result, format: format, encoding: encoding)
                try payload.write(to: url)
                if !quiet {
                    print("导出完成：\(rows.count) 行 / \(payload.count) 字节")
                    print("文件：\(url.path)")
                    print("说明：xlsx 是二进制工作簿，需要整份写完才能落盘，因此**按一次性取回导出**（取数仍逐页）。")
                }
                return 0
            } catch {
                await fetcher.close()
                print("导出失败（\(url.lastPathComponent)）：\(error.localizedDescription)")
                return 67
            }
        }

        do {
            try await fetcher.open()
            guard let first = try await fetcher.nextPage() else {
                await fetcher.close()
                if !quiet { print("没有取到任何结果集") }
                return 66
            }

            let streamWriter = ResultStreamWriter(
                targetURL: url,
                format: format,
                columns: first.columns,
                tableName: tableName,
                dialect: dialect,
                encoding: encoding
            )
            writer = streamWriter
            try streamWriter.begin()
            try streamWriter.write(first.rows)
            while let page = try await fetcher.nextPage() {
                try streamWriter.write(page.rows)
            }
            let report = try streamWriter.finish()
            if quiet {
                print("  · \(url.lastPathComponent)：\(report.rowCount) 行 / \(report.byteCount) 字节 / \(await fetcher.pageCount) 页")
            } else {
                print("导出完成：\(report.rowCount) 行 / \(report.byteCount) 字节 / \(await fetcher.pageCount) 页")
                print("文件：\(url.path)")
                print("取数方式：服务端游标逐页（每页 \(fetchSize) 行），内存占用与总行数无关")
                if encoding != .utf8 {
                    // 编码说清楚：GB18030 的文件用 UTF-8 打开就是乱码，用户需要知道为什么。
                    print("文本编码：\(encoding.displayName)")
                }
            }
            return 0
        } catch {
            writer?.abort()
            await fetcher.close()
            print("导出失败（\(url.lastPathComponent)）：\(error.localizedDescription)")
            return 67
        }
    }

    /// 解析 `--param 名字=值[:类型]`（可重复）。
    static func parameterFlags(arguments: [String]) -> [(name: String, value: String, type: SQLParameters.ValueType)] {
        var result: [(String, String, SQLParameters.ValueType)] = []
        var index = 0
        while index < arguments.count {
            if arguments[index] == "--param", index + 1 < arguments.count {
                let raw = arguments[index + 1]
                if let equals = raw.firstIndex(of: "=") {
                    let name = String(raw[..<equals])
                    var rest = String(raw[raw.index(after: equals)...])
                    var type: SQLParameters.ValueType = .text
                    // 类型后缀只在**最后一段**且是已知类型时才切（值里的冒号不该被误切）。
                    if let colon = rest.lastIndex(of: ":") {
                        let suffix = String(rest[rest.index(after: colon)...]).lowercased()
                        if let parsed = SQLParameters.ValueType(rawValue: suffix) {
                            type = parsed
                            rest = String(rest[..<colon])
                        }
                    }
                    result.append((name, rest, type))
                }
                index += 2
                continue
            }
            index += 1
        }
        return result
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
