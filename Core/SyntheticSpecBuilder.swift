import Foundation

/// 按**已存在的表结构**推断一份合成数据规格（FR-AI-07 的"一键可用"入口）。
///
/// 为什么需要它：`SyntheticTableSpec` 要求逐列写生成规则，而绝大多数场景（造测试数据）
/// 只是想"按这张表的形状灌点能用的数据"。让用户对着十几列手填规则，等于把功能藏起来。
///
/// 两条纪律：
/// 1. **只按类型推断，不猜业务语义** —— `email` 这种"看着像邮箱就生成邮箱"的猜测会误导，
///    宁可给通用文本；想更贴合就在界面上改（规格是可编辑的）。
/// 2. **推断结果必须自洽**：主键 / 唯一列用 `sequence`（天然唯一）、非空列 `nullProbability = 0`、
///    可空列给一个小概率 NULL —— 否则生成出来的数据插不进去（约束不满足）。
public enum SyntheticSpecBuilder {

    /// 列的名字 / 类型 / 可空 / 是否主键（与 `TableColumnDefinition` 同形，避免调用方再转一层）。
    public struct ColumnShape: Equatable, Sendable {
        public var name: String
        public var typeName: String
        public var isNullable: Bool
        public var isPrimaryKey: Bool

        public init(name: String, typeName: String, isNullable: Bool = true, isPrimaryKey: Bool = false) {
            self.name = name
            self.typeName = typeName
            self.isNullable = isNullable
            self.isPrimaryKey = isPrimaryKey
        }

        public init(_ column: TableColumnDefinition) {
            self.init(
                name: column.name,
                typeName: column.typeName,
                isNullable: column.isNullable,
                isPrimaryKey: column.isPrimaryKey
            )
        }
    }

    /// 可空列的 NULL 概率（保守：10% 足够体现"可空"，又不至于让数据看起来缺得厉害）。
    public static let nullableProbability = 0.1

    public static func spec(
        table: String,
        schema: String? = nil,
        columns: [ColumnShape],
        rowCount: Int = 100,
        seed: UInt64 = 1
    ) -> SyntheticTableSpec {
        let specs = columns.filter { !$0.name.isEmpty }.map { shape -> ColumnSpec in
            // 主键 / 非空列：NULL 概率必须是 0 —— 这是"插得进去"的硬条件，不是偏好。
            let nullProbability = (shape.isPrimaryKey || !shape.isNullable) ? 0 : nullableProbability
            return ColumnSpec(
                name: shape.name,
                generator: generator(for: shape),
                nullProbability: nullProbability,
                // 主键必然唯一；唯一约束我们看不到（`TableColumnDefinition` 里没有），
                // 因此只对主键置 true —— 猜错唯一性会让生成失败，代价比少标一个大。
                isUnique: shape.isPrimaryKey
            )
        }

        return SyntheticTableSpec(table: table, schema: schema, columns: specs, rowCount: rowCount, seed: seed)
    }

    /// 类型名 → 生成规则。
    ///
    /// 匹配用小写 + 去参数（`varchar(50)` → `varchar`），并且**按完整类型名判定**，
    /// 不用 `contains`：`interval` 里也有 `int`，用它做判定会把时间间隔列生成成整数。
    static func generator(for shape: ColumnShape) -> ColumnGenerator {
        let base = normalizedTypeName(shape.typeName)

        // 主键优先于类型：主键用序列（唯一且递增），比"随机整数 + 去重"更省事也更像真数据。
        if shape.isPrimaryKey, isIntegerType(base) {
            return .sequence(start: 1, step: 1)
        }

        switch base {
        case "int2", "int4", "int8", "smallint", "integer", "bigint", "serial", "bigserial", "int", "tinyint", "mediumint":
            return .integer(min: 1, max: 10_000)
        case "numeric", "decimal", "real", "float4", "float8", "double", "double precision", "money":
            return .decimal(min: 0, max: 1_000, precision: 2)
        case "bool", "boolean":
            return .boolean(trueProbability: 0.5)
        case "date":
            return .date(lastDays: 365)
        case "timestamp", "timestamptz", "timestamp with time zone", "timestamp without time zone", "datetime":
            return .timestamp(lastDays: 365)
        case "uuid":
            return .uuid
        case "text", "varchar", "character varying", "char", "character", "bpchar", "name", "lvarchar":
            return .text(minLength: 8, maxLength: 24)
        default:
            // 认不出来的一律给短文本：**生成可插入的数据**比"精确匹配类型"更重要，
            // 何况多数数据库会自己把文本转成目标类型。
            return .text(minLength: 6, maxLength: 16)
        }
    }

    /// `varchar(50)` → `varchar`；`numeric(10, 2)` → `numeric`；去空白、转小写。
    static func normalizedTypeName(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let paren = text.firstIndex(of: "(") {
            text = String(text[..<paren]).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    static func isIntegerType(_ base: String) -> Bool {
        ["int2", "int4", "int8", "smallint", "integer", "bigint", "serial", "bigserial", "int"].contains(base)
    }
}
