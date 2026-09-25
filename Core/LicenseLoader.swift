import Foundation

/// 从本机装载许可证并得出"该呈现哪一版"（FR-LIC-02 的 Core 半边）。
///
/// 界面只需要问它一句：**现在该显示哪几块**。判据（签名 / 到期 / 档位 / 配额）都在 `LicenseGate`，
/// 这里只负责"从哪儿读、读不到怎么办" —— 后者按老规矩**如实说明原因**，不静默当成 Standard 就完了。
public enum LicenseLoader {

    public enum Source: Equatable, Sendable {
        case file(URL)
        /// 还没放许可证（首次安装的正常状态）
        case missing
        /// 文件在但读不出来 / 格式不对（坏文件、手改坏了）
        case unreadable(String)
    }

    public struct LoadResult: Equatable, Sendable {
        public var entitlements: LicenseEntitlements
        public var license: License?
        public var source: Source
    }

    /// 许可证放哪儿：与应用数据同处，文件名固定。
    ///
    /// **`DOYAH_LICENSE_PATH` 可覆盖**（绝对路径）—— 这条存在的理由很实际：
    /// 验收"三档呈现"要来回换许可证，而真许可证在用户的数据目录里；
    /// 有了它就能拿一份临时许可证启动一次，**不动用户那份**（与 `DOYAH_SSH_BINARY`、
    /// `DOYAH_LICENSE_PUBLIC_KEY` 同一套路）。空串视为没设，避免"设成空变量就找不到文件"。
    public static let licensePathEnvironmentKey = "DOYAH_LICENSE_PATH"

    public static func defaultLicenseURL(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment[licensePathEnvironmentKey], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent(DoyahIdentity.applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("license.doyahlicense", isDirectory: false)
    }

    /// 装载并判定。
    ///
    /// - Parameters:
    ///   - url: 许可证位置（默认 `defaultLicenseURL()`，可被 `DOYAH_LICENSE_PATH` 覆盖）。
    ///   - verifier: 签名校验器（默认取 App 内置公钥；取不到就**无法校验** → 降级）。
    public static func load(
        from url: URL? = nil,
        verifier: Ed25519LicenseVerifier? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) -> LoadResult {
        let target = url ?? defaultLicenseURL(environment: environment)
        let resolvedVerifier = verifier ?? LicensePublicKey.verifier(environment: environment)

        guard let text = try? String(contentsOf: target, encoding: .utf8) else {
            return LoadResult(
                entitlements: LicenseGate.evaluate(nil, now: now),
                license: nil,
                source: .missing
            )
        }
        guard let file = LicenseFile.decode(text), let license = file.license() else {
            // 文件在但读不出来：**如实说"读不出来"**，与"还没放许可证"分开 ——
            // 两者的用户动作完全不同（一个是去拿许可证，一个是许可证坏了要重下）。
            return LoadResult(
                entitlements: LicenseGate.evaluate(nil, now: now),
                license: nil,
                source: .unreadable(licenseDecodeFailureHint)
            )
        }
        let entitlements = LicenseGate.evaluate(
            license,
            payload: file.payload,
            signature: file.signature,
            verifier: resolvedVerifier,
            now: now
        )
        return LoadResult(entitlements: entitlements, license: license, source: .file(target))
    }

    /// 坏文件时的说明（走语言表）。
    static var licenseDecodeFailureHint: String {
        LocalizedStrings.text(.licenseUnreadable, language: .simplifiedChinese)
    }

    /// 供界面显示的一句话（**必须能区分"没放"与"坏了"**）。
    public static func summary(for result: LoadResult) -> String {
        switch result.source {
        case .missing:
            return LocalizedStrings.text(.licenseMissing, language: .simplifiedChinese)
        case .unreadable(let reason):
            return LocalizedStrings.format(.licenseUnreadableWithReason, language: .simplifiedChinese, reason)
        case .file:
            switch result.entitlements.basis {
            case .licensed:
                // 档位名**不写进这一句**：档位在界面上是单独一行（`licAboutEdition`），
                // 而且那一行要走 `LicensePresentation.displayNameKey` 才能跟着语言变。
                return LocalizedStrings.text(.licenseActive, language: .simplifiedChinese)
            case .expired(let date):
                return LocalizedStrings.format(
                    .licenseExpired,
                    language: .simplifiedChinese,
                    ISO8601DateFormatter().string(from: date)
                )
            case .invalidSignature:
                return LocalizedStrings.text(.licenseInvalidSignature, language: .simplifiedChinese)
            case .unsupportedVersion(let version):
                return LocalizedStrings.format(
                    .licenseFromFuture,
                    language: .simplifiedChinese,
                    String(version)
                )
            case .unknownEdition:
                return LocalizedStrings.text(.licenseUnknownEdition, language: .simplifiedChinese)
            case .missingLicense:
                return LocalizedStrings.text(.licenseMissing, language: .simplifiedChinese)
            }
        }
    }
}
