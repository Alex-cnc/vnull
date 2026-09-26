import XCTest
import PostgresNIO
import Logging
@testable import DoyahCore

/// **建连之前先查主机名**（队列 L-14，2026-09-26）。
///
/// 缺陷原话：主机名解析不了时报的是「与数据库的连接中断了」，且不提示主机名可能写错。
/// 根因**不是**文案写错，而是**驱动把原因丢了**：把解析不了的名字交给 `PostgresConnection`，
/// 回来的是 `PSQLError(code: serverClosedConnection)` 且 `underlying == nil` ——
/// `ConnectionFailure` 手上没有任何信息能看出「解析不了」。所以修法不是改措辞，
/// 而是在**建连之前自己查一次**，把确切原因拿到手（`ConnectionFailure.requireResolvableHost`）。
///
/// 这个文件钉三件事：
/// 1. 前置检查真的会拒（并把 host/port/原始串带出来）；
/// 2. 文案说的是**解析**，不是「连接中断」；目标、建议、错误码、原始串都在；
/// 3. **驱动丢原因**这条前提本身有测试守着 —— 哪天驱动补上了，这里会红，
///    提醒我们可以简化（而不是留一段没人再需要的补偿代码）。
final class HostResolutionTests: XCTestCase {

    /// 一个**保证解析不了**的名字（RFC 2606 保留 TLD `.invalid`）。
    private let unknownHost = "no-such-host.invalid"

    /// 本机对这个名字到底解不解析得开 —— 少数环境（企业 DNS / 透明代理）会劫持一切名字。
    /// 那种机器上前置检查本来就该"成功"，所以断言前先自检，避免造出一个只在同款环境里绿的测试。
    private func resolves(_ host: String) -> Bool {
        (try? SocketAddress.makeAddressResolvingHost(host, port: 5432)) != nil
    }

    // MARK: - 前置检查本身

    func testUnresolvableHostIsRejectedBeforeConnecting() throws {
        try XCTSkipIf(resolves(unknownHost), "本环境把 \(unknownHost) 也解析出来了（DNS 劫持），这条断言不适用")

        XCTAssertThrowsError(try ConnectionFailure.requireResolvableHost(unknownHost, port: 5432)) { error in
            guard let failure = error as? ConnectionFailure.HostResolutionFailure else {
                return XCTFail("期望 HostResolutionFailure，实际 \(type(of: error))")
            }
            XCTAssertEqual(failure.host, unknownHost)
            XCTAssertEqual(failure.port, 5432)
            XCTAssertTrue(failure.detail.contains(unknownHost), "原始串要带上名字：\(failure.detail)")
            XCTAssertFalse(failure.detail.isEmpty, "原始串不许空着 —— 排查时它就是唯一证据")
        }
    }

    /// 解析得到的名字**不许**被拒：这道闸只挡"解析不了"，不挡连接建立本身（那由驱动报）。
    func testResolvableTargetsPassPreflight() throws {
        for host in ["127.0.0.1", "::1", "localhost"] {
            XCTAssertNoThrow(
                try ConnectionFailure.requireResolvableHost(host, port: 5432),
                "\(host) 是可解析的，前置检查不该拒"
            )
        }
    }

    // MARK: - 文案：说解析，不说「连接中断」

    func testResolutionFailureIsDescribedAsResolution() throws {
        let failure = ConnectionFailure.HostResolutionFailure(
            host: unknownHost, port: 5432, detail: "SocketAddressError.UnknownHost: nodename nor servname provided, or not known"
        )
        let described = try XCTUnwrap(ConnectionFailure.describe(failure))

        XCTAssertTrue(described.summary.contains("主机名解析不了"), described.summary)
        XCTAssertFalse(described.summary.contains("连接中断"), "这是本轮修掉的那句话：\(described.summary)")
        XCTAssertTrue(described.summary.contains("\(unknownHost):5432"), "要带上目标：\(described.summary)")
        let suggestion = try XCTUnwrap(described.suggestion)
        XCTAssertTrue(suggestion.contains("主机名"), "建议要提醒先看主机名：\(suggestion)")
        XCTAssertEqual(described.code, "hostUnresolvable")
        XCTAssertEqual(described.technicalDetail?.contains("UnknownHost"), true, "原始串要保留")
    }

    /// 调用方给了完整目标（带库名）时用它 —— 跨库时才知道是哪个库失败。
    /// **不带用户**：解析与用哪个账号无关（`userSuffix` 只在认证类失败里才有意义）。
    func testCallerSuppliedTargetWins() throws {
        let failure = ConnectionFailure.HostResolutionFailure(host: unknownHost, port: 5432, detail: "unknown host")
        let target = ConnectionFailure.Target(host: unknownHost, port: 5432, database: "orders", username: "app")
        let described = try XCTUnwrap(ConnectionFailure.describe(failure, target: target))
        XCTAssertTrue(described.summary.contains("\(unknownHost):5432/orders"), described.summary)
        XCTAssertFalse(described.summary.contains("app"), "解析失败与账号无关：\(described.summary)")
    }

    /// `errorDescription` 与台面文案**同一句**（同一条事实不写两份说法）。
    func testErrorDescriptionMatchesTheSurfaceText() {
        let failure = ConnectionFailure.HostResolutionFailure(host: unknownHost, port: 5432, detail: "unknown host")
        XCTAssertEqual(failure.errorDescription, ConnectionFailure.describe(failure)?.summary)
    }

    /// 网络层那句「nodename nor servname」与前置检查**共用同一段文案**：
    /// 两个入口各写一套，正是这类文案长歪的地方。
    func testNetworkBranchSharesTheSameWording() throws {
        let fromMessage = try XCTUnwrap(
            ConnectionFailure.describeNetworkMessage("nodename nor servname provided, or not known")
        )
        let fromPreflight = ConnectionFailure.resolutionDescription(target: nil)
        XCTAssertEqual(fromMessage.summary, fromPreflight.summary)
        XCTAssertEqual(fromMessage.suggestion, fromPreflight.suggestion)
    }

    // MARK: - 驱动丢原因这条**前提**本身（补偿代码的存在理由）

    /// 把解析不了的名字交给驱动：`serverClosedConnection` + **underlying 为 nil**。
    ///
    /// 这条测试不是在考驱动"做得对不对"，而是把**我们为什么需要前置检查**钉住：
    /// 驱动那边没有任何可用的原因，文案层再怎么写也写不出"解析不了"。
    /// 驱动升版后若开始带 underlying，这里会红 —— 那时可以回头简化。
    func testDriverDropsTheResolutionCause() async throws {
        try XCTSkipIf(resolves(unknownHost), "本环境把 \(unknownHost) 也解析出来了（DNS 劫持），这条断言不适用")

        var configuration = PostgresConnection.Configuration(
            host: unknownHost, port: 5432, username: "x", password: "y", database: "x", tls: .disable
        )
        // 真去连也是立刻失败（名字都解析不了），但把超时压到 2 秒，免得劫持环境下拖住整套单测。
        configuration.options.connectTimeout = .seconds(2)

        do {
            _ = try await PostgresConnection.connect(configuration: configuration, id: 9_001, logger: Logger(label: "host-resolution-test"))
            XCTFail("解析不了的名字不该连上")
        } catch {
            let psql = try XCTUnwrap(error as? PSQLError, "期望 PSQLError，实际 \(type(of: error))")
            XCTAssertEqual(psql.code.description, "serverClosedConnection", "驱动的分类与实测一致")
            XCTAssertNil(psql.underlying, "**这就是修法的理由**：驱动没把解析失败的原因带出来")
        }
    }
}
