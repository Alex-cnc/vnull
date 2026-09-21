import XCTest
@testable import PostgresClientCore

final class SQLFormatterTests: XCTestCase {

    func testUppercasesKeywordsAndBreaksClauses() {
        let formatted = SQLFormatter(databaseType: .postgresql)
            .format("select id, name from users where id=1 and name='a b' order by id;")

        XCTAssertEqual(
            formatted,
            """
            SELECT id, name
            FROM users
            WHERE id = 1 AND name = 'a b'
            ORDER BY id;
            """
        )
    }

    func testPreservesStringContent() {
        let formatted = SQLFormatter(databaseType: .postgresql)
            .format("select 'select from where' as s;")

        XCTAssertEqual(formatted, "SELECT 'select from where' AS s;")
    }

    func testKeepsParenthesizedQueryOnOneLineButUppercasesInnerKeywords() {
        let formatted = SQLFormatter(databaseType: .postgresql)
            .format("select * from t where id in (select id from u);")

        XCTAssertEqual(
            formatted,
            """
            SELECT *
            FROM t
            WHERE id IN (SELECT id FROM u);
            """
        )
    }

    func testEmptyInputIsReturnedUnchanged() {
        let formatter = SQLFormatter(databaseType: .postgresql)

        XCTAssertEqual(formatter.format(""), "")
        XCTAssertEqual(formatter.format("   "), "")
    }
}
