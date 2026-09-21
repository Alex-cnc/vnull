import XCTest
@testable import PostgresClientCore

final class TabNumberGeneratorTests: XCTestCase {

    func testNumbersAreSequential() {
        var generator = TabNumberGenerator()

        XCTAssertEqual(generator.next(), 1)
        XCTAssertEqual(generator.next(), 2)
        XCTAssertEqual(generator.next(), 3)
        XCTAssertEqual(generator.nextValue, 4)
    }

    /// 关闭 / 重命名页签不影响后续编号：生成器只增不减。
    func testNumbersKeepIncreasingAfterTabsAreClosed() {
        var generator = TabNumberGenerator()

        let first = generator.next()
        let second = generator.next()
        XCTAssertEqual([first, second], [1, 2])

        // 模拟关闭「查询 1」后再新建：仍然从 3 开始，而不是回到 2。
        XCTAssertEqual(generator.next(), 3)
        XCTAssertEqual(generator.next(), 4)
    }

    func testGeneratorsAreIndependent() {
        var a = TabNumberGenerator()
        var b = TabNumberGenerator()

        XCTAssertEqual(a.next(), 1)
        XCTAssertEqual(a.next(), 2)
        XCTAssertEqual(b.next(), 1)
    }
}
