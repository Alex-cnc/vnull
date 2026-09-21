import XCTest
@testable import PostgresClientCore

/// FR-DIAG-01 ~ FR-DIAG-02：执行计划解析。
final class ExplainPlanTests: XCTestCase {

    private let textPlan = """
    Hash Join  (cost=1.09..2.20 rows=3 width=68) (actual time=0.050..0.080 rows=3 loops=1)
      Hash Cond: (a.id = b.id)
      ->  Seq Scan on a  (cost=0.00..1.03 rows=3 width=36) (actual time=0.010..0.020 rows=3 loops=1)
      ->  Hash  (cost=1.05..1.05 rows=5 width=32) (actual time=0.020..0.020 rows=5 loops=1)
            ->  Seq Scan on b  (cost=0.00..1.05 rows=5 width=32) (actual time=0.005..0.010 rows=5 loops=1)
    Planning Time: 0.123 ms
    Execution Time: 0.456 ms
    """

    // MARK: - 文本计划

    func testParsesNodeTreeWithDepth() {
        let plan = ExplainPlanParser.parse(text: textPlan)

        XCTAssertEqual(plan.nodes.count, 4)
        XCTAssertEqual(plan.nodes.map(\.depth), [0, 1, 1, 2])
        XCTAssertEqual(plan.nodes[0].label, "Hash Join")
        XCTAssertEqual(plan.nodes[3].label, "Seq Scan on b")
    }

    func testParsesCostRowsAndWidth() {
        let node = ExplainPlanParser.parse(text: textPlan).nodes[0]

        XCTAssertEqual(node.startupCost ?? -1, 1.09, accuracy: 0.0001)
        XCTAssertEqual(node.totalCost ?? -1, 2.20, accuracy: 0.0001)
        XCTAssertEqual(node.estimatedRows, 3)
        XCTAssertEqual(node.width, 68)
    }

    func testParsesActualTimes() {
        let node = ExplainPlanParser.parse(text: textPlan).nodes[0]

        XCTAssertEqual(node.actualStartupTime ?? -1, 0.050, accuracy: 0.0001)
        XCTAssertEqual(node.actualTotalTime ?? -1, 0.080, accuracy: 0.0001)
        XCTAssertEqual(node.actualRows, 3)
        XCTAssertEqual(node.loops, 1)
    }

    func testAttachesDetailLinesToPreviousNode() {
        let plan = ExplainPlanParser.parse(text: textPlan)
        XCTAssertEqual(plan.nodes[0].details, ["Hash Cond: (a.id = b.id)"])
    }

    func testParsesPlanningAndExecutionTime() {
        let plan = ExplainPlanParser.parse(text: textPlan)

        XCTAssertEqual(plan.planningTime ?? -1, 0.123, accuracy: 0.0001)
        XCTAssertEqual(plan.executionTime ?? -1, 0.456, accuracy: 0.0001)
        XCTAssertTrue(plan.isAnalyzed)
    }

    func testNodeTypeIgnoresArrowPrefix() {
        let plan = ExplainPlanParser.parse(text: textPlan)

        XCTAssertEqual(plan.nodes[1].nodeType, "Seq Scan")
        XCTAssertTrue(plan.nodes[1].isSequentialScan)
        XCTAssertFalse(plan.nodes[1].isIndexScan)
    }

    func testSummaryCountsSequentialScans() {
        let plan = ExplainPlanParser.parse(text: textPlan)

        XCTAssertEqual(plan.sequentialScanCount, 2)
        XCTAssertEqual(plan.mostExpensiveNode?.label, "Hash Join")
        XCTAssertEqual(plan.slowestNode?.label, "Hash Join")
        XCTAssertTrue(plan.summaryLines.contains("4 个计划节点"))
        XCTAssertTrue(plan.summaryLines.contains("含 2 处全表扫描"))
    }

    func testIndexScanIsRecognised() {
        let plan = ExplainPlanParser.parse(text:
            "Index Scan using users_pkey on users  (cost=0.15..8.17 rows=1 width=36)"
        )
        XCTAssertEqual(plan.nodes.count, 1)
        XCTAssertTrue(plan.nodes[0].isIndexScan)
        XCTAssertEqual(plan.sequentialScanCount, 0)
        XCTAssertFalse(plan.isAnalyzed)
    }

    func testEmptyTextProducesEmptyPlan() {
        let plan = ExplainPlanParser.parse(text: "   ")
        XCTAssertTrue(plan.isEmpty)
    }

    // MARK: - JSON 计划

    private let jsonPlan = """
    [
      {
        "Plan": {
          "Node Type": "Nested Loop",
          "Startup Cost": 0.29,
          "Total Cost": 16.35,
          "Plan Rows": 3,
          "Plan Width": 68,
          "Actual Startup Time": 0.05,
          "Actual Total Time": 0.09,
          "Actual Rows": 3,
          "Actual Loops": 1,
          "Join Type": "Inner",
          "Plans": [
            {
              "Node Type": "Seq Scan",
              "Relation Name": "users",
              "Startup Cost": 0.00,
              "Total Cost": 1.03,
              "Plan Rows": 3,
              "Plan Width": 36,
              "Filter": "(active = true)"
            }
          ]
        },
        "Planning Time": 0.2,
        "Execution Time": 0.3
      }
    ]
    """

    func testParsesJSONPlanTree() {
        let plan = ExplainPlanParser.parse(json: jsonPlan)

        XCTAssertEqual(plan.nodes.count, 2)
        XCTAssertEqual(plan.nodes[0].label, "Nested Loop")
        XCTAssertEqual(plan.nodes[0].depth, 0)
        XCTAssertEqual(plan.nodes[1].label, "Seq Scan on users")
        XCTAssertEqual(plan.nodes[1].depth, 1)
        XCTAssertTrue(plan.nodes[1].details.contains("Filter: (active = true)"))
        XCTAssertEqual(plan.planningTime ?? -1, 0.2, accuracy: 0.0001)
        XCTAssertEqual(plan.executionTime ?? -1, 0.3, accuracy: 0.0001)
    }

    func testParseAutoDetectsJSON() {
        let plan = ExplainPlanParser.parse(jsonPlan)

        XCTAssertEqual(plan.nodes.count, 2)
        XCTAssertFalse(plan.isAnalyzed)
    }

    func testParseAutoDetectsText() {
        let plan = ExplainPlanParser.parse(textPlan)

        XCTAssertEqual(plan.nodes.count, 4)
        XCTAssertTrue(plan.isAnalyzed)
    }

    func testInvalidJSONFallsBackToTextParsing() {
        let plan = ExplainPlanParser.parse("[not json at all")
        XCTAssertTrue(plan.nodes.isEmpty)
        XCTAssertEqual(plan.rawText, "[not json at all")
    }

    func testDisplayDetailMentionsCostAndActual() {
        let detail = ExplainPlanParser.parse(text: textPlan).nodes[0].displayDetail

        XCTAssertTrue(detail.contains("cost 1.09..2.20"))
        XCTAssertTrue(detail.contains("rows 3"))
        XCTAssertTrue(detail.contains("actual 0.080 ms"))
    }
}
