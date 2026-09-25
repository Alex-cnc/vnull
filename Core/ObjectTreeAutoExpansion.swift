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

/// 什么时候该去**重新查**一个节点的子节点。
///
/// 为什么单独有这条规则（2026-09-25 需求提出者实测，R-59）：**空结果不能被当成"查过了"**。
/// 树原先是 `childrenCache[id] == nil` 才去查，而"加载过但一个子节点都没有"存的是**空数组**
/// —— 它也不是 nil，于是那个节点**再也不会重查**：折叠再展开、点了又点，都停在
/// 「该数据库下暂无表 / 视图」；只有换连接或在本应用里建对象（根节点重载）才会刷新。
/// 别人在别的客户端建了表，用户看到的就是"这软件看不到我的表"。
///
/// 所以：**非空的缓存算数，空的缓存不算** —— 看起来是空的节点每次展开都再问一次服务端
/// （代价只有一次元数据往返，且只在"看起来是空"的那种节点上）。
public enum ObjectTreeReloadPolicy {

    /// - Parameters:
    ///   - cached: 已缓存的子节点（`nil` = 从没查过）。
    ///   - isLoading: 这个节点当前正在查（避免重复发起）。
    public static func shouldLoad(cached: [DatabaseObject]?, isLoading: Bool) -> Bool {
        if isLoading { return false }
        guard let cached else { return true }
        return cached.isEmpty
    }
}
