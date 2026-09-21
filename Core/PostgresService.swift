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

        // 取消能力依赖后端 PID；查询失败不影响正常使用，只是退化为「仅取消本地等待」。
        self.backendPID = try? await firstInt(
            on: newConnection,
            sql: "SELECT pg_backend_pid()"
        )

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
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.performExecute(
                        sql: sql,
                        options: options,
                        continuation: continuation
                    )
                } catch {
                    continuation.finish(throwing: error)
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
    public func cancel() async {
        guard let pid = backendPID else { return }

        let configuration: PostgresConnection.Configuration
        do {
            configuration = try makePostgresConfiguration()
        } catch {
            logger.warning("取消查询失败：无法构造连接配置，\(String(describing: error))")
            return
        }

        var cancelConnection: PostgresConnection?
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
        } catch {
            logger.warning("取消查询失败：\(String(describing: error))")
        }

        if let cancelConnection {
            try? await cancelConnection.close()
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
        continuation: AsyncThrowingStream<QueryEvent, Error>.Continuation
    ) async throws {
        guard let connection else {
            throw AppError.notConnected
        }

        let statements = StatementSplitter(databaseType: .postgresql).split(sql)
        if statements.isEmpty {
            continuation.yield(.finished(QuerySummary(statementCount: 0, duration: 0)))
            continuation.finish()
            return
        }

        let overallStart = Date()
        var executedCount = 0

        for (index, statement) in statements.enumerated() {
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
                continuation.yield(.resultSet(result))
                if let affected {
                    continuation.yield(.affectedRows(affected))
                }
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

            var rows: [[String?]] = []
            for try await row in rowSequence {
                rows.append(row.map { PostgresCellFormatter.format($0) })
                if let maxRows = options.maxRows, rows.count >= maxRows {
                    break
                }
            }

            let result = QueryResult(
                columns: columns,
                rows: rows,
                executionTime: Date().timeIntervalSince(statementStart)
            )
            continuation.yield(.resultSet(result))
            executedCount += 1
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
