import XCTest
@testable import DoyahCore

/// 结果列对齐判定的单测。
///
/// 这个函数"看起来显然"，但错了会让整列数字左对齐 —— 在界面上很难一眼看出来，
/// 所以用白名单 + 精确匹配把它写死，并把经典陷阱逐个钉成用例。
final class ColumnAlignmentTests: XCTestCase {

    func testIntegerTypesAreNumeric() {
        for name in ["int", "INT4", "integer", "bigint", "int8", "smallint", "serial", "bigserial", "tinyint"] {
            XCTAssertTrue(ColumnAlignment.isNumeric(typeName: name), "\(name) 应判为数值")
        }
    }

    func testDecimalAndFloatTypesAreNumeric() {
        for name in ["numeric", "decimal", "real", "double precision", "float8", "money", "number"] {
            XCTAssertTrue(ColumnAlignment.isNumeric(typeName: name), "\(name) 应判为数值")
        }
    }

    /// **经典陷阱**：这些词里都含 "int"，但它们不是数值类型。
    func testWordsContainingIntAreNotNumeric() {
        for name in ["interval", "point", "print", "integer_range", "text_int", "varchar"] {
            XCTAssertFalse(ColumnAlignment.isNumeric(typeName: name), "\(name) 不该被判为数值（子串匹配的典型误判）")
        }
    }

    func testTextAndTemporalTypesAreLeading() {
        for name in ["text", "varchar", "character varying", "char", "uuid", "date", "timestamp",
                     "timestamp with time zone", "time", "boolean", "json", "jsonb", "bytea"] {
            XCTAssertEqual(ColumnAlignment.alignment(for: name), .leading, "\(name) 应左对齐")
        }
    }

    /// 类型名常带精度与数组后缀：必须归一化后再判。
    func testNormalizesPrecisionAndArraySuffix() {
        XCTAssertTrue(ColumnAlignment.isNumeric(typeName: "NUMERIC(12,2)"))
        XCTAssertTrue(ColumnAlignment.isNumeric(typeName: "decimal(10)"))
        XCTAssertTrue(ColumnAlignment.isNumeric(typeName: "  int4  "))
        XCTAssertEqual(ColumnAlignment.alignment(for: "numeric(12,2)"), .trailing)
        XCTAssertEqual(ColumnAlignment.alignment(for: "character varying(64)"), .leading)
        XCTAssertEqual(ColumnAlignment.alignment(for: "timestamp(6) with time zone"), .leading)
    }

    func testEmptyTypeNameIsLeadingAndDoesNotCrash() {
        XCTAssertEqual(ColumnAlignment.alignment(for: ""), .leading)
        XCTAssertEqual(ColumnAlignment.alignment(for: "   "), .leading)
    }
}
