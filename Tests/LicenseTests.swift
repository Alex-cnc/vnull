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

/// FR-LIC-02 / FR-NOTE-25：**许可证决定界面显示哪几块**，未授权的区**不出现**（不是灰掉诱导）。
final class LicensePresentationTests: XCTestCase {

    func testStandardShowsOnlyNotes() {
        let items = LicensePresentation.activityItems(for: .notesOnly)
        XCTAssertEqual(items, [.notes], "Standard 只显示笔记")
        XCTAssertFalse(items.contains(.workspace), "Standard 下工作区不可达")
        XCTAssertFalse(items.contains(.database), "Standard 下数据库不可达")
    }

    func testProShowsToolsButNotNotes() {
        let items = LicensePresentation.activityItems(for: [.workspaces, .database])
        XCTAssertEqual(items, [.workspace, .database])
        XCTAssertFalse(items.contains(.notes), "Pro 不含笔记（Q10 的口径：纯 IT 工具类）")
    }

    func testUltraShowsEverythingInDeclarationOrder() {
        XCTAssertEqual(LicensePresentation.activityItems(for: .all), [.workspace, .database, .notes])
    }

    /// 任何档位下都能兜底到一个可见项（不会出现"选中项指向不存在的视图"）。
    func testFallbackAlwaysLandsOnAVisibleItem() {
        for capabilities in [LicenseCapabilities.notesOnly, [.workspaces, .database], .all] {
            let fallback = LicensePresentation.fallbackItem(for: capabilities)
            XCTAssertNotNil(fallback)
            XCTAssertTrue(LicensePresentation.activityItems(for: capabilities).contains(fallback!))
        }
        // 笔记优先（三档里唯一每档都有的能力）
        XCTAssertEqual(LicensePresentation.fallbackItem(for: [.workspaces, .database]), .workspace)
        XCTAssertEqual(LicensePresentation.fallbackItem(for: .notesOnly), .notes)
    }

    /// **Standard 下工作区与数据库真的不可达** —— 不只是"栏上不画"。
    ///
    /// 历史偏好里可能存着 `database`（用户先在 Ultra 用过、后换成 Standard），
    /// 代码里也有直接赋值的入口（对象树命令、工作区页的"去数据库"按钮）。
    /// 这些入口全部经过 `resolveSelection`，所以只要这里钉住，就不存在"绕过界面配置钻进去"的路。
    func testStandardMakesWorkspaceAndDatabaseUnreachable() {
        for attempt in [ActivityBarItem.workspace, .database, .notes] {
            let resolved = LicensePresentation.resolveSelection(attempt, for: .notesOnly)
            XCTAssertEqual(resolved, .notes, "Standard 下点 \(attempt.rawValue) 也只能落到笔记")
        }
        // 想切到未授权的区：解析结果里绝不会出现它
        XCTAssertNotEqual(LicensePresentation.resolveSelection(.database, for: .notesOnly), .database)
        XCTAssertNotEqual(LicensePresentation.resolveSelection(.workspace, for: .notesOnly), .workspace)
    }

    /// 反过来：授权的档位**不该**把用户从自己选的项上赶走（否则切换视图会"弹回"）。
    func testResolveKeepsSelectionWhenVisible() {
        XCTAssertEqual(LicensePresentation.resolveSelection(.database, for: .all), .database)
        XCTAssertEqual(LicensePresentation.resolveSelection(.workspace, for: .all), .workspace)
        XCTAssertEqual(LicensePresentation.resolveSelection(.notes, for: .all), .notes)
        XCTAssertEqual(
            LicensePresentation.resolveSelection(.database, for: [.workspaces, .database]),
            .database
        )
    }

    func testUpgradeLinesListTheOtherEditions() {
        let lines = LicensePresentation.upgradeLines(for: .standard)
        XCTAssertEqual(lines.map(\.edition), [.pro, .ultra])
        XCTAssertTrue(lines.allSatisfy { !$0.items.isEmpty }, "每一版都要逐条列出功能（Q11 要求）")
        XCTAssertTrue(LicensePresentation.upgradeLines(for: .ultra).isEmpty, "已是最高档就不推销")
        // Pro 只看得到往上那一档：**不能向下推销 Standard**（那是降级）。
        XCTAssertEqual(LicensePresentation.upgradeLines(for: .pro).map(\.edition), [.ultra])
    }

    /// 每档都要有一个能在界面上念出来的名字（只写 "Pro" 等于没说）。
    func testEveryEditionHasItsOwnDisplayNameKey() {
        let keys = LicenseEdition.allCases.map { LicensePresentation.displayNameKey(of: $0) }
        XCTAssertEqual(Set(keys).count, LicenseEdition.allCases.count, "两档共用一个名字键")
        for key in keys {
            XCTAssertFalse(LocalizedStrings.text(key, language: .simplifiedChinese).isEmpty)
            XCTAssertNotEqual(
                LocalizedStrings.text(key, language: .simplifiedChinese),
                LocalizedStrings.text(key, language: .english),
                "\(key.rawValue) 的中英文一样，等于没翻译"
            )
        }
    }
}
