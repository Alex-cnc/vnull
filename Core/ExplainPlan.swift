import Foundation

/// 执行计划解析（FR-DIAG-01）。
///
/// PostgreSQL 的 `EXPLAIN` 有两种可用形态：
/// - 文本：缩进表示层级，行内带 `cost=… rows=… width=…`，`ANALYZE` 时还有 `actual time=… rows=… loops=…`；
/// - JSON：`EXPLAIN (FORMAT JSON)` 返回一个 JSON 数组，`Plan` 是嵌套结构，附带 `Planning Time` / `Execution Time`。
///
/// 本文件把两种输入统一成「扁平化的节点列表 + 层级深度」，供界面直接画树：
/// 扁平结构比嵌套结构更容易用 `List` / `OutlineGroup` 增量渲染，也更好做「跳到最慢节点」。

/// 计划里的一个节点。
public struct ExplainPlanNode: Identifiable, Hashable, Sendable {
    /// 从 0 开始的稳定下标（同一份计划内唯一）。
    public let id: Int
    /// 缩进层级，0 = 根节点。
    public var depth: Int
    /// 节点主标签，例如 `Seq Scan on users`。
    public var label: String
    /// 其他信息行 / 条件（`Filter:`、`Hash Cond:` 等），文本形态下来自紧随其后的无代价行。
    public var details: [String]
    /// 估算启动代价（`cost=a..b` 的 a）。
    public var startupCost: Double?
    /// 估算总代价（`cost=a..b` 的 b）。
    public var totalCost: Double?
    /// 估算行数。
    public var estimatedRows: Int?
    /// 估算行宽（字节）。
    public var width: Int?
    /// 实际启动耗时（ms，仅 `ANALYZE`）。
    public var actualStartupTime: Double?
    /// 实际总耗时（ms，仅 `ANALYZE`）。
    public var actualTotalTime: Double?
    /// 实际行数（仅 `ANALYZE`）。
    public var actualRows: Int?
    /// 循环次数（仅 `ANALYZE`）。
    public var loops: Int?

    public init(
        id: Int,
        depth: Int,
        label: String,
        details: [String] = [],
        startupCost: Double? = nil,
        totalCost: Double? = nil,
        estimatedRows: Int? = nil,
        width: Int? = nil,
        actualStartupTime: Double? = nil,
        actualTotalTime: Double? = nil,
        actualRows: Int? = nil,
        loops: Int? = nil
    ) {
        self.id = id
        self.depth = depth
        self.label = label
        self.details = details
        self.startupCost = startupCost
        self.totalCost = totalCost
        self.estimatedRows = estimatedRows
        self.width = width
        self.actualStartupTime = actualStartupTime
        self.actualTotalTime = actualTotalTime
        self.actualRows = actualRows
        self.loops = loops
    }

    /// 节点类型（标签的第一段），例如 `Seq Scan`。
    public var nodeType: String {
        if let range = label.range(of: " on ") {
            return String(label[label.startIndex..<range.lowerBound])
        }
        if let range = label.range(of: "  (") {
            return String(label[label.startIndex..<range.lowerBound])
        }
        return label
    }

    /// 是否全表扫描（诊断里最常被点名的信号）。
    public var isSequentialScan: Bool {
        nodeType.hasPrefix("Seq Scan")
    }

    /// 是否走索引。
    public var isIndexScan: Bool {
        nodeType.contains("Index")
    }

    /// 单节点自报的耗时（ms）：优先 `actual total time × loops`，用于找最慢节点。
    public var effectiveTime: Double? {
        guard let actualTotalTime else { return nil }
        return actualTotalTime * Double(max(loops ?? 1, 1))
    }

    /// 界面副标题：`代价 0.00..1.03 · 估算 3 行` / 追加 `实际 0.02 ms · 3 行 × 1`。
    public var displayDetail: String {
        var parts: [String] = []
        if let startupCost, let totalCost {
            parts.append(String(format: "cost %.2f..%.2f", startupCost, totalCost))
        } else if let totalCost {
            parts.append(String(format: "cost %.2f", totalCost))
        }
        if let estimatedRows { parts.append("rows \(estimatedRows)") }
        if let width { parts.append("width \(width)") }
        if let actualTotalTime {
            parts.append(String(format: "actual %.3f ms", actualTotalTime))
        }
        if let actualRows { parts.append("actual rows \(actualRows)") }
        if let loops, loops > 1 { parts.append("loops \(loops)") }
        return parts.joined(separator: " · ")
    }
}

/// 一份完整的执行计划。
public struct ExplainPlan: Sendable {
    /// 扁平化的节点列表（已按出现顺序排好）。
    public var nodes: [ExplainPlanNode]
    /// `Planning Time`（ms）。
    public var planningTime: Double?
    /// `Execution Time`（ms）。
    public var executionTime: Double?
    /// 原始文本（文本形态）或原始 JSON 字符串，便于「查看原文」。
    public var rawText: String

    public init(
        nodes: [ExplainPlanNode] = [],
        planningTime: Double? = nil,
        executionTime: Double? = nil,
        rawText: String = ""
    ) {
        self.nodes = nodes
        self.planningTime = planningTime
        self.executionTime = executionTime
        self.rawText = rawText
    }

    public var isEmpty: Bool { nodes.isEmpty }

    /// 是否包含实际耗时（即用了 `ANALYZE`）。
    public var isAnalyzed: Bool {
        nodes.contains { $0.actualTotalTime != nil }
    }

    /// 全表扫描节点数。
    public var sequentialScanCount: Int {
        nodes.filter(\.isSequentialScan).count
    }

    /// 代价最高的节点（按总代价）。
    public var mostExpensiveNode: ExplainPlanNode? {
        nodes.compactMap { node -> (ExplainPlanNode, Double)? in
            guard let cost = node.totalCost else { return nil }
            return (node, cost)
        }
        .max { $0.1 < $1.1 }?.0
    }

    /// 实际耗时最高的节点（`ANALYZE` 时才有意义）。
    public var slowestNode: ExplainPlanNode? {
        nodes.compactMap { node -> (ExplainPlanNode, Double)? in
            guard let time = node.effectiveTime else { return nil }
            return (node, time)
        }
        .max { $0.1 < $1.1 }?.0
    }

    /// 顶层结论，供计划面板顶部一行展示。
    public var summaryLines: [String] {
        guard !nodes.isEmpty else { return [] }

        var lines: [String] = ["\(nodes.count) 个计划节点"]
        if let planningTime { lines.append(String(format: "规划 %.3f ms", planningTime)) }
        if let executionTime { lines.append(String(format: "执行 %.3f ms", executionTime)) }
        if sequentialScanCount > 0 {
            lines.append("含 \(sequentialScanCount) 处全表扫描")
        }
        if let slowestNode, let time = slowestNode.effectiveTime, time > 0 {
            lines.append(String(format: "最慢节点 %@（%.3f ms）", slowestNode.label, time))
        }
        return lines
    }
}

public enum ExplainPlanParser {

    /// 解析 `EXPLAIN` 的文本输出。
    public static func parse(text: String) -> ExplainPlan {
        let lines = text.components(separatedBy: .newlines)
        var nodes: [ExplainPlanNode] = []
        var planningTime: Double?
        var executionTime: Double?
        // 缩进宽度不固定（PG 用两空格起、层级再累加），因此记录「每个深度对应的缩进列」，
        // 用「当前行缩进 > 栈顶缩进」来判断是否进入下一层。
        var indentStack: [Int] = []

        for rawLine in lines {
            guard !rawLine.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let indent = leadingSpaces(rawLine)
            let content = rawLine.trimmingCharacters(in: .whitespaces)

            if let value = value(after: "Planning Time:", in: content) {
                planningTime = value
                continue
            }
            if let value = value(after: "Execution Time:", in: content) {
                executionTime = value
                continue
            }

            let metrics = parseMetrics(content)
            if metrics.hasCost {
                // 有代价 = 一个真正的计划节点，按缩进确定层级。
                while let last = indentStack.last, indent <= last {
                    indentStack.removeLast()
                }
                let depth = indentStack.count
                indentStack.append(indent)
                nodes.append(
                    ExplainPlanNode(
                        id: nodes.count,
                        depth: depth,
                        label: metrics.label,
                        startupCost: metrics.startupCost,
                        totalCost: metrics.totalCost,
                        estimatedRows: metrics.estimatedRows,
                        width: metrics.width,
                        actualStartupTime: metrics.actualStartupTime,
                        actualTotalTime: metrics.actualTotalTime,
                        actualRows: metrics.actualRows,
                        loops: metrics.loops
                    )
                )
            } else if !nodes.isEmpty {
                // 无代价行（Filter / Hash Cond / Sort Key…）挂到最近的节点上。
                nodes[nodes.count - 1].details.append(content)
            }
        }

        return ExplainPlan(
            nodes: nodes,
            planningTime: planningTime,
            executionTime: executionTime,
            rawText: text
        )
    }

    /// 解析 `EXPLAIN (FORMAT JSON)` 的输出（单元格里是一段 JSON 文本）。
    public static func parse(json text: String) -> ExplainPlan {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = root.first
        else {
            return ExplainPlan(rawText: text)
        }

        var nodes: [ExplainPlanNode] = []
        if let plan = first["Plan"] as? [String: Any] {
            appendJSONNodes(plan, depth: 0, into: &nodes)
        }

        return ExplainPlan(
            nodes: nodes,
            planningTime: (first["Planning Time"] as? NSNumber)?.doubleValue,
            executionTime: (first["Execution Time"] as? NSNumber)?.doubleValue,
            rawText: text
        )
    }

    /// 自动判定：以 `[` / `{` 开头按 JSON 解析，否则按文本解析。
    public static func parse(_ text: String) -> ExplainPlan {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") {
            let plan = parse(json: trimmed)
            if !plan.nodes.isEmpty { return plan }
        }
        return parse(text: text)
    }

    // MARK: - JSON 计划树

    private static func appendJSONNodes(
        _ object: [String: Any],
        depth: Int,
        into nodes: inout [ExplainPlanNode]
    ) {
        let nodeType = object["Node Type"] as? String ?? "Node"
        var label = nodeType
        if let relation = object["Relation Name"] as? String {
            label += " on \(relation)"
        } else if let alias = object["Alias"] as? String, alias != relationName(object) {
            label += " on \(alias)"
        }

        var details: [String] = []
        if let indexName = object["Index Name"] as? String { details.append("Index: \(indexName)") }
        if let filter = object["Filter"] as? String { details.append("Filter: \(filter)") }
        if let cond = object["Hash Cond"] as? String { details.append("Hash Cond: \(cond)") }
        if let joinType = object["Join Type"] as? String { details.append("Join Type: \(joinType)") }

        nodes.append(
            ExplainPlanNode(
                id: nodes.count,
                depth: depth,
                label: label,
                details: details,
                startupCost: number(object["Startup Cost"]),
                totalCost: number(object["Total Cost"]),
                estimatedRows: number(object["Plan Rows"]).map { Int($0) },
                width: number(object["Plan Width"]).map { Int($0) },
                actualStartupTime: number(object["Actual Startup Time"]),
                actualTotalTime: number(object["Actual Total Time"]),
                actualRows: number(object["Actual Rows"]).map { Int($0) },
                loops: number(object["Actual Loops"]).map { Int($0) }
            )
        )

        for child in (object["Plans"] as? [[String: Any]]) ?? [] {
            appendJSONNodes(child, depth: depth + 1, into: &nodes)
        }
    }

    private static func relationName(_ object: [String: Any]) -> String? {
        object["Relation Name"] as? String
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    // MARK: - 文本计划

    private struct Metrics {
        var hasCost = false
        var label = ""
        var startupCost: Double?
        var totalCost: Double?
        var estimatedRows: Int?
        var width: Int?
        var actualStartupTime: Double?
        var actualTotalTime: Double?
        var actualRows: Int?
        var loops: Int?
    }

    private static func parseMetrics(_ line: String) -> Metrics {
        var metrics = Metrics()
        metrics.hasCost = line.contains("cost=")

        // 主标签：去掉 `(cost=…)` / `(actual time=…)` 之后剩下的部分。
        if let range = line.range(of: "  (") {
            metrics.label = String(line[line.startIndex..<range.lowerBound])
        } else {
            metrics.label = line
        }

        // 文本计划里子节点带箭头前缀（`->  Seq Scan on t`），去掉它，
        // 否则 `nodeType` / `isSequentialScan` 这些判定全部失效。
        metrics.label = stripArrowPrefix(metrics.label)

        if let range = line.range(of: "cost=") {
            let tail = line[range.upperBound...]
            let numbers = leadingNumbers(in: tail)
            if numbers.count >= 2 {
                metrics.startupCost = numbers[0]
                metrics.totalCost = numbers[1]
            } else if numbers.count == 1 {
                metrics.totalCost = numbers[0]
            }
        }

        if let range = line.range(of: "rows=") {
            let tail = line[range.upperBound...]
            // `rows=` 在 cost 段是估算行数；actual 段是实际行数。用 `actual time=` 的位置区分。
            let isActualSection = range.lowerBound > (line.range(of: "actual time=")?.lowerBound ?? line.startIndex) && line.contains("actual time=")
            if isActualSection {
                if let first = leadingNumbers(in: tail).first, first >= 0 {
                    metrics.actualRows = Int(first)
                }
            } else {
                metrics.estimatedRows = leadingNumbers(in: tail).first.map { Int($0) }
            }
        }

        if let range = line.range(of: "width=") {
            let tail = line[range.upperBound...]
            metrics.width = leadingNumbers(in: tail).first.map { Int($0) }
        }

        if let range = line.range(of: "actual time=") {
            let tail = line[range.upperBound...]
            let numbers = leadingNumbers(in: tail)
            if numbers.count >= 2 {
                metrics.actualStartupTime = numbers[0]
                metrics.actualTotalTime = numbers[1]
            } else if numbers.count == 1 {
                metrics.actualTotalTime = numbers[0]
            }
        }

        if let range = line.range(of: "loops=") {
            let tail = line[range.upperBound...]
            metrics.loops = leadingNumbers(in: tail).first.map { Int($0) }
        }

        return metrics
    }

    /// 依次取出文本里的所有数字（允许 `12.34`、`.5`）。
    ///
    /// 注意 `cost=1.09..2.20` 这种区间写法：第二个点不是小数点，
    /// 必须停在前一个数字上，否则 `Double("1.09..2.20")` 会解析失败、代价整段丢失。
    private static func leadingNumbers(in text: String) -> [Double] {
        var result: [Double] = []
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)

            let startsNumber: Bool
            if character.isNumber {
                startsNumber = true
            } else if character == ".", next < text.endIndex, text[next].isNumber {
                startsNumber = true
            } else {
                startsNumber = false
            }

            guard startsNumber else {
                // 跳过 `..`、`ms`、空格、`rows=` 这类分隔内容，继续找下一个数字。
                index = next
                continue
            }

            var literal = ""
            var seenDot = false
            while index < text.endIndex {
                let current = text[index]
                if current.isNumber {
                    literal.append(current)
                    index = text.index(after: index)
                    continue
                }
                if current == ".", !seenDot {
                    let following = text.index(after: index)
                    let hasDigitAfterDot = following < text.endIndex && text[following].isNumber
                    guard hasDigitAfterDot else { break }
                    literal.append(current)
                    seenDot = true
                    index = following
                    continue
                }
                break
            }

            if let value = Double(literal) {
                result.append(value)
            }
        }

        return result
    }

    private static func value(after prefix: String, in line: String) -> Double? {
        guard line.hasPrefix(prefix) else { return nil }
        let tail = line.dropFirst(prefix.count)
        return leadingNumbers(in: String(tail)).first
    }

    /// 去掉文本计划的行前缀箭头（`->` / `->>`）。
    private static func stripArrowPrefix(_ label: String) -> String {
        var text = label.trimmingCharacters(in: .whitespaces)
        while text.hasPrefix("-") {
            text.removeFirst()
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    private static func leadingSpaces(_ line: String) -> Int {
        var count = 0
        for character in line {
            if character == " " {
                count += 1
            } else if character == "\t" {
                count += 4
            } else {
                break
            }
        }
        return count
    }
}
