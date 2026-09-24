import XCTest
@testable import DoyahCore

final class SQLLinterTests: XCTestCase {
    func testCleanStatementHasNoDiagnostics() {
        let linter = SQLLinter(databaseType: .postgresql)
        let sql = """
        SELECT id, name
        FROM users
        WHERE name = 'O''Brien' AND id IN (1, 2, 3);
        """
        XCTAssertTrue(linter.analyze(sql).isEmpty)
    
    /// 实时扫描的长度边界（NFR-PERF-05 的阻塞条件之一是"超限要给可读提示"）。
    ///
    /// 这条判据放进 Core 就是为了能单测：阈值是 20_000 **字符**，
    /// 恰好等于不算超、多一个字符算超 —— 边界写错的话，用户会看到"没有问题"的空态，
    /// 而实际上根本没检查（欺骗性空态）。
    func testRealtimeScanLimitBoundary() {
        XCTAssertFalse(sqlExceedsRealtimeScanLimit(String(repeating: "a", count: sqlRealtimeScanLimit)))
        XCTAssertTrue(sqlExceedsRealtimeScanLimit(String(repeating: "a", count: sqlRealtimeScanLimit + 1)))
        XCTAssertFalse(sqlExceedsRealtimeScanLimit("SELECT 1"))
    }
}

    func testUnterminatedString() {
        let linter = SQLLinter(databaseType: .postgresql)
        let diagnostics = linter.analyze("SELECT 'abc")
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics[0].severity, .error)
        XCTAssertTrue(diagnostics[0].message.contains("字符串"))
        XCTAssertEqual(diagnostics[0].line, 1)
        XCTAssertEqual(diagnostics[0].column, 8)
    }

    func testUnterminatedBlockComment() {
        let linter = SQLLinter(databaseType: .postgresql)
        let diagnostics = linter.analyze("SELECT 1 /* 注释没结束")
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertTrue(diagnostics[0].message.contains("块注释"))
    }

    func testUnbalancedParentheses() {
        let linter = SQLLinter(databaseType: .postgresql)
        let diagnostics = linter.analyze("SELECT * FROM t WHERE (a = 1 AND b = 2;")
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertTrue(diagnostics[0].message.contains("左括号"))

        let extra = linter.analyze("SELECT 1);")
        XCTAssertEqual(extra.count, 1)
        XCTAssertTrue(extra[0].message.contains("右括号"))
    }

    func testParenthesesInsideStringAreIgnored() {
        let linter = SQLLinter(databaseType: .postgresql)
        XCTAssertTrue(linter.analyze("SELECT '(' AS a, ')' AS b;").isEmpty)
    }

    func testUnterminatedDollarQuote() {
        let linter = SQLLinter(databaseType: .postgresql)
        let diagnostics = linter.analyze("CREATE FUNCTION f() RETURNS int AS $$ SELECT 1;")
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertTrue(diagnostics[0].message.contains("dollar-quoted"))
    }

    func testClosedDollarQuoteHasNoDiagnostics() {
        let linter = SQLLinter(databaseType: .postgresql)
        let sql = "CREATE FUNCTION f() RETURNS int AS $$ SELECT 1; $$ LANGUAGE sql;"
        XCTAssertTrue(linter.analyze(sql).isEmpty)
    }

    func testDollarParameterIsNotDollarQuote() {
        let linter = SQLLinter(databaseType: .postgresql)
        XCTAssertTrue(linter.analyze("SELECT $1, $2;").isEmpty)
    }

    func testGBaseHashComment() {
        let linter = SQLLinter(databaseType: .gbase8a)
        XCTAssertTrue(linter.analyze("SELECT 1 # 这是注释").isEmpty)
    }

    func testDiagnosticLineAndColumn() {
        let linter = SQLLinter(databaseType: .postgresql)
        let diagnostics = linter.analyze("SELECT 1;\nSELECT '未闭合")
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics[0].line, 2)
        XCTAssertEqual(diagnostics[0].column, 8)
    }
}

final class SQLTokenizerTests: XCTestCase {
    func testKeywordsAndFunctions() {
        let tokenizer = SQLTokenizer.standard(.postgresql)
        let sql = "SELECT count(*) FROM users WHERE id = 1;"
        let tokens = tokenizer.tokenize(sql)

        let keywords = tokens.filter { $0.kind == .keyword }
        XCTAssertEqual(keywords.count, 3) // SELECT FROM WHERE

        let functions = tokens.filter { $0.kind == .function }
        XCTAssertEqual(functions.count, 1)

        let numbers = tokens.filter { $0.kind == .number }
        XCTAssertEqual(numbers.count, 1)
    }

    func testStringAndCommentRanges() {
        let tokenizer = SQLTokenizer.standard(.postgresql)
        let sql = "SELECT 'a;b' -- 注释\nFROM t"
        let tokens = tokenizer.tokenize(sql)

        let string = tokens.first { $0.kind == .string }
        XCTAssertNotNil(string)
        XCTAssertEqual((sql as NSString).substring(with: string!.range), "'a;b'")

        let comment = tokens.first { $0.kind == .comment }
        XCTAssertNotNil(comment)
        XCTAssertEqual((sql as NSString).substring(with: comment!.range), "-- 注释")
    }

    func testDollarQuoteTokenIsString() {
        let tokenizer = SQLTokenizer.standard(.postgresql)
        let sql = "AS $$ SELECT 1; $$ LANGUAGE sql"
        let tokens = tokenizer.tokenize(sql)

        let string = tokens.first { $0.kind == .string }
        XCTAssertNotNil(string)
        XCTAssertTrue((sql as NSString).substring(with: string!.range).hasPrefix("$$"))
    }

    func testUnterminatedStringExtendsToEnd() {
        let tokenizer = SQLTokenizer.standard(.postgresql)
        let sql = "SELECT 'abc"
        let tokens = tokenizer.tokenize(sql)

        let string = tokens.first { $0.kind == .string }
        XCTAssertNotNil(string)
        XCTAssertEqual(string!.range.location, 7)
        XCTAssertEqual(string!.range.length, 4)
    }

    func testKeywordCaseInsensitive() {
        let tokenizer = SQLTokenizer.standard(.postgresql)
        let tokens = tokenizer.tokenize("select 1")
        XCTAssertEqual(tokens.first { $0.kind == .keyword }?.range.location, 0)
    }
}
