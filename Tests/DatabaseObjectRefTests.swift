import XCTest
@testable import DoyahCore

/// 表引用（FR-DATA-06 的外键跳转用它记录「结果是从哪张表来的」）。
///
/// 这个类型小到看起来不值得测，但它的两个判断**会静默出错**：schema 为空时拼出
/// 前导点（`.orders` 这种名字在日志与状态栏里很难看出问题），以及把跨 schema 的
/// 同名表当成同一张表（跳转就会落到另一个 schema 的同名表上）。
final class DatabaseObjectRefTests: XCTestCase {

    func testQualifiedNameIncludesSchemaWhenPresent() {
        XCTAssertEqual(DatabaseObjectRef(schema: "public", name: "orders").qualifiedName, "public.orders")
    }

    /// 没有 schema 时**不要**拼出一个前导点：`orders`，而不是 `.orders`。
    func testQualifiedNameOmitsMissingSchema() {
        XCTAssertEqual(DatabaseObjectRef(schema: nil, name: "orders").qualifiedName, "orders")
        XCTAssertEqual(DatabaseObjectRef(schema: "", name: "orders").qualifiedName, "orders")
    }

    func testEqualityAndHashingUseBothFields() {
        let a = DatabaseObjectRef(schema: "public", name: "orders")
        let b = DatabaseObjectRef(schema: "public", name: "orders")
        let c = DatabaseObjectRef(schema: "sales", name: "orders")
        XCTAssertEqual(a, b)
        XCTAssertEqual(Set([a, b, c]).count, 2, "跨 schema 的同名表是两个不同的引用")
    }
}
