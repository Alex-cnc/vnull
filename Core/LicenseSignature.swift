import Crypto
import Foundation

/// 许可签名的校验实现（FR-LIC-01）：**Ed25519**，公钥内置、离线校验。
///
/// 三条口径写死在类型上：
///   · **只做签名校验，不做 DRM**（ADR-34）：不联网激活、不混淆、不反调试；
///   · 用的是 **swift-crypto**（跨平台）而不是 Apple 的 CryptoKit —— 同一个 Core 将来要给
///     `Doyah Notes` 的 Windows / 安卓 / 鸿蒙版复用；
///   · 校验**失败只降级**（退到 Standard），**不锁数据**（`LicenseGate.evaluate` 已有断言）。
public struct Ed25519LicenseVerifier: LicenseSignatureVerifying {

    private let publicKey: Curve25519.Signing.PublicKey?

    /// 用 32 字节原始公钥初始化。**密钥长度不对就当作"无法校验"**（不是"校验通过"）。
    public init?(rawPublicKey: Data) {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawPublicKey) else {
            return nil
        }
        self.publicKey = key
    }

    /// 多把钥匙（换钥期：新旧公钥并存，旧签发的许可仍然有效）。
    public init?(rawPublicKeys: [Data]) {
        let keys = rawPublicKeys.compactMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
        guard !keys.isEmpty else { return nil }
        self.publicKeys = keys
        self.publicKey = keys.first
    }

    private var publicKeys: [Curve25519.Signing.PublicKey] = []

    public func isValid(payload: Data, signature: Data) -> Bool {
        let candidates = publicKeys.isEmpty ? (publicKey.map { [$0] } ?? []) : publicKeys
        // **任何一把钥匙验证通过就算通过**；一把都不通过就是不通过（不"默认放行"）。
        return candidates.contains { $0.isValidSignature(signature, for: payload) }
    }
}

/// 许可证文件（`*.doyahlicense`）的装载：`payload` 是 JSON，`signature` 是 detached 签名。
public struct LicenseFile: Equatable, Sendable {
    public var payload: Data
    public var signature: Data

    public init(payload: Data, signature: Data) {
        self.payload = payload
        self.signature = signature
    }

    /// 带外格式（够用即止，**故意简单到能被人看懂**）：
    /// ```
    /// DOYAH-LICENSE-1
    /// <base64 的 JSON 载荷>
    /// <base64 的签名>
    /// ```
    public static let header = "DOYAH-LICENSE-1"

    public func encoded() -> String {
        [LicenseFile.header, payload.base64EncodedString(), signature.base64EncodedString()]
            .joined(separator: "\n")
    }

    public static func decode(_ text: String) -> LicenseFile? {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 3, lines[0] == header,
              let payload = Data(base64Encoded: lines[1]),
              let signature = Data(base64Encoded: lines[2]) else { return nil }
        return LicenseFile(payload: payload, signature: signature)
    }

    /// 解析载荷为许可证（坏 JSON / 缺字段一律 nil —— 交给上层降级并说明原因）。
    public func license() -> License? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(License.self, from: payload)
    }
}

public enum LicenseIssuing {
    /// 签发（**只在发行方侧使用**；仓库里不放私钥，测试用临时密钥）。
    public static func sign(_ license: License, privateKey: Data) throws -> LicenseFile {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(license)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        return LicenseFile(payload: payload, signature: try key.signature(for: payload))
    }

    /// 生成一对临时密钥（测试与本地验证用）。
    public static func makeKeyPair() -> (privateKey: Data, publicKey: Data) {
        let key = Curve25519.Signing.PrivateKey()
        return (key.rawRepresentation, key.publicKey.rawRepresentation)
    }
}
