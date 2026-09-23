import Foundation
import PostgresNIO

/// PostgreSQL 实现。
///
/// 驱动层只负责协议传输：连接、认证、发送 SQL、接收结果。
/// PostgreSQL 方言由 `PostgresDialect` 负责，两者不混合。
public actor PostgresService: DatabaseService {
    public nonisolated let config: ConnectionConfig

    private let password: String?
    private let logger = Logger(label: "PostgresService")
    private var connection: PostgresConnection?

    /// 当前连接的服务器端后端进程号。
    ///
    /// PostgreSQL 的取消机制（CancelRequest）要求客户端提供后端 PID；
    /// `pg_cancel_backend(pid)` 同样需要它。连接成功后立即查询并缓存。
    private var backendPID: Int?

    /// 执行注册表：「谁在跑、谁被取消过」的唯一事实源（R-29 / R-30）。
    private let registry = ExecutionRegistryBox()

    public init(config: ConnectionConfig, password: String?) {
        self.config = config
        self.password = password
    }

    public func connect() async throws -> ServerInfo {
        let postgresConfiguration = try makePostgresConfiguration()
        let newConnection = try await PostgresConnection.connect(
            configuration: postgresConfiguration,
            id: 1,
            logger: logger
        )
        self.connection = newConnection

        let version = try await firstString(
            on: newConnection,
            sql: "SHOW server_version"
        ) ?? "unknown"

        let database = try await firstString(
            on: newConnection,
            sql: "SELECT current_database()"
        ) ?? config.database

        let user = try await firstString(
            on: newConnection,
            sql: "SELECT current_user"
        ) ?? config.username

        // 取消能力依赖后端 PID。取不到不阻塞使用，但**必须留痕**：
        // 原来这里是 `try?`，失败后取消按钮会静默无效（用户看到"已取消"而服务端还在跑，R-30）。
        do {
            self.backendPID = try await firstInt(on: newConnection, sql: "SELECT pg_backend_pid()")
            if self.backendPID == nil {
                logger.warning("未取得后端 PID（pg_backend_pid 返回空），本次连接的「停止」将无法下发到服务端")
            }
        } catch {
            self.backendPID = nil
            logger.warning("未取得后端 PID：\(String(describing: error))；本次连接的「停止」将无法下发到服务端")
        }

        return ServerInfo(version: version, database: database, user: user)
    }

    public func disconnect() async {
        if let connection {
            try? await connection.close()
        }
        connection = nil
        backendPID = nil
    }

    public nonisolated func execute(
        _ sql: String,
        options: QueryOptions
    ) -> AsyncThrowingStream<QueryEvent, Error> {
        execute(sql, options: options, handle: ExecutionHandle())
    }

    public nonisolated func execute(
        _ sql: String,
        options: QueryOptions,
        handle: ExecutionHandle
    ) -> AsyncThrowingStream<QueryEvent, Error> {
        // 句柄**在流创建时就登记**：排队期间（actor 正忙）按「停止」也要能记住，
        // 否则轮到时它会照旧执行 —— 这正是 R-30 里"停不住"的一种。
        registry.withLock { $0.enqueue(handle) }

        return AsyncThrowingStream { continuation in
            let producer = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    try await self.performExecute(
                        sql: sql,
                        options: options,
                        handle: handle,
                        continuation: continuation
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            // R-29：消费者一走开（「停止」、页签关闭、上层 `break`、任务取消），
            // 生产端必须停 —— 原来这里是**非结构化** Task 且没有 onTermination，
            // 多语句脚本取消后剩余语句照旧打到数据库上（实测）。
            continuation.onTermination = { _ in
                producer.cancel()
                Task { [weak self] in
                    await self?.cancelInFlight(for: handle)
                }
            }
        }
    }

    /// 服务端取消。
    ///
    /// PostgresNIO 的查询流一旦开始消费，连接就处于忙碌状态；
    /// 因此取消必须在**另一条连接**上发出，否则取消语句只会排在当前语句之后，
    /// 起不到「中断正在执行的查询」的作用。
    ///
    /// 这里采用 `pg_cancel_backend(pid)`：
    /// - 只终止目标语句，不断开连接，用户仍可继续执行下一条；
    /// - PostgreSQL 允许用户取消自己的后端，无需超级用户权限；
    /// - 无需手写 CancelRequest 报文，跨版本行为一致（9.6+）。
    public func cancel(_ handle: ExecutionHandle) async -> CancelOutcome {
        switch registry.withLock({ $0.requestCancel(handle) }) {
        case .cancelActive:
            return await cancelServerSide(handle)
        case .markOnly:
            // 排队中的执行：标记后它一条语句都不会跑，**不去碰别人的语句**。
            logger.debug("取消：该执行尚未开始，已标记为取消")
            return .cancelledBeforeStart
        case .alreadyFinished:
            return .notActive
        }
    }

    /// 消费者走开时的服务端收尾（`onTermination` 调用）。
    private func cancelInFlight(for handle: ExecutionHandle) async {
        if case .cancelActive = registry.withLock({ $0.requestCancel(handle) }) {
            _ = await cancelServerSide(handle)
        }
    }

    /// 向服务端发出取消。**每一种失败都要有名字地返回**（R-30）。
    ///
    /// 必须在**另一条连接**上发：本连接的查询流正忙，取消语句只会排在它后面。
    /// 用 `pg_cancel_backend(pid)` 而不是断连：只终止目标语句，连接与后续操作都还在。
    private func cancelServerSide(_ handle: ExecutionHandle) async -> CancelOutcome {
        guard let pid = backendPID else {
            let reason = "未取得后端 PID，无法向服务端发送取消（该查询可能仍在运行）"
            logger.warning("\(reason)")
            return .failed(reason: reason)
        }

        let configuration: PostgresConnection.Configuration
        do {
            configuration = try makePostgresConfiguration()
        } catch {
            let reason = "取消失败：无法构造连接配置（\(error.localizedDescription)）"
            logger.warning("\(reason)")
            return .failed(reason: reason)
        }

        var cancelConnection: PostgresConnection?
        defer { cancelConnection.map { connection in Task { try? await connection.close() } } }
        do {
            cancelConnection = try await PostgresConnection.connect(
                configuration: configuration,
                id: 2,
                logger: logger
            )
            _ = try await cancelConnection?.query(
                "SELECT pg_cancel_backend(\(pid))",
                []
            ).get()
            return .cancelled
        } catch {
            let reason = "取消请求下发失败：\(error.localizedDescription)"
            logger.warning("\(reason)")
            return .failed(reason: reason)
        }
    }

    public func beginTransaction() async throws {
        try await run("BEGIN")
    }

    public func commit() async throws {
        try await run("COMMIT")
    }

    public func rollback() async throws {
        try await run("ROLLBACK")
    }

    /// 生成 PostgresNIO 连接配置。
    /// 标记为 internal，方便单元测试验证配置映射，而不真的连接数据库。
    func makePostgresConfiguration() throws -> PostgresConnection.Configuration {
        let tls: PostgresConnection.Configuration.TLS

        switch config.sslMode {
        case .disable:
            tls = .disable

        case .allow, .prefer:
            var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
            tlsConfiguration.certificateVerification = .none
            let context = try NIOSSLContext(configuration: tlsConfiguration)
            tls = .prefer(context)

        case .require, .verifyCA, .verifyFull:
            var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
            if config.sslMode == .require {
                tlsConfiguration.certificateVerification = .none
            }
            let context = try NIOSSLContext(configuration: tlsConfiguration)
            tls = .require(context)
        }

        return PostgresConnection.Configuration(
            host: config.host,
            port: config.port,
            username: config.username,
            password: password,
            database: config.database.isEmpty ? nil : config.database,
            tls: tls
        )
    }

    private func performExecute(
        sql: String,
        options: QueryOptions,
        handle: ExecutionHandle,
        continuation: AsyncThrowingStream<QueryEvent, Error>.Continuation
    ) async throws {
        guard let connection else {
            registry.withLock { $0.finish(handle) }
            throw AppError.notConnected
        }

        // 排队期间被取消（用户按了停止）→ **一条语句都不执行**。
        guard registry.withLock({ $0.begin(handle) }) else {
            logger.debug("执行在开始前已被取消，未向服务端发送任何语句")
            continuation.finish()
            return
        }
        defer { registry.withLock { $0.finish(handle) } }

        let statements = StatementSplitter(databaseType: .postgresql).split(sql)
        if statements.isEmpty {
            continuation.yield(.finished(QuerySummary(statementCount: 0, duration: 0)))
            continuation.finish()
            return
        }

        let overallStart = Date()
        var executedCount = 0

        for (index, statement) in statements.enumerated() {
            // R-29 的另一半：**每条语句之前**都要看一次取消状态。
            // 光靠 `onTermination` 停生产 Task 不够 —— 已经排队/正在跑的语句要在这里断开，
            // 否则多语句脚本取消后剩下的语句还会继续打到数据库上。
            if Task.isCancelled || registry.withLock({ $0.isCancelled(handle) }) {
                logger.debug("执行已取消，跳过第 \(index + 1) 条及其后的语句")
                break
            }

            continuation.yield(.started(statementIndex: index))

            let statementStart = Date()

            // 无结果集的 DML：用 EventLoopFuture 版本执行，才能拿到 CommandComplete
            // 中的 command tag（`INSERT 0 3` / `UPDATE 5`），从而显示影响行数。
            if Self.reportsAffectedRows(statement.sql) {
                let queryResult = try await connection.query(statement.sql, []).get()
                let affected = queryResult.metadata.rows

                let result = QueryResult(
                    columns: [],
                    rows: [],
                    affectedRows: affected,
                    executionTime: Date().timeIntervalSince(statementStart)
                )
                // 只发这一个事件：行数随结果对象一起上报（R-32：曾经这里还额外发一次
                // `.affectedRows`，上层两条分支都累加，落盘数字翻倍）。
                continuation.yield(.resultSet(result))
                executedCount += 1
                continue
            }

            let rowSequence = try await connection.query(
                PostgresQuery(unsafeSQL: statement.sql),
                logger: logger
            )

            let columns = rowSequence.columns.enumerated().map { columnIndex, column in
                ColumnMeta(
                    id: columnIndex,
                    name: column.name,
                    typeName: String(describing: column.dataType)
                )
            }

            // 截断由 `ResultCollector` 决定并**留下事实**（R-33）：
            // 到达上限后多拉一行来区分「正好这么多」与「还有更多」，然后停止。
            var collector = ResultCollector(maxRows: options.maxRows)
            for try await row in rowSequence {
                if !collector.append(row.map { PostgresCellFormatter.format($0) }) {
                    break
                }
            }

            let result = collector.makeResult(
                columns: columns,
                executionTime: Date().timeIntervalSince(statementStart)
            )
            continuation.yield(.resultSet(result))
            executedCount += 1
        }

        if Task.isCancelled || registry.withLock({ $0.isCancelled(handle) }) {
            // 取消是"半途而止"，不是正常收尾：不发 `.finished`，让上层走取消路径
            // （App 侧据此记 `succeeded: false`，见 R-31）。
            continuation.finish(throwing: CancellationError())
            return
        }

        continuation.yield(
            .finished(
                QuerySummary(
                    statementCount: executedCount,
                    duration: Date().timeIntervalSince(overallStart)
                )
            )
        )
        continuation.finish()
    }

    private func firstString(
        on connection: PostgresConnection,
        sql: String
    ) async throws -> String? {
        let rowSequence = try await connection.query(
            PostgresQuery(unsafeSQL: sql),
            logger: logger
        )

        for try await row in rowSequence {
            if let cell = row.first {
                return PostgresCellFormatter.format(cell)
            }
        }
        return nil
    }

    private func firstInt(
        on connection: PostgresConnection,
        sql: String
    ) async throws -> Int? {
        guard let text = try await firstString(on: connection, sql: sql) else {
            return nil
        }
        return Int(text)
    }

    /// 判断语句是否应当走「收集影响行数」的执行路径。
    ///
    /// 只覆盖 `INSERT` / `UPDATE` / `DELETE`：
    /// - 这三类语句的 command tag 一定带行数，PostgresNIO 能安全解析；
    /// - 带 `RETURNING` 时仍走流式路径（需要列名，且可能返回大量行）；
    /// - DDL（CREATE/ALTER/DROP/TRUNCATE）在 PostgreSQL 协议里本来就不返回行数。
    /// 标记为 internal，便于单测直接验证判定规则。
    static func reportsAffectedRows(_ sql: String) -> Bool {
        let head = statementHead(sql)
        guard ["insert", "update", "delete"].contains(head.keyword) else { return false }
        return !head.containsReturning
    }

    private static func statementHead(
        _ sql: String
    ) -> (keyword: String, containsReturning: Bool) {
        var remaining = Substring(sql.trimmingCharacters(in: .whitespacesAndNewlines))

        // 跳过前置的行注释与块注释，避免 `-- 注释\nUPDATE ...` 被误判。
        while true {
            if remaining.hasPrefix("--") {
                guard let newline = remaining.firstIndex(of: "\n") else {
                    return ("", false)
                }
                remaining = remaining[remaining.index(after: newline)...]
                    .drop(while: { $0 == " " || $0 == "\t" })
                continue
            }

            if remaining.hasPrefix("/*") {
                guard let end = remaining.range(of: "*/") else {
                    return ("", false)
                }
                remaining = remaining[end.upperBound...]
                    .drop(while: { $0 == " " || $0 == "\t" || $0 == "\n" })
                continue
            }

            break
        }

        let keyword = remaining
            .prefix { $0.isLetter || $0 == "_" }
            .lowercased()

        let upper = sql.uppercased()
        return (keyword, upper.contains("RETURNING"))
    }

    private func run(_ sql: String) async throws {
        guard let connection else {
            throw AppError.notConnected
        }

        let rowSequence = try await connection.query(
            PostgresQuery(unsafeSQL: sql),
            logger: logger
        )
        _ = try await rowSequence.collect()
    }
}
