import XCTest
@testable import DoyahCore

final class StatementSplitterTests: XCTestCase {
    func testSimpleStatements() {
        let splitter = StatementSplitter(databaseType: .postgresql)
        let statements = splitter.split("SELECT 1; SELECT 2;")

        XCTAssertEqual(statements.count, 2)
        XCTAssertEqual(statements[0].sql.trimmingCharacters(in: .whitespacesAndNewlines), "SELECT 1")
        XCTAssertEqual(statements[1].sql.trimmingCharacters(in: .whitespacesAndNewlines), "SELECT 2")
    }

    func testSemicolonInsideSingleQuotedString() {
        let splitter = StatementSplitter(databaseType: .postgresql)
        let statements = splitter.split("SELECT 'a;b' AS value; SELECT 2;")

        XCTAssertEqual(statements.count, 2)
        XCTAssertTrue(statements[0].sql.contains("'a;b'"))
    }

    func testSemicolonInsideLineComment() {
        let splitter = StatementSplitter(databaseType: .postgresql)
        let statements = splitter.split("SELECT 1; -- 这里有一个 ; 但不是结束\nSELECT 2;")

        XCTAssertEqual(statements.count, 2)
        XCTAssertTrue(statements[1].sql.contains("-- 这里有一个 ; 但不是结束"))
    }

    func testSemicolonInsideBlockComment() {
        let splitter = StatementSplitter(databaseType: .postgresql)
        let statements = splitter.split("SELECT 1 /* 这里 ; 也不是结束 */; SELECT 2;")

        XCTAssertEqual(statements.count, 2)
        XCTAssertTrue(statements[0].sql.contains("/* 这里 ; 也不是结束 */"))
    }

    func testPostgresDollarQuotedFunction() {
        let splitter = StatementSplitter(databaseType: .postgresql)
        let sql = """
        CREATE FUNCTION f() RETURNS void AS $$
        BEGIN
            PERFORM 1;
        END;
        $$ LANGUAGE plpgsql;
        SELECT 1;
        """

        let statements = splitter.split(sql)
        XCTAssertEqual(statements.count, 2)
        XCTAssertTrue(statements[0].sql.contains("PERFORM 1;"))
        XCTAssertTrue(statements[0].sql.contains("$$ LANGUAGE plpgsql"))
    }

    func testPostgresTaggedDollarQuote() {
        let splitter = StatementSplitter(databaseType: .postgresql)
        let sql = "SELECT $tag$hello; world$tag$; SELECT 2;"
        let statements = splitter.split(sql)

        XCTAssertEqual(statements.count, 2)
        XCTAssertTrue(statements[0].sql.contains("hello; world"))
    }

    func testGBaseDelimiterProcedure() {
        let splitter = StatementSplitter(databaseType: .gbase8a)
        let sql = """
        DELIMITER $
        CREATE PROCEDURE test_proc()
        BEGIN
            SELECT 1;
        END $
        DELIMITER ;
        SELECT 2;
        """

        let statements = splitter.split(sql)
        XCTAssertEqual(statements.count, 2)
        XCTAssertTrue(statements[0].sql.contains("CREATE PROCEDURE test_proc()"))
        XCTAssertTrue(statements[0].sql.contains("SELECT 1;"))
        XCTAssertTrue(statements[0].sql.contains("END"))
        XCTAssertFalse(statements[0].sql.contains("DELIMITER"))
        XCTAssertTrue(statements[1].sql.contains("SELECT 2"))
    }

    func testGBaseEndWithSpaceIsPreserved() {
        let splitter = StatementSplitter(databaseType: .gbase8a)
        let statements = splitter.split("DELIMITER $\nCREATE PROCEDURE p() BEGIN SELECT 1; END $\nDELIMITER ;")

        XCTAssertEqual(statements.count, 1)
        XCTAssertTrue(statements[0].sql.contains("END "))
    }

    func testGBaseEndWithoutSpaceIsNotRewritten() {
        let splitter = StatementSplitter(databaseType: .gbase8a)
        let statements = splitter.split("DELIMITER $\nCREATE PROCEDURE p() BEGIN SELECT 1; END$\nDELIMITER ;")

        XCTAssertEqual(statements.count, 1)
        XCTAssertTrue(statements[0].sql.contains("END"))
        XCTAssertFalse(statements[0].sql.contains("END $"))
    }
}
