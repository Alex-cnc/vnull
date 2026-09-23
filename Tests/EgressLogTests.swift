import XCTest
@testable import DoyahCore

/// 统一外发日志（NFR-SEC-08）的回归测试。
///
/// 这份日志要支撑的是一句对外承诺：**默认零外发、最小外发**。所以测试盯住四件事：
///   ① 出网必留痕（含"发出前先记"与"失败也记"）；
///   ② 被拦下的请求也留痕（`denied`）；
///   ③ **日志自身不能成为泄漏源**（目标去掉 query/fragment，正文统一脱敏）；
///   ④ 零外发时可验证（没有任何出网 → 日志为空）。
final class EgressLogTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EgressLogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    private func makeLog() -> EgressLog {
        EgressLog(directoryURL: directory)
    }

    // MARK: - 目标净化

    /// query 与 fragment 里最常见地带着密钥，必须被去掉。
    func testSanitizeStripsQueryFragmentAndCredential() {
        let raw = "https://api.openai.com/v1/chat/completions?api_key=sk-secret123#access_token=abc"
        let sanitized = EgressTarget.sanitize(raw)

        XCTAssertEqual(sanitized, "https://api.openai.com/v1/chat/completions")
        XCTAssertFalse(sanitized.contains("sk-secret123"))
        XCTAssertFalse(sanitized.contains("access_token"))
    }

    /// 外部程序名这类非 URL 目标原样保留（但同样过一遍脱敏）。
    func testSanitizeKeepsProgramNames() {
        XCTAssertEqual(EgressTarget.sanitize("pg_dump"), "pg_dump")
        XCTAssertEqual(EgressTarget.sanitize("  ssh  "), "ssh")
    }

    // MARK: - 记录与读取

    func testRecordAppendsAndReadsBackNewestFirst() async throws {
        let log = makeLog()
        let older = EgressEntry(
            timestamp: Date(timeIntervalSince1970: 1_000),
            kind: .agentModel, target: "https://a.example", origin: "智能体 · 生成 SQL",
            outcome: .allowed
        )
        let newer = EgressEntry(
            timestamp: Date(timeIntervalSince1970: 2_000),
            kind: .browser, target: "https://b.example", origin: "浏览器 · 页签 1",
            outcome: .allowed
        )
        await log.append(older)
        await log.append(newer)

        let entries = try await log.entries()
        let count = try await log.count()
        let path = await log.fileLocation().path
        XCTAssertEqual(entries.map(\.target), ["https://b.example", "https://a.example"])
        XCTAssertEqual(count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    /// 零外发可验证：什么都没发生 → 日志为空，且**连文件都不该存在**。
    func testNoEgressMeansEmptyLog() async throws {
        let log = makeLog()
        let entries = try await log.entries()
        let path = await log.fileLocation().path
        XCTAssertEqual(entries.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    /// 被拦下的请求也要留痕（与"没想发"区分开）。
    func testDeniedRequestsAreRecorded() async throws {
        let log = makeLog()
        await log.record(
            kind: .agentModel,
            target: "https://api.example/v1/chat",
            origin: "智能体 · 生成 SQL",
            outcome: .denied,
            detail: "智能体总开关关闭"
        )
        let entries = try await log.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.outcome, .denied)
    }

    // MARK: - 日志自身不得泄漏

    func testLogFileAndExportsNeverContainSecrets() async throws {
        let log = makeLog()
        await log.record(
            kind: .agentModel,
            target: "https://api.example/v1/chat?api_key=sk-shouldnotappear",
            origin: "智能体 · 生成 SQL",
            outcome: .failed,
            detail: "请求头 Authorization: Bearer sk-shouldnotappear"
        )

        let location = await log.fileLocation()
        let raw = try String(contentsOf: location, encoding: .utf8)
        XCTAssertFalse(raw.contains("sk-shouldnotappear"), "落盘内容不得含密钥")
        XCTAssertFalse(raw.contains("Bearer"), "落盘的失败原因也要脱敏")

        let json = try String(data: try await log.exportJSON(), encoding: .utf8) ?? ""
        let csv = try await log.exportCSV()
        XCTAssertFalse(json.contains("sk-shouldnotappear"))
        XCTAssertFalse(csv.contains("sk-shouldnotappear"))
    }

    // MARK: - 导出与清空

    func testExportCSVHasHeaderAndEscapesFields() async throws {
        let log = makeLog()
        await log.record(
            kind: .externalProgram,
            target: "pg_dump",
            origin: "导出 · 连接 A",
            outcome: .allowed,
            detail: "带,逗号 与\"引号\""
        )
        let csv = try await log.exportCSV()
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines.first, "时间,类别,目标,触发来源,结果,补充")
        XCTAssertTrue(csv.contains("\"带,逗号"), "含逗号的字段必须被引号包住")
        XCTAssertTrue(lines.count >= 2)
    }

    func testClearRemovesEverything() async throws {
        let log = makeLog()
        await log.record(kind: .updateCheck, target: "https://update.example", origin: "更新检查", outcome: .allowed)
        try await log.clear()

        let count = try await log.count()
        let path = await log.fileLocation().path
        XCTAssertEqual(count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    // MARK: - HTTP 装饰器（唯一出网缝）

    /// 成功：**发出前先记一条**（进程若中途被杀，记录已在），且包裹的传输只被调用一次。
    func testRecordingTransportRecordsBeforeSending() async throws {
        let log = makeLog()
        let recorder = CountingTransport()
        let transport = EgressRecordingTransport(
            origin: "智能体 · 生成 SQL",
            wrapped: recorder,
            log: log
        )

        var request = URLRequest(url: URL(string: "https://api.example/v1/chat?api_key=sk-x")!)
        request.httpMethod = "POST"
        _ = try await transport.send(request)

        let entries = try await log.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.outcome, .allowed)
        XCTAssertEqual(entries.first?.target, "https://api.example/v1/chat")
        XCTAssertEqual(entries.first?.kind, .agentModel)
        let calls = await recorder.callCount
        XCTAssertEqual(calls, 1, "装饰器不得重复发送请求")
    }

    /// 失败：已发出的记录 + 一条失败记录（**不能只有失败、也不能只有发出**）。
    func testRecordingTransportRecordsFailureAndRethrows() async throws {
        struct FailingTransport: HTTPTransport {
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                throw AppError.queryFailed("网络不可达")
            }
        }
        let log = makeLog()
        let transport = EgressRecordingTransport(
            origin: "智能体 · 生成 SQL",
            wrapped: FailingTransport(),
            log: log
        )

        do {
            _ = try await transport.send(URLRequest(url: URL(string: "https://api.example/v1/chat")!))
            XCTFail("应当把错误继续抛出，不能吞掉")
        } catch {
            // 预期：错误原样上抛
        }

        let entries = try await log.entries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(Set(entries.map(\.outcome)), [.allowed, .failed])
        XCTAssertTrue(entries.contains { ($0.detail ?? "").contains("网络不可达") })
    }
}

/// 统计被调用次数的假传输。
private actor CountingTransport: HTTPTransport {
    private(set) var callCount = 0

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        callCount += 1
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data("{}".utf8), response)
    }
}
