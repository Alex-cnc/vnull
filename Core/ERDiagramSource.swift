import Foundation

/// ER 图的数据来源（FR-DDL-05）：库里的外键元数据 → `ERDiagram`。
///
/// 与 `ERDiagram` 的分工：那边只认"表 + 关系"的抽象模型（纯逻辑、纯布局、纯导出），
/// 这边负责**从数据库取与解析**。分开的好处是布局与导出不必依赖连接，而解析（尤其是
/// 复合外键的分组、`confdeltype` 这类编码）能单独测。
public enum ERDiagramSource {

    /// 一次取回**整个 schema** 的外键：每列一行，同一约束的多行靠 `conname` 归并成一条复合外键。
    ///
    /// 为什么用 `pg_constraint` 而不是 `information_schema`：后者的 `referential_constraints`
    /// 拿不到"哪一列对应哪一列"的配对，复合外键会错配；`conkey` / `confkey` 是**按序对应**的数组，
    /// 用 `generate_subscripts` 展开才拿得到正确配对。
    public static func foreignKeysQuery(schema: String) -> String {
        let escaped = schema.replacingOccurrences(of: "'", with: "''")
        return """
        SELECT con.conname,
               child.relname AS child_table,
               child_ns.nspname AS child_schema,
               child_att.attname AS child_column,
               parent.relname AS parent_table,
               parent_ns.nspname AS parent_schema,
               parent_att.attname AS parent_column,
               con.confdeltype::text AS on_delete,
               con.confupdtype::text AS on_update,
               ord.n AS position
        FROM pg_constraint con
        JOIN pg_class child ON child.oid = con.conrelid
        JOIN pg_namespace child_ns ON child_ns.oid = child.relnamespace
        JOIN pg_class parent ON parent.oid = con.confrelid
        JOIN pg_namespace parent_ns ON parent_ns.oid = parent.relnamespace
        JOIN generate_subscripts(con.conkey, 1) AS ord(n) ON true
        JOIN pg_attribute child_att
          ON child_att.attrelid = con.conrelid AND child_att.attnum = con.conkey[ord.n]
        JOIN pg_attribute parent_att
          ON parent_att.attrelid = con.confrelid AND parent_att.attnum = con.confkey[ord.n]
        WHERE con.contype = 'f' AND child_ns.nspname = '\(escaped)'
        ORDER BY child.relname, con.conname, ord.n
        """
    }

    /// 解析外键查询结果。
    ///
    /// 归并规则：`(子表, 约束名)` 相同的行属于同一条外键，列按 `position` 排序 ——
    /// **列序不能乱**：复合外键的配对是有序的，乱了就会把 `(a,b) → (x,y)` 读成 `(a,b) → (y,x)`。
    public static func relationships(from result: QueryResult) -> [ERDiagram.Relationship] {
        struct Bucket {
            var name: String
            var childSchema: String?
            var childTable: String
            var parentSchema: String?
            var parentTable: String
            var childColumns: [(position: Int, name: String)]
            var parentColumns: [(position: Int, name: String)]
            var onDelete: String?
            var onUpdate: String?
        }

        var buckets: [String: Bucket] = [:]
        var order: [String] = []

        for row in result.rows {
            guard let name = value(row, at: 0),
                  let childTable = value(row, at: 1),
                  let childColumn = value(row, at: 3),
                  let parentTable = value(row, at: 4),
                  let parentColumn = value(row, at: 6) else { continue }
            let childSchema = value(row, at: 2)
            let key = "\(childSchema ?? "").\(childTable)|\(name)|\(parentTable)"
            let position = Int(value(row, at: 9) ?? "0") ?? 0

            if buckets[key] == nil {
                order.append(key)
                buckets[key] = Bucket(
                    name: name,
                    childSchema: childSchema,
                    childTable: childTable,
                    parentSchema: value(row, at: 5),
                    parentTable: parentTable,
                    childColumns: [],
                    parentColumns: [],
                    onDelete: decodeAction(value(row, at: 7)),
                    onUpdate: decodeAction(value(row, at: 8))
                )
            }
            buckets[key]?.childColumns.append((position, childColumn))
            buckets[key]?.parentColumns.append((position, parentColumn))
        }

        return order.compactMap { key -> ERDiagram.Relationship? in
            guard let bucket = buckets[key] else { return nil }
            return ERDiagram.Relationship(
                name: bucket.name,
                from: ERDiagram.Endpoint(
                    schema: bucket.childSchema,
                    table: bucket.childTable,
                    columns: bucket.childColumns.sorted { $0.position < $1.position }.map(\.name)
                ),
                to: ERDiagram.Endpoint(
                    schema: bucket.parentSchema,
                    table: bucket.parentTable,
                    columns: bucket.parentColumns.sorted { $0.position < $1.position }.map(\.name)
                ),
                onDelete: bucket.onDelete,
                onUpdate: bucket.onUpdate
            )
        }
    }

    /// 结构快照 → 图上的表（列 + 主键标记；外键标记由 `ERDiagram.build` 按关系补）。
    public static func tables(from snapshots: [TableSnapshot]) -> [ERDiagram.Table] {
        snapshots.map { snapshot in
            ERDiagram.Table(
                schema: snapshot.schema,
                name: snapshot.name,
                columns: snapshot.columns.map { column in
                    ERDiagram.Column(
                        name: column.name,
                        typeName: column.typeName,
                        isPrimaryKey: column.isPrimaryKey
                    )
                }
            )
        }
    }

    /// 组装：表来自结构快照，关系来自外键查询。
    public static func diagram(snapshots: [TableSnapshot], foreignKeys: QueryResult) -> ERDiagram {
        ERDiagram.build(tables: tables(from: snapshots), relationships: relationships(from: foreignKeys))
    }

    /// `pg_constraint.confdeltype` / `confupdtype` 的编码 → 可读动作。
    ///
    /// 编码是 PostgreSQL 文档里的单字符码（`a`=NO ACTION、`r`=RESTRICT、`c`=CASCADE、
    /// `n`=SET NULL、`d`=SET DEFAULT）；认不出来时返回 nil 而不是编一个。
    static func decodeAction(_ raw: String?) -> String? {
        guard let raw, let code = raw.first else { return nil }
        switch code {
        case "a": return SQLGenerator.ReferentialAction.noAction.rawValue
        case "r": return SQLGenerator.ReferentialAction.restrict.rawValue
        case "c": return SQLGenerator.ReferentialAction.cascade.rawValue
        case "n": return SQLGenerator.ReferentialAction.setNull.rawValue
        case "d": return SQLGenerator.ReferentialAction.setDefault.rawValue
        default: return nil
        }
    }

    private static func value(_ row: [String?], at index: Int) -> String? {
        guard row.indices.contains(index), let value = row[index], !value.isEmpty else { return nil }
        return value
    }
}
