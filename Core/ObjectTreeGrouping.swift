import Foundation

/// 一个「按类型」聚合出的虚拟分组（FR-META-15）。
public struct ObjectTypeGroup: Identifiable, Hashable, Sendable {
    /// 稳定 id，形如 `group:<父节点 id>:<类型>`。
    ///
    /// 带上父节点是为了让**多个已展开的容器**各自的分组标题在扁平化行列表里 id 不冲突
    /// （SwiftUI 的 `ForEach` 要求 id 唯一）。
    public let id: String
    /// 分组对应的对象类型；「其他」分组为 `nil`。
    public let kind: DatabaseObject.Kind?
    /// 组内对象，保持传入顺序。
    public let objects: [DatabaseObject]
    /// 组内出现过的 schema（去重、升序）—— 满足「保持 schema 归属」。
    public let schemas: [String]

    public var count: Int { objects.count }

    /// 组标题（随界面语言）。
    public func title(language: AppLanguage) -> String {
        ObjectTreeGrouping.title(for: kind, language: language)
    }

    /// 行上显示的名字：组内**跨越多个 schema** 时补 `schema.` 前缀，
    /// 否则重名对象（`public.orders` 与 `sales.orders`）在分组视图里看起来会一模一样。
    public func displayName(for object: DatabaseObject) -> String {
        guard schemas.count > 1, let schema = object.schema, !schema.isEmpty else {
            return object.name
        }
        return "\(schema).\(object.name)"
    }
}

/// 对象树「按类型分组」视图（FR-META-15）。
///
/// 纯函数：输入**已经加载好的**同级对象数组，输出分组结果。
/// 因此切换视图只是对缓存做一次重新聚合，**不触发任何重新查库**
/// —— 这正是验收要点「切换不触发全量重查」的落地方式。
public enum ObjectTreeGrouping {

    /// 分组展示顺序：表 → 视图 → 序列 → 函数 →（其余归入「其他」）。
    ///
    /// 这里是「常见类型优先、其余兜底」而不是把 8 个 `Kind` 全列一遍：
    /// 容器节点的子对象实际只有这四类，`server` / `database` / `schema` / `column`
    /// 落到兜底分组里即可，不必为它们各写一条文案。
    public static let preferredKinds: [DatabaseObject.Kind] = [.table, .view, .sequence, .function]

    /// 按类型聚合同级对象。
    ///
    /// - Parameters:
    ///   - objects: 已加载的同级对象（通常是某个已展开节点的子节点缓存）。
    ///   - parentID: 父节点 id，用于生成不冲突的分组 id。
    ///   - language: 生成分组标题所用语言。
    public static func groupedByType(
        _ objects: [DatabaseObject],
        parentID: String? = nil,
        language: AppLanguage = .simplifiedChinese
    ) -> [ObjectTypeGroup] {
        guard !objects.isEmpty else { return [] }

        let prefix = parentID ?? "-"

        var buckets: [DatabaseObject.Kind: [DatabaseObject]] = [:]
        var others: [DatabaseObject] = []
        for object in objects {
            if preferredKinds.contains(object.kind) {
                buckets[object.kind, default: []].append(object)
            } else {
                others.append(object)
            }
        }

        var groups: [ObjectTypeGroup] = []
        for kind in preferredKinds {
            guard let items = buckets[kind], !items.isEmpty else { continue }
            groups.append(makeGroup(kind: kind, id: "group:\(prefix):\(kind.rawValue)", objects: items))
        }
        if !others.isEmpty {
            groups.append(makeGroup(kind: nil, id: "group:\(prefix):other", objects: others))
        }
        return groups
    }

    /// 分组标题文案。
    public static func title(for kind: DatabaseObject.Kind?, language: AppLanguage) -> String {
        switch kind {
        case .table: return LocalizedStrings.text(.treeGroupTable, language: language)
        case .view: return LocalizedStrings.text(.treeGroupView, language: language)
        case .sequence: return LocalizedStrings.text(.treeGroupSequence, language: language)
        case .function: return LocalizedStrings.text(.treeGroupFunction, language: language)
        default: return LocalizedStrings.text(.treeGroupOther, language: language)
        }
    }

    /// 界面在分组视图下画表头用的图标类型。
    ///
    /// 「其他」分组没有对应 `Kind`，用 `.column` 作中性图标 / 颜色（`symbolName` 与
    /// `color(for:)` 都按 `Kind` 取，构造一个合成节点是这里最省事又不失真的做法）。
    public static func headerKind(for kind: DatabaseObject.Kind?) -> DatabaseObject.Kind {
        kind ?? .column
    }

    private static func makeGroup(
        kind: DatabaseObject.Kind?,
        id: String,
        objects: [DatabaseObject]
    ) -> ObjectTypeGroup {
        let schemas = Array(
            Set(objects.compactMap { object -> String? in
                guard let schema = object.schema, !schema.isEmpty else { return nil }
                return schema
            })
        ).sorted()
        return ObjectTypeGroup(id: id, kind: kind, objects: objects, schemas: schemas)
    }
}
