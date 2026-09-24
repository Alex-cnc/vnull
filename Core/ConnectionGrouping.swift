import Foundation

/// 连接分组的聚合（FR-CONN-15）。
///
/// 为什么要抽成纯函数：侧边栏的展开 / 折叠状态是按**分组**记的，分组顺序一抖动，
/// 用户刚展开的组就跑到别处去了（或"明明展开着却看着像收起了"）。
/// 所以顺序必须由这里一次定死，界面只负责画。
public enum ConnectionGrouping {

    /// 一个分组段。`group == nil` 表示**未分组**（永远排在最后）。
    public struct Section: Equatable, Sendable, Identifiable {
        public var group: String?
        public var connections: [ConnectionConfig]

        public init(group: String?, connections: [ConnectionConfig]) {
            self.group = group
            self.connections = connections
        }

        public var id: String { group ?? "__ungrouped__" }
        public var isUngrouped: Bool { group == nil }
    }

    /// 未分组的展示名（界面与 CLI 共用一份，避免两处各写一个词）。
    public static let ungroupedTitle = "未分组"

    /// 分组聚合。
    ///
    /// 两条顺序规则（都刻意定死）：
    /// - **分组之间**按组名**本地化自然序**升序（`localizedStandardCompare`）；**未分组永远最后**
    ///   （它是"没整理"的那一堆，不该夹在中间）。
    ///   为什么不用码点排序：中文按码点排出来在用户眼里是乱的（`测` U+6D4B 排在 `生` U+751F 前面），
    ///   而项目其它地方（如结果集文本排序）的既定口径就是本地化自然序。
    /// - **组内保持传入顺序**（不是按名字重排）—— 用户看到的连接顺序应当是他自己排的，
    ///   侧边栏刷新一次就重排会让人找不到东西。
    public static func sections(_ connections: [ConnectionConfig]) -> [Section] {
        var named: [String: [ConnectionConfig]] = [:]
        var ungrouped: [ConnectionConfig] = []
        // 用小写做键去聚合，但**取名时保留首次出现的原始写法**（避免把用户的 "Prod" 显示成 "prod"）。
        var displayNames: [String: String] = [:]

        for connection in connections {
            guard let group = connection.normalizedGroup else {
                ungrouped.append(connection)
                continue
            }
            let key = group.lowercased()
            named[key, default: []].append(connection)
            if displayNames[key] == nil { displayNames[key] = group }
        }

        let sections = named.keys.sorted { lhs, rhs in
            (displayNames[lhs] ?? lhs).localizedStandardCompare(displayNames[rhs] ?? rhs) == .orderedAscending
        }.map { key in
            Section(group: displayNames[key], connections: named[key] ?? [])
        }
        return ungrouped.isEmpty ? sections : (sections + [Section(group: nil, connections: ungrouped)])
    }

    /// 已用过的组名（供表单下拉建议）：大小写不敏感去重、升序；不含"未分组"。
    public static func groupNames(_ connections: [ConnectionConfig]) -> [String] {
        var seen: Set<String> = []
        var names: [String] = []
        for connection in connections {
            guard let group = connection.normalizedGroup else { continue }
            let key = group.lowercased()
            guard seen.insert(key).inserted else { continue }
            names.append(group)
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
