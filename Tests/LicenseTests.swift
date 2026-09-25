import XCTest
@testable import DoyahCore

/// FR-LIC-01~05：能力位 / 版本判定 / 设备配额 / 到期降级 / 无 license 默认档。
/// **签名校验走注入点**，所以这里能用"永远通过 / 永远不通过"的假校验器把判据穷举。
private struct FakeVerifier: LicenseSignatureVerifying {
    let result: Bool
    func isValid(payload: Data, signature: Data) -> Bool { result }
}

final class LicenseTests: XCTestCase {

    private func license(
        capabilities: LicenseCapabilities = .all,
        maxDevices: Int = License.defaultMaxDevices,
        expiresAt: Date? = nil,
        devices: [LicenseDevice] = []
    ) -> License {
        License(issuedTo: "alex", capabilities: capabilities, maxDevices: maxDevices, expiresAt: expiresAt, devices: devices)
    }

    // MARK: 档位与能力位

    func testEditionIsDerivedFromCapabilities() {
        XCTAssertEqual(license(capabilities: .notesOnly).edition, .standard)
        XCTAssertEqual(license(capabilities: [.workspaces, .database]).edition, .pro)
        XCTAssertEqual(license(capabilities: .all).edition, .ultra)
        // 只授权一块（我们没卖这种档）：如实判为"不是有效档位"，不猜成最接近的
        XCTAssertNil(license(capabilities: [.database]).edition)
    }

    func testEditionCapabilitiesMatchTheMatrix() {
        XCTAssertEqual(LicenseEdition.standard.capabilities, .notesOnly)
        XCTAssertEqual(LicenseEdition.pro.capabilities, [.workspaces, .database])
        XCTAssertEqual(LicenseEdition.ultra.capabilities, .all)
    }

    // MARK: 呈现判定（无 license → Standard，且要说清为什么）

    func testMissingLicenseFallsBackToStandard() {
        let result = LicenseGate.evaluate(nil)
        XCTAssertEqual(result.edition, .standard)
        XCTAssertEqual(result.capabilities, .notesOnly)
        XCTAssertEqual(result.basis, .missingLicense)
    }

    func testValidUltraLicensePresentsUltra() {
        let result = LicenseGate.evaluate(license(), payload: Data("x".utf8), signature: Data("s".utf8), verifier: FakeVerifier(result: true))
        XCTAssertEqual(result.edition, .ultra)
        XCTAssertEqual(result.basis, .licensed)
    }

    func testBadSignatureDegradesButSaysWhy() {
        let result = LicenseGate.evaluate(license(), payload: Data("x".utf8), signature: Data("s".utf8), verifier: FakeVerifier(result: false))
        XCTAssertEqual(result.edition, .standard)
        XCTAssertEqual(result.basis, .invalidSignature, "降级原因必须能说出来，不能悄悄少两块功能区")
    }

    func testExpiredLicenseDegradesToStandard() {
        let past = Date(timeIntervalSince1970: 1_000)
        let result = LicenseGate.evaluate(license(expiresAt: past), now: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(result.edition, .standard)
        XCTAssertEqual(result.basis, .expired(past))
    }

    /// **到期只降级、不锁数据**：许可证对象本身不被改写、设备清单仍在。
    func testExpiryDoesNotTouchData() throws {
        let devices = [LicenseDevice(name: "MacBook")]
        var subject = license(expiresAt: Date(timeIntervalSince1970: 1_000), devices: devices)
        let before = subject
        _ = LicenseGate.evaluate(subject, now: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(subject, before, "判定不该有副作用")
        try subject.removeDevice(id: devices[0].id)
        XCTAssertTrue(subject.devices.isEmpty, "到期后仍能管理设备（换机不锁）")
    }

    func testFutureVersionIsRefusedInsteadOfGuessed() {
        var future = license()
        future.version = LicenseFormat.currentVersion + 1
        let result = LicenseGate.evaluate(future)
        XCTAssertEqual(result.edition, .standard)
        XCTAssertEqual(result.basis, .unsupportedVersion(future.version))
    }

    func testUnknownEditionDegradesToStandard() {
        let result = LicenseGate.evaluate(license(capabilities: [.database]))
        XCTAssertEqual(result.basis, .unknownEdition)
    }

    // MARK: 设备配额（默认 5 台）

    func testDefaultQuotaIsFiveAndCountsRemaining() throws {
        var subject = license()
        XCTAssertEqual(subject.maxDevices, 5)
        XCTAssertEqual(subject.remainingDevices, 5)
        for index in 0..<5 {
            try subject.addDevice(named: "设备\(index)")
        }
        XCTAssertEqual(subject.remainingDevices, 0)
    }

    /// 第 6 台要被拒，并**指名建议移除哪一台**（最早激活的那台）。
    func testSixthDeviceIsRejectedWithAConcreteSuggestion() throws {
        var subject = license(maxDevices: 5)
        try subject.addDevice(named: "手机A", now: Date(timeIntervalSince1970: 100))
        try subject.addDevice(named: "手机B", now: Date(timeIntervalSince1970: 200))
        try subject.addDevice(named: "Mac", now: Date(timeIntervalSince1970: 300))
        try subject.addDevice(named: "Win", now: Date(timeIntervalSince1970: 400))
        try subject.addDevice(named: "公司电脑", now: Date(timeIntervalSince1970: 500))

        XCTAssertThrowsError(try subject.addDevice(named: "第六台")) { error in
            guard case License.DeviceError.quotaExceeded(let max, let suggestion) = error else {
                return XCTFail("应当是配额超限，实际 \(error)")
            }
            XCTAssertEqual(max, 5)
            XCTAssertEqual(suggestion, "手机A", "要指名先移除哪一台，不能只说'已达上限'")
        }
    }

    func testRegisteredDeviceCannotBeAddedTwice() throws {
        var subject = license()
        let id = UUID()
        try subject.addDevice(named: "Mac", id: id)
        XCTAssertThrowsError(try subject.addDevice(named: "Mac", id: id)) { error in
            XCTAssertEqual(error as? License.DeviceError, .alreadyRegistered(id))
        }
    }

    /// **换机不锁**：移除旧设备后配额立刻回到可加状态。
    func testRemovingADeviceFreesTheQuota() throws {
        var subject = license(maxDevices: 2)
        try subject.addDevice(named: "旧手机")
        try subject.addDevice(named: "旧电脑")
        XCTAssertThrowsError(try subject.addDevice(named: "新电脑"))
        let old = subject.devices[0].id
        try subject.removeDevice(id: old)
        XCTAssertEqual(subject.remainingDevices, 1)
        try subject.addDevice(named: "新电脑")
        XCTAssertEqual(subject.devices.count, 2)
        let missing = UUID()
        XCTAssertThrowsError(try subject.removeDevice(id: missing)) { error in
            XCTAssertEqual(error as? License.DeviceError, .unknownDevice(missing))
        }
    }

    // MARK: 升级提示（Q11：逐条列出各版功能）

    func testEditionCatalogListsFeaturesPerEdition() {
        XCTAssertTrue(LicenseEditionCatalog.items(for: .standard).contains { $0.contains("笔记") })
        XCTAssertTrue(LicenseEditionCatalog.items(for: .pro).contains { $0.contains("数据库") })
        let ultra = LicenseEditionCatalog.items(for: .ultra)
        XCTAssertEqual(ultra.count, 3, "Ultra 要写明'含 Standard 与 Pro 的全部'再加联动能力")
        XCTAssertEqual(LicenseEditionCatalog.features.count, 3)
    }
}
