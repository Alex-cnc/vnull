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
}

public extension DatabaseService {
    /// 便捷入口：不关心定向取消的调用方（元数据查询、一次性探测）直接用它。
    /// 它内部生成一个**外部无法取消**的句柄 —— 需要「停止」按钮的场景必须显式传句柄。
    func execute(_ sql: String, options: QueryOptions) -> AsyncThrowingStream<QueryEvent, Error> {
        execute(sql, options: options, handle: ExecutionHandle())
    }
}

public enum DatabaseServiceFactory {
    public static func make(for config: ConnectionConfig, password: String?) -> DatabaseService {
        switch config.dbType {
        case .postgresql:
            return PostgresService(config: config, password: password)
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
