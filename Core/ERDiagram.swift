import Foundation

/// ER 图 / 关系图（FR-DDL-05）：由外键元数据生成**确定性**的图模型、布局与文本导出。
///
/// 为什么把"画图"这件事拆成"模型 + 布局 + 导出"三层而不是直接在视图里连线：
/// 1. **可单测**：布局是纯计算（层号、坐标、走线），同一份输入必须给出同一份输出 ——
///    这样"图会不会叠在一起""每次打开位置是不是乱跳"能在 Core 里钉住，而不是靠肉眼看；
/// 2. **可脚本化**：`mermaid` / `dot` 两种文本导出让图能被**外部工具**渲染与核对
///    （GitHub 直接渲染 Mermaid，`dot` 是 Graphviz 的输入），也给了真机脚本可断言的东西；
/// 3. **不绑界面**：视图只负责把节点与走线画出来，换平台不用重写布局。
///
/// 分层规则（父子方向）：**被引用的一方在上层**（`orders` 在 `order_items` 上面），
/// 也就是"不依赖别人的表在第 0 层，依赖别人的表在它下面"。环（互相引用）无法拓扑排序，
/// 处理方式是：能定层的先定层，**剩下成环的按名字稳定地放到最后一层**并在
/// `layout().cyclicTables` 里点名 —— 不假装环不存在，也不让布局在这里死循环。
public struct ERDiagram: Equatable, Sendable {

    public struct Column: Equatable, Sendable {
        public var name: String
        public var typeName: String
        public var isPrimaryKey: Bool
        public var isForeignKey: Bool

        public init(name: String, typeName: String = "", isPrimaryKey: Bool = false, isForeignKey: Bool = false) {
            self.name = name
            self.typeName = typeName
            self.isPrimaryKey = isPrimaryKey
            self.isForeignKey = isForeignKey
        }
    }

    public struct Table: Equatable, Sendable, Identifiable {
        public var schema: String?
        public var name: String
        public var columns: [Column]
        /// 只在关系里出现、但没拿到列定义的表（跨 schema / 权限看不到）——**保留而不是丢掉**，
        /// 否则图上会凭空少一条外键，看的人会以为"这两张表没关系"。
        public var isStub: Bool

        public var id: String { qualifiedName }

        /// 限定名（图上的标识）：`schema.name`，schema 为空时就是表名。
        public var qualifiedName: String {
            guard let schema, !schema.isEmpty else { return name }
            return "\(schema).\(name)"
        }

        public init(schema: String?, name: String, columns: [Column] = [], isStub: Bool = false) {
            self.schema = schema
            self.name = name
            self.columns = columns
            self.isStub = isStub
        }
    }

    public struct Endpoint: Equatable, Sendable {
        public var schema: String?
        public var table: String
        /// 参与该外键的列（复合外键会有多列，顺序与约束一致）。
        public var columns: [String]

        public var qualifiedTable: String {
            guard let schema, !schema.isEmpty else { return table }
            return "\(schema).\(table)"
        }

        public init(schema: String?, table: String, columns: [String]) {
            self.schema = schema
            self.table = table
            self.columns = columns
        }
    }

    public struct Relationship: Equatable, Sendable {
        public var name: String?
        /// 引用方（子表，外键在它身上）。
        public var from: Endpoint
        /// 被引用方（父表）。
        public var to: Endpoint
        public var onDelete: String?
        public var onUpdate: String?

        public var isSelfReference: Bool { from.qualifiedTable == to.qualifiedTable }
        public var isComposite: Bool { from.columns.count > 1 }
        /// 图上的标签：约束名优先，没有就用列名拼一个（不能空着 —— 空标签等于没解释这条线）。
        public var label: String {
            if let name, !name.isEmpty { return name }
            return "\(from.columns.joined(separator: "+")) → \(to.columns.joined(separator: "+"))"
        }

        public init(
            name: String? = nil,
            from: Endpoint,
            to: Endpoint,
            onDelete: String? = nil,
            onUpdate: String? = nil
        ) {
            self.name = name
            self.from = from
            self.to = to
            self.onDelete = onDelete
            self.onUpdate = onUpdate
        }
    }

    public var tables: [Table]
    public var relationships: [Relationship]

    public init(tables: [Table], relationships: [Relationship]) {
        self.tables = tables
        self.relationships = relationships
    }

    public var isEmpty: Bool { tables.isEmpty }

    /// 归一化 + 排序：剔除重复关系、给缺列的表补桩、按名字稳定排序。
    ///
    /// 排序是布局确定性的前提：同样的库结构，两次导出必须给出同一张图
    /// （否则"每次打开位置都不一样"会被当成缺陷报上来，而且很难复现）。
    public static func build(tables: [Table], relationships: [Relationship]) -> ERDiagram {
        var nodes: [String: Table] = [:]
        for table in tables {
            let key = table.qualifiedName
            if var existing = nodes[key] {
                // 同一张表被喂了两次：合并列（按列名去重，保留先出现的顺序）。
                for column in table.columns where !existing.columns.contains(where: { $0.name == column.name }) {
                    existing.columns.append(column)
                }
                existing.isStub = existing.isStub && table.isStub
                nodes[key] = existing
            } else {
                nodes[key] = table
            }
        }

        var unique: [Relationship] = []
        var seen: Set<String> = []
        for relationship in relationships {
            // 关系里出现、但没给列定义的表：补一个"桩节点"，只放参与外键的列。
            for endpoint in [relationship.from, relationship.to] where endpoint.columns.isEmpty == false {
                let key = endpoint.qualifiedTable
                if nodes[key] == nil {
                    nodes[key] = Table(
                        schema: endpoint.schema,
                        name: endpoint.table,
                        columns: endpoint.columns.map { Column(name: $0, isForeignKey: endpoint.qualifiedTable == relationship.from.qualifiedTable) },
                        isStub: true
                    )
                }
            }
            let signature = "\(relationship.from.qualifiedTable)|\(relationship.from.columns.joined(separator: ","))"
                + "->\(relationship.to.qualifiedTable)|\(relationship.to.columns.joined(separator: ","))"
            guard !seen.contains(signature) else { continue }
            seen.insert(signature)
            unique.append(relationship)
        }

        // 把关系里用到的列标成外键（界面上要能一眼看出哪几列是外键）。
        for relationship in unique {
            let key = relationship.from.qualifiedTable
            guard var table = nodes[key] else { continue }
            for column in relationship.from.columns {
                if let index = table.columns.firstIndex(where: { $0.name == column }) {
                    table.columns[index].isForeignKey = true
                } else {
                    table.columns.append(Column(name: column, isForeignKey: true))
                }
            }
            nodes[key] = table
        }

        let sortedTables = nodes.values.sorted { $0.qualifiedName < $1.qualifiedName }
        let sortedRelationships = unique.sorted {
            ($0.from.qualifiedTable, $0.name ?? $0.label, $0.to.qualifiedTable)
                < ($1.from.qualifiedTable, $1.name ?? $1.label, $1.to.qualifiedTable)
        }
        return ERDiagram(tables: sortedTables, relationships: sortedRelationships)
    }

    // MARK: - 布局

    public struct Layout: Equatable, Sendable {
        /// 布局默认值：**放在这里而不是视图里** —— 视图画节点时要用同一个表头 / 行高，
        /// 两处各写一份数字迟早会不一样（画出来的格子与布局算出来的不一样高）。
        public static let defaultNodeWidth: Double = 220
        public static let defaultHeaderHeight: Double = 34
        public static let defaultRowHeight: Double = 18
        public static let defaultHorizontalGap: Double = 60
        public static let defaultVerticalGap: Double = 90
        public static let defaultMaximumVisibleColumns: Int = 12

        public struct Node: Equatable, Sendable {
            public var table: String
            public var layer: Int
            /// 在层内的次序（从左到右）。
            public var order: Int
            /// 左上角坐标与尺寸（点是抽象单位，视图按需缩放）。
            public var x: Double
            public var y: Double
            public var width: Double
            public var height: Double

            public var centerX: Double { x + width / 2 }
            public var bottomY: Double { y + height }
        }

        public struct RoutedEdge: Equatable, Sendable {
            public var label: String
            public var fromTable: String
            public var toTable: String
            public var start: (x: Double, y: Double)
            public var end: (x: Double, y: Double)
            /// 折线中间点（视图画曲线时当控制点用）。
            public var waypoint: (x: Double, y: Double)
            public var isSelfReference: Bool

            public static func == (lhs: RoutedEdge, rhs: RoutedEdge) -> Bool {
                lhs.label == rhs.label && lhs.fromTable == rhs.fromTable && lhs.toTable == rhs.toTable
                    && lhs.start == rhs.start && lhs.end == rhs.end && lhs.waypoint == rhs.waypoint
                    && lhs.isSelfReference == rhs.isSelfReference
            }
        }

        public var nodes: [Node]
        public var edges: [RoutedEdge]
        /// 互相引用、无法拓扑排序的表（点名，不假装不存在）。
        public var cyclicTables: [String]
        public var width: Double
        public var height: Double

        public func node(for table: String) -> Node? { nodes.first { $0.table == table } }
    }

    /// 计算布局。
    ///
    /// - Parameters:
    ///   - nodeWidth: 节点宽度（抽象单位）。
    ///   - headerHeight: 表头高度。
    ///   - rowHeight: 每列一行的高度。
    ///   - horizontalGap / verticalGap: 同层间距与层间距。
    public func layout(
        nodeWidth: Double = ERDiagram.Layout.defaultNodeWidth,
        headerHeight: Double = ERDiagram.Layout.defaultHeaderHeight,
        rowHeight: Double = ERDiagram.Layout.defaultRowHeight,
        horizontalGap: Double = ERDiagram.Layout.defaultHorizontalGap,
        verticalGap: Double = ERDiagram.Layout.defaultVerticalGap,
        maximumVisibleColumns: Int = ERDiagram.Layout.defaultMaximumVisibleColumns
    ) -> Layout {
        let tablesByKey = Dictionary(uniqueKeysWithValues: tables.map { ($0.qualifiedName, $0) })

        // 1) 定层：不引用别人的表在第 0 层；其余取"所有父表层号 + 1"。
        var parentsOf: [String: Set<String>] = [:]
        for table in tables { parentsOf[table.qualifiedName] = [] }
        for relationship in relationships where !relationship.isSelfReference {
            parentsOf[relationship.from.qualifiedTable, default: []].insert(relationship.to.qualifiedTable)
        }
        // 自引用不算父依赖（否则自己把自己卡住），单独当作环记下来。
        let selfReferencing = Set(relationships.filter(\.isSelfReference).map(\.from.qualifiedTable))

        var layers: [String: Int] = [:]
        var pending = Set(tables.map(\.qualifiedName))
        var progress = true
        while progress, !pending.isEmpty {
            progress = false
            for key in pending.sorted() {
                let parents = parentsOf[key] ?? []
                if parents.allSatisfy({ layers[$0] != nil }) {
                    let depth = parents.compactMap { layers[$0] }.max().map { $0 + 1 } ?? 0
                    layers[key] = depth
                    pending.remove(key)
                    progress = true
                }
            }
        }
        // 剩下的都是环里的（互相引用）：按名字稳定地排到最后一层。
        let maxAssigned = layers.values.max() ?? -1
        let cyclic = pending.sorted()
        for (offset, key) in cyclic.enumerated() {
            layers[key] = maxAssigned + 1 + offset
        }

        // 2) 层内排序 → 坐标。
        var byLayer: [Int: [String]] = [:]
        for (key, layer) in layers {
            byLayer[layer, default: []].append(key)
        }
        var nodes: [Layout.Node] = []
        var y = 0.0
        var width = 0.0
        for layer in byLayer.keys.sorted() {
            let keys = (byLayer[layer] ?? []).sorted()
            let heights = keys.map { height(for: tablesByKey[$0], headerHeight: headerHeight, rowHeight: rowHeight, maximumVisibleColumns: maximumVisibleColumns) }
            let layerHeight = heights.max() ?? headerHeight
            var x = 0.0
            for (order, key) in keys.enumerated() {
                let nodeHeight = heights[order]
                nodes.append(
                    Layout.Node(
                        table: key,
                        layer: layer,
                        order: order,
                        x: x,
                        y: y,
                        width: nodeWidth,
                        height: nodeHeight
                    )
                )
                x += nodeWidth + horizontalGap
                width = max(width, x - horizontalGap)
            }
            y += layerHeight + verticalGap
        }

        // 3) 走线：父在上 → 从子表顶部连到父表底部；同层 / 环 → 左右相连。
        let nodesByKey = Dictionary(uniqueKeysWithValues: nodes.map { ($0.table, $0) })
        var edges: [Layout.RoutedEdge] = []
        for relationship in relationships {
            guard let from = nodesByKey[relationship.from.qualifiedTable],
                  let to = nodesByKey[relationship.to.qualifiedTable] else { continue }
            let start: (x: Double, y: Double)
            let end: (x: Double, y: Double)
            let waypoint: (x: Double, y: Double)
            if from.table == to.table {
                // 自引用：从右侧出、绕一圈回到顶部（画出来才不会压在节点上）。
                start = (from.x + from.width, from.y + from.height / 2)
                end = (from.x + from.width / 2, from.y)
                waypoint = (from.x + from.width + horizontalGap / 2, from.y - verticalGap / 3)
            } else if from.layer > to.layer {
                start = (from.centerX, from.y)
                end = (to.centerX, to.bottomY)
                waypoint = ((start.x + end.x) / 2, (start.y + end.y) / 2)
            } else {
                let leftToRight = from.centerX <= to.centerX
                start = (leftToRight ? from.x + from.width : from.x, from.y + from.height / 2)
                end = (leftToRight ? to.x : to.x + to.width, to.y + to.height / 2)
                waypoint = ((start.x + end.x) / 2, (start.y + end.y) / 2)
            }
            edges.append(
                Layout.RoutedEdge(
                    label: relationship.label,
                    fromTable: from.table,
                    toTable: to.table,
                    start: start,
                    end: end,
                    waypoint: waypoint,
                    isSelfReference: from.table == to.table
                )
            )
        }

        let height = max(0, y - verticalGap)
        return Layout(
            nodes: nodes,
            edges: edges,
            cyclicTables: Array(Set(cyclic).union(selfReferencing)).sorted(),
            width: width,
            height: height
        )
    }

    func height(
        for table: Table?,
        headerHeight: Double,
        rowHeight: Double,
        maximumVisibleColumns: Int
    ) -> Double {
        let count = min(table?.columns.count ?? 0, max(0, maximumVisibleColumns))
        let overflow = (table?.columns.count ?? 0) > count ? 1 : 0
        return headerHeight + Double(count + overflow) * rowHeight
    }

    // MARK: - 文本导出

    /// Mermaid `erDiagram`（GitHub / VS Code 直接渲染）。
    ///
    /// 语法要点：属性行是 `类型 名字 [PK|FK]`，关系行是 `父 ||--o{ 子 : 标签`
    /// —— 注意**父在左**：外键在子表上，一个父可以对应零到多个子。
    public func mermaid() -> String {
        var lines: [String] = ["erDiagram"]
        for table in tables {
            lines.append("    %% \(table.qualifiedName)")
            lines.append("    \(mermaidIdentifier(table.qualifiedName)) {")
            if table.columns.isEmpty {
                // Mermaid 里空实体是合法的，但列一行都没有时给一行说明，免得看着像漏了。
                lines.append("        text \(mermaidIdentifier("no_columns_visible"))")
            }
            for column in table.columns {
                var parts = [mermaidType(column.typeName), mermaidIdentifier(column.name)]
                if column.isPrimaryKey { parts.append("PK") }
                if column.isForeignKey { parts.append("FK") }
                lines.append("        " + parts.joined(separator: " "))
            }
            lines.append("    }")
        }
        for relationship in relationships {
            let parent = mermaidIdentifier(relationship.to.qualifiedTable)
            let child = mermaidIdentifier(relationship.from.qualifiedTable)
            lines.append("    \(parent) ||--o{ \(child) : \(mermaidLabel(relationship.label))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Graphviz DOT（`dot -Tsvg` 渲染）。
    public func dot() -> String {
        var lines: [String] = ["digraph er {", "  rankdir=TB;", "  node [shape=plaintext, fontname=\"Helvetica\"];"]
        for table in tables {
            var label = escapeDOT(table.qualifiedName) + "\\l"
            for column in table.columns {
                var marker = ""
                if column.isPrimaryKey { marker += " PK" }
                if column.isForeignKey { marker += " FK" }
                label += escapeDOT(column.name + (column.typeName.isEmpty ? "" : " \(column.typeName)") + marker) + "\\l"
            }
            lines.append("  \"\(table.qualifiedName)\" [label=\"\(label)\"];")
        }
        for relationship in relationships {
            lines.append(
                "  \"\(relationship.from.qualifiedTable)\" -> \"\(relationship.to.qualifiedTable)\" "
                + "[label=\"\(escapeDOT(relationship.label))\", arrowhead=crow];"
            )
        }
        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }

    /// JSON（给脚本与其它渲染器用；字段名固定）。
    public func json() -> String {
        var tableObjects: [String] = []
        for table in tables {
            let columns = table.columns.map { column -> String in
                var fields = ["\"name\": \(jsonString(column.name))"]
                if !column.typeName.isEmpty { fields.append("\"type\": \(jsonString(column.typeName))") }
                if column.isPrimaryKey { fields.append("\"primaryKey\": true") }
                if column.isForeignKey { fields.append("\"foreignKey\": true") }
                return "{" + fields.joined(separator: ", ") + "}"
            }
            var fields = ["\"table\": \(jsonString(table.qualifiedName))"]
            if let schema = table.schema { fields.append("\"schema\": \(jsonString(schema))") }
            fields.append("\"name\": \(jsonString(table.name))")
            if table.isStub { fields.append("\"stub\": true") }
            fields.append("\"columns\": [" + columns.joined(separator: ", ") + "]")
            tableObjects.append("    {" + fields.joined(separator: ", ") + "}")
        }
        let relationshipObjects = relationships.map { relationship -> String in
            var fields = [
                "\"from\": \(jsonString(relationship.from.qualifiedTable))",
                "\"fromColumns\": [" + relationship.from.columns.map(jsonString).joined(separator: ", ") + "]",
                "\"to\": \(jsonString(relationship.to.qualifiedTable))",
                "\"toColumns\": [" + relationship.to.columns.map(jsonString).joined(separator: ", ") + "]",
            ]
            if let name = relationship.name { fields.insert("\"name\": \(jsonString(name))", at: 0) }
            if let onDelete = relationship.onDelete { fields.append("\"onDelete\": \(jsonString(onDelete))") }
            if relationship.isComposite { fields.append("\"composite\": true") }
            return "    {" + fields.joined(separator: ", ") + "}"
        }
        return """
        {
          "tables": [
        \(tableObjects.joined(separator: ",\n"))
          ],
          "relationships": [
        \(relationshipObjects.joined(separator: ",\n"))
          ]
        }
        """ + "\n"
    }

    private func jsonString(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            default: escaped.append(character)
            }
        }
        return "\"" + escaped + "\""
    }

    /// Mermaid 的实体名：**不加引号**，非字母数字一律换成下划线。
    ///
    /// 为什么不加引号：Mermaid 的 ER 语法历史上只接受"字母开头、只含字母数字下划线中划线"的名字，
    /// 带引号的写法在不同版本 / 不同渲染器上支持程度不一致 —— 生成一份**到哪都能渲染**的图
    /// 比保留那个点更重要（真实的限定名在 DOT 与 JSON 里是完整的，注释里也留了一份）。
    func mermaidIdentifier(_ raw: String) -> String {
        var sanitized = raw.map { character -> Character in
            character.isLetter || character.isNumber || character == "_" || character == "-" ? character : "_"
        }
        if sanitized.first?.isNumber == true { sanitized.insert(contentsOf: "t_", at: 0) }
        let text = String(sanitized)
        return text.isEmpty ? "unnamed" : text
    }

    func mermaidType(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "text" }
        // 只保留"一个词"：Mermaid 的属性行是 `类型 名字`，类型里带空格或括号会解析失败。
        let base = trimmed.split(separator: "(").first.map(String.init) ?? trimmed
        let sanitized = base.map { character -> Character in
            character.isLetter || character.isNumber || character == "_" ? character : "_"
        }
        return sanitized.isEmpty ? "text" : String(sanitized)
    }

    func mermaidLabel(_ raw: String) -> String {
        // 标签里出现双引号会破坏语法；统一换成单引号。
        "\"" + raw.replacingOccurrences(of: "\"", with: "'") + "\""
    }

    func escapeDOT(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
