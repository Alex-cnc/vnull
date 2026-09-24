import Foundation

public struct ServerInfo: Sendable {
    public var version: String
    public var database: String
    public var user: String

    public init(version: String, database: String, user: String) {
        self.version = version
        self.database = database
        self.user = user
    }
}

public protocol DatabaseService: AnyObject, Sendable {
    var config: ConnectionConfig { get }

    func connect() async throws -> ServerInfo
    func disconnect() async

    /// 执行 SQL。**带句柄的版本才是契约入口** —— 停止按钮要能定向到「这一次执行」，
    /// 否则同库另一个页签正在跑的语句会被一起干掉（R-29 / R-30）。
    func execute(
        _ sql: String,
        options: QueryOptions,
        handle: ExecutionHandle
    ) -> AsyncThrowingStream<QueryEvent, Error>

    /// 请求取消某次执行。**返回值必须如实反映结果**：拿不到后端 PID、取消连接建不起来，
    /// 都要作为 `.failed(reason:)` 交给上层显示，绝不静默返回。
    func cancel(_ handle: ExecutionHandle) async -> CancelOutcome

    func beginTransaction() async throws
    func commit() async throws
    func rollback() async throws

    /// 批量导入（FR-IO-03 的 `COPY … FROM STDIN` 路径）：把**已经编码好的 COPY text 格式数据**
    /// 交给服务端流式写入。
    ///
    /// 三条约定：
    /// 1. 编码规则（NULL 写 `\N`、空串写空、反斜杠先转义）由 `CopyTextFormat` 负责 ——
    ///    服务层**不再判定值**，只负责传输；
    /// 2. 不支持的方言**抛可读错误**，绝不"悄悄退回逐条 INSERT"：那会让"用了 COPY"变成一句空话，
    ///    而用户以为是快路径；
    /// 3. `table` 传**裸表名**（不含 schema）：驱动会在 COPY 语句里自己加引号，
    ///    带 schema 的写法请先用 `SET search_path`（见 CLI 的实现）。
    func copyFromText(table: String, columns: [String], text: String) async throws
}

public extension DatabaseService {
    /// 便捷入口：不关心定向取消的调用方（元数据查询、一次性探测）直接用它。
    /// 它内部生成一个**外部无法取消**的句柄 —— 需要「停止」按钮的场景必须显式传句柄。
    func execute(_ sql: String, options: QueryOptions) -> AsyncThrowingStream<QueryEvent, Error> {
        execute(sql, options: options, handle: ExecutionHandle())
    }

    /// 默认：该方言不支持 COPY 导入。**明确报出来**，不静默退化成逐条 INSERT。
    func copyFromText(table: String, columns: [String], text: String) async throws {
        throw AppError.notImplemented("当前方言不支持 COPY 导入（请去掉 --copy，改用批量 INSERT）")
    }
}

public enum DatabaseServiceFactory {
    public static func make(for config: ConnectionConfig, password: String?) -> DatabaseService {
        switch config.dbType {
        case .postgresql:
            return PostgresService(config: config, password: password)
        case .mysql:
            return MySQLService(config: config, password: password)
        case .gbase8a:
            return NotImplementedDatabaseService(config: config, driverName: "MySQLNIO")
        }
    }
}

public final class NotImplementedDatabaseService: DatabaseService, @unchecked Sendable {
    public let config: ConnectionConfig
    private let driverName: String

    public init(config: ConnectionConfig, driverName: String) {
        self.config = config
        self.driverName = driverName
    }

    public func connect() async throws -> ServerInfo {
        throw AppError.notImplemented("\(driverName) 连接")
    }

    public func disconnect() async {
        // 骨架阶段无连接可断开。
    }

    public func execute(
        _ sql: String,
        options: QueryOptions,
        handle: ExecutionHandle
    ) -> AsyncThrowingStream<QueryEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: AppError.notImplemented("\(driverName) 查询执行"))
        }
    }

    public func cancel(_ handle: ExecutionHandle) async -> CancelOutcome {
        // 骨架阶段没有连接，也就没有可取消的执行 —— 如实回答，而不是假装取消成功。
        .notActive
    }

    public func beginTransaction() async throws {
        throw AppError.notImplemented("\(driverName) 事务")
    }

    public func commit() async throws {
        throw AppError.notImplemented("\(driverName) 事务")
    }

    public func rollback() async throws {
        throw AppError.notImplemented("\(driverName) 事务")
    }
}
