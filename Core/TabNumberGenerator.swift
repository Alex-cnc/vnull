import Foundation

/// 新建查询页签的编号生成器。
///
/// 语义（用户明确要求）：在应用的一个生命周期内**只增不减**——
/// 关闭页签、重命名页签、切换连接都不影响后续编号，避免出现两个「查询 2」。
public struct TabNumberGenerator: Sendable, Equatable {
    private var nextNumber: Int

    public init(startingAt: Int = 1) {
        self.nextNumber = startingAt
    }

    /// 取下一个编号，并把内部计数 +1。
    public mutating func next() -> Int {
        defer { nextNumber += 1 }
        return nextNumber
    }

    /// 下一个将要分配的编号（用于显示 / 断言）。
    public var nextValue: Int {
        nextNumber
    }
}
