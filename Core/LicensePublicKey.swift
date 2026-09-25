import Foundation

/// **App 内置的公钥**（需求提出者口径：「app 自己保存一个公钥来对 license 进行校验」）。
///
/// 三条口径：
///   · 这里只放**公钥**——私钥在发行方手里（`doyah-license-tool keygen` 生成，**绝不入库**）；
///   · 公钥可以有**多把**（换钥期：旧钥签发的许可仍然有效），顺序无关；
///   · `DOYAH_LICENSE_PUBLIC_KEY` 环境变量可覆盖（自用与测试：拿自己的钥匙签发自己的许可证）。
public enum LicensePublicKey {

    /// 生产公钥（base64，32 字节）。
    ///
    /// **当前是占位**：等第一对正式密钥生成后替换（`doyah-license-tool keygen` 会打印可粘贴的一行）。
    /// 占位期间的行为是**诚实的降级**：校验器构造失败 ⇒ 任何许可证都判为签名不通过 ⇒ 呈现 Standard，
    /// 而不是"公钥没配就默认放行"（那等于把许可控制关掉）。
    public static let productionPublicKeysBase64: [String] = [
        // 第一把正式公钥（2026-09-25 由 doyah-license-tool keygen 生成；私钥在发行方手上，未入库）
        "ArxOeIS+FxCLwp32B80+t2wI0Wy6xynJNhDWsOmW/IM=",
    ]

    /// 解析出可用的校验器；没有任何可用公钥时返回 nil（调用方据此**如实降级**）。
    public static func verifier(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Ed25519LicenseVerifier? {
        if let override = environment["DOYAH_LICENSE_PUBLIC_KEY"], !override.isEmpty {
            let keys = override
                .split(whereSeparator: { $0 == "," || $0 == " " })
                .compactMap { Data(base64Encoded: String($0)) }
            if let verifier = Ed25519LicenseVerifier(rawPublicKeys: keys) {
                return verifier
            }
        }
        let keys = productionPublicKeysBase64.compactMap { Data(base64Encoded: $0) }
        return Ed25519LicenseVerifier(rawPublicKeys: keys)
    }
}
