import Foundation

/// 连上之后对象树**自动展开到哪一级**（默认展开策略）。
///
/// 为什么需要它：元数据的层级是「服务器 → 数据库 → schema → 表」，而展开状态是**视图本地**的
/// （`ObjectTreeView.expandedIDs`），每次连接 / 刷新都从「全部折叠」开始。于是刚连上时
/// 用户看到的只是**服务器**一个节点；展开它是**一列库名**（本机这台有 23 个），
/// 而自己那张表还要再点两三次才出现 —— 实测反馈正是「连上了，但那么多数据库里没看到 customers」
/// （`customers` 是**表**，住在连接自己那个库里）。
///
/// 规则收敛成两句话，做成纯函数以便单测（视图只负责把名字喂进来）：
///   ① 展开**连接自己那个库** —— 别的库不是"我们的"，不自动展开，免得每次连接都去打别人的元数据；
///   ② 它下面展开 **`public`**（只有一个 schema 时就是那一个；有多个又都没有 `public` 时**不猜**，
///      留给人点 —— 猜错会把用户带到另一个 schema 里）。
public enum ObjectTreeAutoExpansion {

    /// 根节点（服务器）下面，哪个**数据库**该自动展开。
    ///
    /// 只在连接配置里的库确实出现在列表里时才展开：连不上 / 没有权限 / 名字写错时，
    /// 列表里就没有它，此时展开任何一个别的库都是误导。
    public static func database(in names: [String], connectionDatabase: String?) -> String? {
        guard let connectionDatabase, !connectionDatabase.isEmpty else { return nil }
        return names.contains(connectionDatabase) ? connectionDatabase : nil
    }

    /// 数据库节点下面，哪个 **schema** 该自动展开。
    public static func schema(in names: [String]) -> String? {
        if names.contains("public") { return "public" }
        return names.count == 1 ? names.first : nil
    }
}
