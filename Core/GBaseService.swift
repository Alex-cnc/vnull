import Foundation

/// GBase 8a 实现（FR-DRV-08）。
///
/// **为什么是组合而不是复制**：GBase 8a 与 MySQL 同属一个协议族 —— 认证握手、包分帧、
/// 结果集解码、取消（`KILL QUERY`）全都一样，差别只在**方言**与少数自省语义。
/// 所以这里把驱动**委托**给方言可注入的 `MySQLService`（`GBaseDialect`），
/// 而不是再写一份 400 行的 service：复制出去的每一行，将来都要在两边各修一次。
///
/// **哪些是"照搬"、哪些还没验（如实写）**：
///   · 照搬且**离线可验**：连接与自省走 `GBaseDialect`（`SELECT VERSION()` / `SELECT DATABASE()`，
///     GBase 8a 兼容 MySQL 语法）、树形结构是四层（服务器 → Database → Table → Column，**无 schema 层**）、
///     取消走 `KILL QUERY`、事务走 `START TRANSACTION` / `COMMIT` / `ROLLBACK`；
///   · **未验**：真实 GBase 8a 实例上的一切（认证方式、`SHOW TABLES` 的列名、`DESC` 的输出列、
///     `KILL QUERY` 的权限、版本号形态）。本机没有实例，端到端 0 次 —— 这一格在需求书里如实登记，
///     不因为"协议同族"就默认通过（R-22 的纪律：缺实例的版本不得默认判定通过）。
///   · **刻意留空**：建库权限探测（`GBaseDialect` 返回 nil，G-17）；影响行数 / 自增 ID 的
///     会话函数（`sessionMetadataQuery` 默认 nil）—— 于是 GBase 上显示"影响行数未知"，
///     而不是拿客户端自己数的数字冒充服务端的。
public actor GBaseService: DatabaseService {
    public nonisolated let config: ConnectionConfig

    /// 真正干活的驱动（方言已注入为 `GBaseDialect`）。
    private let driver: MySQLService

    public init(config: ConnectionConfig, password: String?) {
        self.config = config
        self.driver = MySQLService(config: config, password: password, dialect: GBaseDialect())
    }

    public func connect() async throws -> ServerInfo {
        try await driver.connect()
    }

    public func disconnect() async {
        await driver.disconnect()
    }

    public nonisolated func execute(
        _ sql: String,
        options: QueryOptions
    ) -> AsyncThrowingStream<QueryEvent, Error> {
        driver.execute(sql, options: options)
    }

    public nonisolated func execute(
        _ sql: String,
        options: QueryOptions,
        handle: ExecutionHandle
    ) -> AsyncThrowingStream<QueryEvent, Error> {
        driver.execute(sql, options: options, handle: handle)
    }

    public func cancel(_ handle: ExecutionHandle) async -> CancelOutcome {
        await driver.cancel(handle)
    }

    public func beginTransaction() async throws {
        try await driver.beginTransaction()
    }

    public func commit() async throws {
        try await driver.commit()
    }

    public func rollback() async throws {
        try await driver.rollback()
    }

    public func copyFromText(table: String, columns: [String], text: String) async throws {
        try await driver.copyFromText(table: table, columns: columns, text: text)
    }
}
