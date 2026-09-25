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
