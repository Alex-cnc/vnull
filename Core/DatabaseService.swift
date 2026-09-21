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

    func execute(_ sql: String, options: QueryOptions) -> AsyncThrowingStream<QueryEvent, Error>
    func cancel() async

    func beginTransaction() async throws
    func commit() async throws
    func rollback() async throws
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

    public func execute(_ sql: String, options: QueryOptions) -> AsyncThrowingStream<QueryEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: AppError.notImplemented("\(driverName) 查询执行"))
        }
    }

    public func cancel() async {
        // 骨架阶段无查询可取消。
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
