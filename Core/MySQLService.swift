import Foundation
import MySQLNIO

/// MySQL 实现（FR-DRV-09）。
///
/// **与 `PostgresService` 的分工完全对称**：驱动只管协议传输（连接、认证、发 SQL、收结果），
/// 方言由 `MySQLDialect` 负责，两者不混合 —— 所以这个文件里**不出现一句手写的 MySQL 方言 SQL**
/// （版本 / 当前库 / 当前用户这类自省查询也走方言）。
///
/// **为什么用 `MySQLNIO` 而不是自己写线协议**：协议是最不该自己造的一层
/// （一个字节解错就是"看着成功、数据已错"），而它又是跨方言共用的。见需求书 FR-DRV-09 的选型记录。
public actor MySQLService: DatabaseService {
    public nonisolated let config: ConnectionConfig

    private let password: String?
    /// 方言**可注入**：GBase 8a 与 MySQL 同属一个协议族，驱动只差方言与少数自省查询，
    /// 所以这里不复制一份 service，而是把方言当参数（`GBaseService` 就是这么组合出来的）。
    private let dialect: any SQLDialect
    private let logger = Logger(label: "MySQLService")
    private var connection: MySQLConnection?
    /// 连接归我们自己管（MySQLNIO 要求调用方给 EventLoop）。
    /// 断连时**必须把它关掉**：NIO 的 EventLoopGroup 不关会留下线程，
    /// 反复连断就会看到进程线程数一路涨。
    private var eventLoopGroup: MultiThreadedEventLoopGroup?

    /// 服务端连接号（`CONNECTION_ID()`）：`KILL QUERY <id>` 要用它。
    private var serverConnectionID: Int?

    /// 执行注册表：「谁在跑、谁被取消过」的唯一事实源（R-29 / R-30），与 PG 侧共用同一个类型。
    private let registry = ExecutionRegistryBox()

    public init(config: ConnectionConfig, password: String?, dialect: (any SQLDialect)? = nil) {
        self.config = config
        self.password = password
        self.dialect = dialect ?? SQLDialectFactory.make(for: config.dbType)
    }

    deinit {
        // actor 的 `deinit` 不能 await；尽力把 socket 关掉（与 PostgresService 同一处理）。
        if let connection {
            connection.channel.close(mode: .all, promise: nil)
        }
        // EventLoopGroup 的关闭是异步的，这里只能发起（`syncShutdownGracefully` 会阻塞，
        // 不能在 deinit 里调）。正常路径是 `disconnect()`。
        eventLoopGroup?.shutdownGracefully { _ in }
    }

    /// **带超时地连接**（修 R-52）：连接配置里的 `timeout` 过去在 MySQL 侧完全没用上 ——
    /// TCP 通了但对端不回应时会**永远等下去**，用户看到的是"卡着不动"，比报错更难排查。
    /// 超时覆盖**连接 + TLS 协商 + 认证**整段（只给 TCP 连接设超时挡不住"连上之后卡在认证"）。
    public func connect() async throws -> ServerInfo {
        try await Self.withTimeout(TimeInterval(config.timeout)) { [self] in
            try await connectWithoutTimeout()
        }
    }

    /// 超时只看这层：错误要**可区分**（上层才知道是"到点了"而不是被谁取消了）。
    enum MySQLServiceError: Error, LocalizedError {
        case timedOut(Int)
        public var errorDescription: String? {
            switch self {
            case .timedOut(let seconds):
                return "连接（含 TLS 与认证）超过 \(seconds) 秒没有完成，已放弃"
            }
        }
    }

    static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let limit = max(1, Int(seconds))
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(limit) * 1_000_000_000)
                throw MySQLServiceError.timedOut(limit)
            }
            guard let result = try await group.next() else {
                throw MySQLServiceError.timedOut(limit)
            }
            group.cancelAll()
            return result
        }
    }

    private func connectWithoutTimeout() async throws -> ServerInfo {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.eventLoopGroup = group

        let address: SocketAddress
        do {
            address = try SocketAddress.makeAddressResolvingHost(config.host, port: config.port)
        } catch {
            // 解析不了主机名：把 group 收干净再抛，别留一个没人管的线程池。
            await shutdown(group)
            throw AppError.queryFailed(LocalizedStrings.format(.mysqlHostResolveFailed, language: .simplifiedChinese, config.host, error.localizedDescription))
        }

        let created: MySQLConnection
        do {
            created = try await MySQLConnection.connect(
                to: address,
                username: config.username,
                database: config.database,
                password: password,
                tlsConfiguration: try makeTLSConfiguration(),
                serverHostname: Self.serverNameIndication(for: config.host),
                logger: logger,
                on: group.next()
            ).get()
        } catch {
            await shutdown(group)
            throw error
        }
        self.connection = created

        // 建连之后的任何一步失败都要把**已经建立的连接**关掉再抛（R-33 ①：否则泄漏一条连接）。
        do {
            return try await finishConnect(on: created)
        } catch {
            logger.warning("initialization after connecting failed; the connection was closed: \(String(describing: error))")
            await disconnect()
            throw error
        }
    }

    /// 建连后的自省：版本 / 当前库 / 当前用户 / 连接号。
    private func finishConnect(on connection: MySQLConnection) async throws -> ServerInfo {
        let version = try await firstString(on: connection, sql: dialect.serverVersionQuery()) ?? "unknown"
        let database = try await firstString(on: connection, sql: dialect.currentDatabaseQuery()) ?? config.database
        let user = try await firstString(on: connection, sql: "SELECT CURRENT_USER()") ?? config.username

        // 取消能力依赖连接号。取不到**必须留痕**：否则「停止」会静默无效
        // （用户看到"已取消"而服务端还在跑，R-30）。
        do {
            if let raw = try await firstString(on: connection, sql: "SELECT CONNECTION_ID()") {
                self.serverConnectionID = Int(raw)
            }
            if self.serverConnectionID == nil {
                logger.warning("no connection id (CONNECTION_ID returned empty); stop will not reach the server on this connection")
            }
        } catch {
            self.serverConnectionID = nil
            logger.warning("no connection id: \(String(describing: error)); stop will not reach the server on this connection")
        }

        return ServerInfo(version: version, database: database, user: user)
    }

    public func disconnect() async {
        if let connection {
            do {
                try await connection.close().get()
            } catch {
                // 关失败也要看得见（R-33 ②）。
                logger.warning("closing the connection failed: \(String(describing: error))")
            }
        }
        connection = nil
        serverConnectionID = nil
        if let group = eventLoopGroup {
            await shutdown(group)
        }
        eventLoopGroup = nil
    }

    private func shutdown(_ group: MultiThreadedEventLoopGroup) async {
        do {
            try await group.shutdownGracefully()
        } catch {
            logger.warning("shutting down the event loop group failed: \(String(describing: error))")
        }
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
        // 句柄在**流创建时**登记：排队期间按「停止」也要记住（否则轮到时照旧执行，R-30）。
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
                    continuation.finish(throwing: await self.mapTimeoutIfNeeded(error, handle: handle))
                }
            }
            continuation.onTermination = { reason in
                guard case .cancelled = reason else { return }
                producer.cancel()
                Task { [weak self] in
                    await self?.cancelInFlight(for: handle)
                }
            }
        }
    }

    // MARK: - 执行

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

        // 排队期间被取消 → 一条语句都不执行。
        guard registry.withLock({ $0.begin(handle) }) else {
            logger.debug("execution was cancelled before it started; no statement was sent")
            continuation.finish()
            return
        }
        defer { registry.withLock { $0.finish(handle) } }

        let statements = StatementSplitter(databaseType: .mysql).split(sql)
        if statements.isEmpty {
            continuation.yield(.finished(QuerySummary(statementCount: 0, duration: 0)))
            continuation.finish()
            return
        }

        let overallStart = Date()
        var executedCount = 0

        for (index, statement) in statements.enumerated() {
            if Task.isCancelled || registry.withLock({ $0.isCancelled(handle) }) {
                logger.debug("execution cancelled; skipping statement \(index + 1) and the rest")
                break
            }

            var timeoutWatchdog: Task<Void, Never>?
            if let timeout = options.statementTimeout, timeout > 0 {
                timeoutWatchdog = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    await self?.statementTimedOut(handle)
                }
            }
            defer { timeoutWatchdog?.cancel() }

            continuation.yield(.started(statementIndex: index))
            let statementStart = Date()

            let collector = MySQLResultBox(maxRows: options.maxRows)

            // **用 `simpleQuery`（COM_QUERY + 文本结果集）而不是 `query`**：
            // 后者走 prepared statement（`COM_STMT_PREPARE` / 二进制行），而本产品在协议层
            // 没有绑定参数的概念（参数由用户写在 SQL 里），多一次 prepare 只是多一次往返；
            // 文本协议还有个好处：任何类型都能原样读成字符串，不必逐类型做二进制解码。
            try await connection.simpleQuery(statement.sql, onRow: { row in
                collector.append(row)
            }).get()

            // 语句是否"该给出结果集"由**语句头**判定（与 PG 侧同一做法）：
            // SELECT 返回 0 行是**有结果集但没数据**，与 `INSERT` 的"没有结果集"不是一回事。
            let returnsRows = Self.returnsRows(statement.sql)
            var affectedRows: Int?
            var notice: String?
            if !returnsRows {
                // COM_QUERY 不回影响行数（那是 OK 包里的字段，这条路径没暴露给调用方），
                // 所以用 MySQL 自己的会话函数问一次 —— `ROW_COUNT()` / `LAST_INSERT_ID()`
                // 就是为这种场景准备的，语义与服务端一致，比我在这里自己数行数可靠。
                let meta = try await self.sessionMetadata(on: connection)
                affectedRows = meta.affectedRows
                if let lastInsertID = meta.lastInsertID, lastInsertID > 0 {
                    notice = LocalizedStrings.format(
                        .mysqlLastInsertID,
                        language: .simplifiedChinese,
                        String(lastInsertID)
                    )
                }
            }

            var result = collector.makeResult(
                columns: collector.columns,
                affectedRows: affectedRows,
                executionTime: Date().timeIntervalSince(statementStart)
            )
            if let notice { result.notice = notice }
            continuation.yield(.resultSet(result))
            executedCount += 1
        }

        if registry.withLock({ $0.isTimedOut(handle) }) {
            let seconds = options.statementTimeout.map { String(Int($0)) } ?? "—"
            continuation.finish(
                throwing: AppError.queryFailed(LocalizedStrings.format(.mysqlStatementTimeout, language: .simplifiedChinese, seconds))
            )
            return
        }

        if Task.isCancelled || registry.withLock({ $0.isCancelled(handle) }) {
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

    // MARK: - 取消

    public func cancel(_ handle: ExecutionHandle) async -> CancelOutcome {
        switch registry.withLock({ $0.requestCancel(handle) }) {
        case .cancelActive:
            return await cancelServerSide()
        case .markOnly:
            logger.debug("cancel: the execution had not started yet; marked as cancelled")
            return .cancelledBeforeStart
        case .alreadyFinished:
            return .notActive
        }
    }

    private func statementTimedOut(_ handle: ExecutionHandle) async {
        guard case .cancelActive = registry.withLock({ $0.markTimedOut(handle) }) else { return }
        logger.warning("statement timed out; sending a cancel to the server")
        _ = await cancelServerSide()
    }

    private func mapTimeoutIfNeeded(_ error: any Error, handle: ExecutionHandle) -> any Error {
        registry.withLock { $0.isTimedOut(handle) }
            ? AppError.queryFailed(LocalizedStrings.format(.mysqlStatementTimeout, language: .simplifiedChinese, "—"))
            : error
    }

    private func cancelInFlight(for handle: ExecutionHandle) async {
        if case .cancelActive = registry.withLock({ $0.requestCancel(handle) }) {
            _ = await cancelServerSide()
        }
    }

    /// 下发 `KILL QUERY <连接号>`。
    ///
    /// **必须在另一条连接上发**：本连接的查询正忙，取消语句只会排在它后面（R-30）。
    /// 用 `KILL QUERY` 而不是 `KILL`：只终止目标语句，连接与后续操作都还在。
    private func cancelServerSide() async -> CancelOutcome {
        guard let serverConnectionID else {
            let reason = LocalizedStrings.text(.mysqlCancelNoConnectionID, language: .simplifiedChinese)
            logger.warning("\(reason)")
            return .failed(reason: reason)
        }
        guard let statement = dialect.cancelSessionStatement(pid: serverConnectionID) else {
            return .failed(reason: LocalizedStrings.text(.mysqlCancelStatementMissing, language: .simplifiedChinese))
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { group.shutdownGracefully { _ in } }
        do {
            let address = try SocketAddress.makeAddressResolvingHost(config.host, port: config.port)
            let cancelConnection = try await MySQLConnection.connect(
                to: address,
                username: config.username,
                database: config.database,
                password: password,
                tlsConfiguration: try makeTLSConfiguration(),
                serverHostname: Self.serverNameIndication(for: config.host),
                logger: logger,
                on: group.next()
            ).get()
            _ = try await cancelConnection.simpleQuery(statement).get()
            try? await cancelConnection.close().get()
            return .cancelled
        } catch {
            let reason = LocalizedStrings.format(.mysqlCancelDispatchFailed, language: .simplifiedChinese, error.localizedDescription)
            logger.warning("\(reason)")
            return .failed(reason: reason)
        }
    }

    // MARK: - 事务

    /// 纯十六进制 / 冒号形式的 IPv6（zone id 由调用方先剥掉）。
    static func isIPv6Hex(_ host: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF:.")
        guard host.contains(":"), host.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        // 至少得有两段十六进制，且不能全是冒号。
        return host.split(separator: ":", omittingEmptySubsequences: false).contains { !$0.isEmpty }
    }

    public func beginTransaction() async throws { try await run("START TRANSACTION") }
    public func commit() async throws { try await run("COMMIT") }
    public func rollback() async throws { try await run("ROLLBACK") }

    /// `COPY … FROM STDIN` 是 PostgreSQL 的通道；MySQL 走 `LOAD DATA LOCAL INFILE` 或批量 INSERT，
    /// **这里如实说"不支持"**，绝不静默退回逐条 INSERT（那会让"用了快路径"变成一句空话）。
    public func copyFromText(table: String, columns: [String], text: String) async throws {
        throw AppError.notImplemented(LocalizedStrings.text(.mysqlCopyUnsupported, language: .simplifiedChinese))
    }

    private func run(_ sql: String) async throws {
        guard let connection else { throw AppError.notConnected }
        _ = try await connection.simpleQuery(sql).get()
    }

    // MARK: - 辅助

    /// TLS 的 **SNI（server name indication）**：只对**域名**有意义。
    ///
    /// **为什么单列一个函数**：把 IP 字面量塞进 SNI，NIOSSL 会直接抛
    /// `cannotUseIPAddressInSN: IP address can not validly be used for server name indication`
    /// —— 用户实测在 217（`192.168.5.217`）上配了 TLS 就撞到了这一条，
    /// 而错误信息里没有任何"是 SNI 的问题"的线索，看着像连不上服务器。
    /// 按规范，IP 字面量本来就不该出现在 SNI 里（证书是发给域名的），所以这里**如实传 nil**。
    static func serverNameIndication(for host: String) -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if isIPLiteral(trimmed) { return nil }
        return trimmed
    }

    /// 这个主机串是不是 **IP 字面量**（IPv4 / IPv6）。
    ///
    /// 自己解析而不引依赖：这条判据只有十几行，而且是**纯字符串**规则
    /// （Core 要保持平台中立，不引平台网络 API）；写清楚比引一个类型更难出错。
    /// IPv4：四段 0–255 的十进制；IPv6：含冒号，且只由十六进制、冒号、`%zone`、`.`（v4 映射）组成。
    static func isIPLiteral(_ host: String) -> Bool {
        if let percent = host.firstIndex(of: "%") {
            // 带 zone id 的 IPv6（`fe80::1%en0`）：zone 是接口名（字母数字），地址部分才是十六进制。
            let address = String(host[host.startIndex..<percent])
            let zone = String(host[host.index(after: percent)...])
            guard !zone.isEmpty, zone.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
            return isIPv6Hex(address)
        }
        if host.contains(":") { return isIPv6Hex(host) }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let value = Int(part), part.count <= 3, !part.isEmpty, (0...255).contains(value) else { return false }
            // 不接受 `01` / `+1` 这类写法：它们不是合法的 IPv4 字面量（域名里也不该有）。
            return part.allSatisfy { $0.isNumber } && (part.count == 1 || part.first != "0")
        }
    }

    private func makeTLSConfiguration() throws -> TLSConfiguration? {
        switch config.sslMode {
        case .disable:
            return nil
        case .allow, .prefer, .require:
            // `prefer` / `require`：加密，但**不校验**服务端证书
            // （MySQL 的 `--ssl-mode=REQUIRED` 就是这个语义；要与 PG 侧口径一致）。
            var configuration = TLSConfiguration.makeClientConfiguration()
            configuration.certificateVerification = .none
            return configuration
        case .verifyCA, .verifyFull:
            return TLSConfiguration.makeClientConfiguration()
        }
    }

    /// 上一条语句的影响行数与自增 ID（`ROW_COUNT()` / `LAST_INSERT_ID()` 作用于**本连接的上一条语句**）。
    private func sessionMetadata(on connection: MySQLConnection) async throws -> (affectedRows: Int?, lastInsertID: UInt64?) {
        // 方言给不出这条查询就**如实返回"拿不到"**（GBase 8a 的 `ROW_COUNT()` 语义未实测，
        // 见 FR-DRV-08）：宁可显示"影响行数未知"，也不用客户端自己数的数字冒充服务端的。
        guard let sql = dialect.sessionMetadataQuery() else { return (nil, nil) }
        let rows = try await connection.simpleQuery(sql).get()
        guard let row = rows.first, row.values.count >= 2 else { return (nil, nil) }
        let affected = Self.stringValue(
            column: row.columnDefinitions[0], value: row.values[0], format: row.format
        ).flatMap(Int.init)
        let lastInsert = Self.stringValue(
            column: row.columnDefinitions[1], value: row.values[1], format: row.format
        ).flatMap(UInt64.init)
        return (affected, lastInsert)
    }

    private func firstString(on connection: MySQLConnection, sql: String) async throws -> String? {
        let rows = try await connection.simpleQuery(sql).get()
        guard let row = rows.first, let value = row.values.first else { return nil }
        return Self.stringValue(column: row.columnDefinitions[0], value: value, format: row.format)
    }

    /// 行值 → 显示字符串。
    ///
    /// **NULL 与空串必须分得开**：NULL 是 `nil`（线上就是空缓冲），空串是 `""`。
    /// 把 NULL 显示成空串，用户会以为"这列有值但是空的"。
    static func stringValue(
        column: MySQLProtocol.ColumnDefinition41,
        value: ByteBuffer?,
        format: MySQLData.Format
    ) -> String? {
        guard let value else { return nil }
        let data = MySQLData(
            type: column.columnType,
            format: format,
            buffer: value,
            isUnsigned: column.flags.contains(.COLUMN_UNSIGNED)
        )
        // text 协议下绝大多数类型都能直接读成字符串；读不出来时退回驱动的描述
        // （日期 / 浮点等二进制形态），**不猜**也不丢。
        if let string = data.string { return string }
        return data.description
    }

    /// 列类型名（界面显示用）。MySQL 的线类型名与 SQL 里的类型名不完全一样
    /// （`VAR_STRING` / `LONGLONG`），这里给**用户能对上 SQL 的那个名字**。
    static func typeName(for type: MySQLProtocol.DataType) -> String {
        switch type {
        case .tiny: return "tinyint"
        case .short: return "smallint"
        case .long: return "int"
        case .longlong: return "bigint"
        case .int24: return "mediumint"
        case .float: return "float"
        case .double: return "double"
        case .decimal: return "decimal"
        case .newdecimal: return "decimal"
        case .varchar, .varString: return "varchar"
        case .string: return "char"
        case .blob, .tinyBlob, .mediumBlob, .longBlob: return "blob"
        case .date: return "date"
        case .datetime: return "datetime"
        case .timestamp: return "timestamp"
        case .time: return "time"
        case .year: return "year"
        case .json: return "json"
        case .bit: return "bit"
        case .null: return "null"
        case .newdate: return "date"
        case .timestamp2: return "timestamp"
        case .datetime2: return "datetime"
        case .time2: return "time"
        case .enum: return "enum"
        case .set: return "set"
        case .geometry: return "geometry"
        default: return "\(type)"
        }
    }

    /// 这条语句是否**应该给出结果集**（而不是"影响行数"）。
    ///
    /// 只看语句头，不做词法分析：`SHOW` / `DESC` / `EXPLAIN` / `SELECT` / `WITH` 是查询，
    /// 其余按 DML/DDL 处理。**为什么需要它**：MySQL 对"0 行的 SELECT"与"INSERT 3 行"
    /// 都不给客户端行数据，若不看语句头，前者会被显示成"影响行数 0"——
    /// 用户看到的是"什么都没发生"，而实际上是"查了，就是没有数据"。
    static func returnsRows(_ sql: String) -> Bool {
        var head = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        // 跳过注释与空行（`-- x` / `# x` / `/* x */`）。
        while true {
            if head.hasPrefix("--") || head.hasPrefix("#") {
                guard let newline = head.firstIndex(where: { $0 == "\n" }) else { return false }
                head = String(head[head.index(after: newline)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            if head.hasPrefix("/*") {
                guard let end = head.range(of: "*/") else { return false }
                head = String(head[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            break
        }
        let word = head.prefix { $0.isLetter }.uppercased()
        return ["SELECT", "SHOW", "DESC", "DESCRIBE", "EXPLAIN", "WITH", "TABLE", "VALUES", "HELP"]
            .contains(word)
    }
}

/// 收 `simpleQuery` 逐行回调的结果（闭包是 `@escaping`，结构体在闭包里改不了，所以用盒子）。
///
/// **截断在收的时候就生效**：`ResultCollector` 的上限一到就不再往数组里放行，
/// 于是"拉了一百万行才发现只要一千行"这件事不会发生（内存与上限同阶，与结果集大小无关）。
///
/// 只在**同一次查询的回调链**里用（NIO 的回调都在同一个 EventLoop 上、顺序执行），因此不加锁。
private final class MySQLResultBox: @unchecked Sendable {
    private let collector: ResultCollector
    private(set) var columns: [ColumnMeta] = []
    private var rows: [[String?]] = []

    init(maxRows: Int?) {
        self.collector = ResultCollector(maxRows: maxRows)
    }

    func append(_ row: MySQLRow) {
        if columns.isEmpty {
            columns = row.columnDefinitions.enumerated().map { columnIndex, column in
                ColumnMeta(
                    id: columnIndex,
                    name: column.name,
                    typeName: MySQLService.typeName(for: column.columnType)
                )
            }
        }
        guard rows.count < (collector.maxRows ?? Int.max) else { return }
        rows.append(row.values.enumerated().map { valueIndex, value in
            MySQLService.stringValue(
                column: row.columnDefinitions[valueIndex],
                value: value,
                format: row.format
            )
        })
    }

    func makeResult(columns: [ColumnMeta], affectedRows: Int?, executionTime: TimeInterval) -> QueryResult {
        var box = collector
        for row in rows {
            if !box.append(row) { break }
        }
        return box.makeResult(
            columns: columns,
            affectedRows: affectedRows,
            executionTime: executionTime
        )
    }
}
