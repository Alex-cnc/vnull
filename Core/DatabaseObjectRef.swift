import Foundation

/// 一张表的**最小引用**（schema + 表名）。
///
/// 为什么不用现成的 `DatabaseObject`：那个类型带着 id、kind、是否可展开等界面属性，
/// 而这里只需要"结果集是从哪张表来的"这一个事实 —— 用它当 `QueryTab` 的字段会让
/// 结果集平白依赖对象树的模型。也刻意不带连接 id：跨连接的同名表不是同一张表，
/// 要判断时必须显式带上当前连接，而不是让一个轻量结构**看起来**能表达这件事。
public struct DatabaseObjectRef: Equatable, Hashable, Sendable {

    /// schema（可为空：某些方言没有 schema 概念，或查询走的默认 search_path）。
    public var schema: String?
    /// 表名。
    public var name: String

    public init(schema: String?, name: String) {
        self.schema = schema
        self.name = name
    }

    /// 供缓存键与日志用：`public.orders` / `orders`。
    public var qualifiedName: String {
        guard let schema, !schema.isEmpty else { return name }
        return "\(schema).\(name)"
    }
}
