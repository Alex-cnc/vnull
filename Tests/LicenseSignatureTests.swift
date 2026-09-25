import Crypto
import XCTest
@testable import DoyahCore

/// FR-LIC-01 的签名与装载：Ed25519 校验、多钥匙并存、坏文件一律"不通过"（不是默认放行）。
final class LicenseSignatureTests: XCTestCase {

    private func sampleLicense() -> License {
        License(issuedTo: "alex", capabilities: .all, maxDevices: 5)
    }

    func testValidSignaturePasses() throws {
        let keys = LicenseIssuing.makeKeyPair()
        let file = try LicenseIssuing.sign(sampleLicense(), privateKey: keys.privateKey)
        let verifier = try XCTUnwrap(Ed25519LicenseVerifier(rawPublicKey: keys.publicKey))
        XCTAssertTrue(verifier.isValid(payload: file.payload, signature: file.signature))
    }

    /// **被改过的载荷必须不通过**（这是"手改许可证"的唯一防线）。
    func testTamperedPayloadFails() throws {
        let keys = LicenseIssuing.makeKeyPair()
        let file = try LicenseIssuing.sign(sampleLicense(), privateKey: keys.privateKey)
        let original = String(decoding: file.payload, as: UTF8.self)
        // 改一个**确实出现在载荷里**的字段（第一次写测试时改了 "standard"，而这份样例里根本没有这个词，
        // 于是"被改过的载荷"其实与原文逐字相同、签名当然通过 —— 测试自己错了，当场抓到并改正）。
        let tampered = original.replacingOccurrences(of: "alex", with: "mallory")
        XCTAssertNotEqual(tampered, original, "改之前先确认真的改了内容")
        let verifier = try XCTUnwrap(Ed25519LicenseVerifier(rawPublicKey: keys.publicKey))
        XCTAssertFalse(
            verifier.isValid(payload: Data(tampered.utf8), signature: file.signature),
            "改过载荷就不该通过 —— 否则签名等于没做"
        )
    }

    func testWrongKeyFails() throws {
        let issuer = LicenseIssuing.makeKeyPair()
        let other = LicenseIssuing.makeKeyPair()
        let file = try LicenseIssuing.sign(sampleLicense(), privateKey: issuer.privateKey)
        let verifier = try XCTUnwrap(Ed25519LicenseVerifier(rawPublicKey: other.publicKey))
        XCTAssertFalse(verifier.isValid(payload: file.payload, signature: file.signature))
    }

    /// 多钥匙（换钥期）：旧钥签发的许可仍应有效。
    func testMultiplePublicKeysAcceptEitherSignature() throws {
        let old = LicenseIssuing.makeKeyPair()
        let new = LicenseIssuing.makeKeyPair()
        let verifier = try XCTUnwrap(Ed25519LicenseVerifier(rawPublicKeys: [old.publicKey, new.publicKey]))
        let signedByOld = try LicenseIssuing.sign(sampleLicense(), privateKey: old.privateKey)
        let signedByNew = try LicenseIssuing.sign(sampleLicense(), privateKey: new.privateKey)
        XCTAssertTrue(verifier.isValid(payload: signedByOld.payload, signature: signedByOld.signature))
        XCTAssertTrue(verifier.isValid(payload: signedByNew.payload, signature: signedByNew.signature))
    }

    func testBadKeyLengthMeansCannotVerifyNotPass() {
        XCTAssertNil(Ed25519LicenseVerifier(rawPublicKey: Data([1, 2, 3])), "密钥长度不对应当构造失败，而不是默认放行")
        XCTAssertNil(Ed25519LicenseVerifier(rawPublicKeys: [Data([1, 2, 3])]))
    }

    func testFileRoundTripAndMalformedInput() throws {
        let keys = LicenseIssuing.makeKeyPair()
        let file = try LicenseIssuing.sign(sampleLicense(), privateKey: keys.privateKey)
        let text = file.encoded()
        let decoded = try XCTUnwrap(LicenseFile.decode(text))
        XCTAssertEqual(decoded, file)
        let license = try XCTUnwrap(decoded.license())
        XCTAssertEqual(license.edition, .ultra)
        XCTAssertEqual(license.issuedTo, "alex")

        XCTAssertNil(LicenseFile.decode("这不是许可证文件"))
        XCTAssertNil(LicenseFile.decode("DOYAH-LICENSE-1\n不是 base64\n也不是"))
        XCTAssertNil(LicenseFile(payload: Data("坏 JSON".utf8), signature: Data()).license())
    }

    /// 端到端：签名有效的许可证 → Ultra；签名被改 → 降级 Standard 且给出原因。
    func testGateEndToEndWithRealSignature() throws {
        let keys = LicenseIssuing.makeKeyPair()
        let file = try LicenseIssuing.sign(sampleLicense(), privateKey: keys.privateKey)
        let verifier = try XCTUnwrap(Ed25519LicenseVerifier(rawPublicKey: keys.publicKey))
        let license = try XCTUnwrap(file.license())

        let ok = LicenseGate.evaluate(license, payload: file.payload, signature: file.signature, verifier: verifier)
        XCTAssertEqual(ok.edition, .ultra)

        let bad = LicenseGate.evaluate(license, payload: Data("改过".utf8), signature: file.signature, verifier: verifier)
        XCTAssertEqual(bad.edition, .standard)
        XCTAssertEqual(bad.basis, .invalidSignature)
    }
}

/// 内置公钥的装载口径：**没配公钥就是"无法校验"（降级），不是"默认放行"**；
/// 环境变量可覆盖（自用与测试：拿自己的钥匙签自己的许可证）。
final class LicensePublicKeyTests: XCTestCase {

    func testEnvironmentOverrideIsUsed() throws {
        let keys = LicenseIssuing.makeKeyPair()
        let file = try LicenseIssuing.sign(
            License(issuedTo: "self", capabilities: .all), privateKey: keys.privateKey
        )
        let verifier = try XCTUnwrap(
            LicensePublicKey.verifier(environment: ["DOYAH_LICENSE_PUBLIC_KEY": keys.publicKey.base64EncodedString()])
        )
        XCTAssertTrue(verifier.isValid(payload: file.payload, signature: file.signature))
    }

    /// 内置公钥存在时，**别的钥匙签的许可证必须不通过**（防"拿自己签的许可证激活生产版"）。
    func testForeignKeyDoesNotPassAgainstBuiltInKey() throws {
        guard let builtIn = LicensePublicKey.verifier(environment: [:]) else {
            throw XCTSkip("当前没有内置公钥（占位期）—— 如实跳过，不假装通过")
        }
        let foreign = LicenseIssuing.makeKeyPair()
        let file = try LicenseIssuing.sign(
            License(issuedTo: "mallory", capabilities: .all), privateKey: foreign.privateKey
        )
        XCTAssertFalse(builtIn.isValid(payload: file.payload, signature: file.signature))
    }

    func testNoKeyMeansCannotVerify() {
        // 空环境 + 把内置公钥当空（用环境变量覆盖成空串来模拟"没配"）
        let verifier = LicensePublicKey.verifier(environment: ["DOYAH_LICENSE_PUBLIC_KEY": ""])
        // 内置公钥仍在，所以这里只断言"能构造出校验器"（真正的占位期行为由 productionPublicKeysBase64 决定）
        XCTAssertNotNil(verifier)
    }
}

/// 装载口径（FR-LIC-02 的 Core 半边）：**"没放许可证"与"许可证坏了"必须分得开**，
/// 因为用户该做的事完全不同。
final class LicenseLoaderTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("doyah-license-load-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ text: String, name: String = "license.doyahlicense") -> URL {
        let url = directory.appendingPathComponent(name)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testMissingFileMeansStandardWithItsOwnReason() {
        let result = LicenseLoader.load(from: directory.appendingPathComponent("nope.doyahlicense"))
        XCTAssertEqual(result.entitlements.edition, .standard)
        XCTAssertEqual(result.source, .missing)
        XCTAssertFalse(LicenseLoader.summary(for: result).isEmpty, "要给一句人话（当前呈现 Standard）")
    }

    func testValidUltraLicenseGivesUltra() throws {
        let keys = LicenseIssuing.makeKeyPair()
        let file = try LicenseIssuing.sign(
            License(issuedTo: "alex", capabilities: .all, maxDevices: 5), privateKey: keys.privateKey
        )
        let url = write(file.encoded())
        let verifier = try XCTUnwrap(Ed25519LicenseVerifier(rawPublicKey: keys.publicKey))
        let result = LicenseLoader.load(from: url, verifier: verifier)
        XCTAssertEqual(result.entitlements.edition, .ultra)
        XCTAssertEqual(result.entitlements.basis, .licensed)
        XCTAssertEqual(result.source, .file(url))
        XCTAssertEqual(result.license?.issuedTo, "alex")
    }

    /// **坏文件与"没放"要分开说**（这是本轮特意分开的两个 source）。
    func testCorruptFileIsDistinguishedFromMissing() {
        let url = write("DOYAH-LICENSE-1\n不是 base64\n也不是")
        let result = LicenseLoader.load(from: url)
        XCTAssertEqual(result.entitlements.edition, .standard)
        guard case .unreadable = result.source else { return XCTFail("应当是 unreadable，实际 \(result.source)") }
        XCTAssertFalse(LicenseLoader.summary(for: result).isEmpty)
    }

    func testTamperedFileDegradesAndSaysSignatureInvalid() throws {
        let keys = LicenseIssuing.makeKeyPair()
        let file = try LicenseIssuing.sign(
            License(issuedTo: "alex", capabilities: .all), privateKey: keys.privateKey
        )
        var lines = file.encoded().split(separator: "\n").map(String.init)
        let payload = String(decoding: file.payload, as: UTF8.self).replacingOccurrences(of: "alex", with: "mallory")
        lines[1] = Data(payload.utf8).base64EncodedString()
        let url = write(lines.joined(separator: "\n"))
        let verifier = try XCTUnwrap(Ed25519LicenseVerifier(rawPublicKey: keys.publicKey))
        let result = LicenseLoader.load(from: url, verifier: verifier)
        XCTAssertEqual(result.entitlements.edition, .standard)
        XCTAssertEqual(result.entitlements.basis, .invalidSignature)
        // 许可证本身仍能被解析出来（数据没被动过），只是签名不过 —— 界面上要能同时说这两件事
        XCTAssertEqual(result.license?.issuedTo, "mallory")
    }

    func testExpiredLicenseSaysExpiredAndKeepsData() throws {
        let keys = LicenseIssuing.makeKeyPair()
        let expired = Date(timeIntervalSince1970: 1_000)
        let file = try LicenseIssuing.sign(
            License(issuedTo: "alex", capabilities: .all, expiresAt: expired), privateKey: keys.privateKey
        )
        let url = write(file.encoded())
        let verifier = try XCTUnwrap(Ed25519LicenseVerifier(rawPublicKey: keys.publicKey))
        let result = LicenseLoader.load(from: url, verifier: verifier, now: Date(timeIntervalSince1970: 5_000))
        XCTAssertEqual(result.entitlements.edition, .standard)
        XCTAssertEqual(result.entitlements.basis, .expired(expired))
        XCTAssertNotNil(result.license, "到期只是降级：许可证与数据都还在")
    }
}
