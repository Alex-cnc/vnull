import Foundation

/// 许可与版本呈现（FR-LIC-01~05）。
///
/// **定位（已拍板）**：license **只用来控制功能呈现**（工作区 / 数据库 / 笔记三块），
/// **不用于收费**（Q12：真要收费是 App Store 发布时设置的事，且大概率不收费）。
/// 因此这里**不做 DRM**（ADR-34）：不联网激活、不混淆、不反调试；签名能挡住"手改许可证"就够。
///
/// **本文件只做纯逻辑**（能力位 / 版本判定 / 设备配额 / 到期），**签名校验走注入的校验器** ——
/// 这样它今天就能被单测穷举，而 Ed25519 的具体实现（`swift-crypto`）作为下一步接进来，
/// 不与判据缠在一起（工程里"端口探测""SSH 可执行文件"都是这个套路）。
public enum LicenseFormat {
    public static let currentVersion = 1
}

/// 三块能力的位。
public struct LicenseCapabilities: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let workspaces = LicenseCapabilities(rawValue: 1 << 0)
    public static let database = LicenseCapabilities(rawValue: 1 << 1)
    public static let notes = LicenseCapabilities(rawValue: 1 << 2)

    /// 三块全给（Ultra）。
    public static let all: LicenseCapabilities = [.workspaces, .database, .notes]
    /// 只有笔记（Standard）。
    public static let notesOnly: LicenseCapabilities = [.notes]
}

/// 版本档：由能力位推导，**不单独存**（避免"档位与能力位打架"这种自相矛盾的数据）。
public enum LicenseEdition: String, Codable, Sendable, CaseIterable {
    case standard
    /// 工作区 + 数据库，不要笔记。
    case pro
    case ultra

    public var capabilities: LicenseCapabilities {
        switch self {
        case .standard: return .notesOnly
        case .pro: return [.workspaces, .database]
        case .ultra: return .all
        }
    }

    public static func from(_ capabilities: LicenseCapabilities) -> LicenseEdition? {
        switch capabilities {
        case .notesOnly: return .standard
        case [.workspaces, .database]: return .pro
        case .all: return .ultra
        default: return nil  // 只授权工作区或数据库其中一块：不是我们卖的档位，如实判为无效
        }
    }
}

/// 一台已激活的设备。**只用随机标识，不采集硬件指纹**（已拍板）。
public struct LicenseDevice: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var addedAt: Date

    public init(id: UUID = UUID(), name: String, addedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.addedAt = addedAt
    }
}

/// 许可证内容。
public struct License: Codable, Equatable, Sendable {
    public var version: Int
    public var issuedTo: String
    public var capabilities: LicenseCapabilities
    /// 设备配额（已拍板默认 **5**）。
    public var maxDevices: Int
    public var expiresAt: Date?
    public var devices: [LicenseDevice]

    public static let defaultMaxDevices = 5

    public init(
        version: Int = LicenseFormat.currentVersion,
        issuedTo: String,
        capabilities: LicenseCapabilities = .notesOnly,
        maxDevices: Int = License.defaultMaxDevices,
        expiresAt: Date? = nil,
        devices: [LicenseDevice] = []
    ) {
        self.version = version
        self.issuedTo = issuedTo
        self.capabilities = capabilities
        self.maxDevices = maxDevices
        self.expiresAt = expiresAt
        self.devices = devices
    }

    public var edition: LicenseEdition? { LicenseEdition.from(capabilities) }
    public var remainingDevices: Int { max(0, maxDevices - devices.count) }
    public var isExpired: Bool { isExpired(now: Date()) }
    public func isExpired(now: Date) -> Bool {
        guard let expiresAt else { return false }
        return now > expiresAt
    }

    public enum DeviceError: Error, Equatable {
        /// 配额已满 —— 必须**指名**先移除哪一台（不给人一句"已达上限"）。
        case quotaExceeded(max: Int, suggestion: String?)
        case alreadyRegistered(UUID)
        case unknownDevice(UUID)
    }

    /// 激活一台设备。配额满时**明确建议移除哪一台**：优先建议"最早激活的那台"。
    public mutating func addDevice(named name: String, id: UUID = UUID(), now: Date = Date()) throws {
        if devices.contains(where: { $0.id == id }) {
            throw DeviceError.alreadyRegistered(id)
        }
        guard devices.count < maxDevices else {
            let suggestion = devices.min { $0.addedAt < $1.addedAt }?.name
            throw DeviceError.quotaExceeded(max: maxDevices, suggestion: suggestion)
        }
        devices.append(LicenseDevice(id: id, name: name, addedAt: now))
    }

    /// 释放一台设备（换机不锁：先把旧机移除，再激活新机）。
    public mutating func removeDevice(id: UUID) throws {
        guard let index = devices.firstIndex(where: { $0.id == id }) else {
            throw DeviceError.unknownDevice(id)
        }
        devices.remove(at: index)
    }
}

/// 签名校验的**注入点**（实现放到平台侧：Ed25519 / `swift-crypto`）。
public protocol LicenseSignatureVerifying: Sendable {
    func isValid(payload: Data, signature: Data) -> Bool
}

/// 呈现判定：**无 license → Standard**（已拍板 Q11），且始终给出"为什么"。
public struct LicenseEntitlements: Equatable, Sendable {
    public enum Basis: Equatable, Sendable {
        case licensed
        case missingLicense
        case expired(Date)
        case unsupportedVersion(Int)
        case invalidSignature
        case unknownEdition
    }

    public var edition: LicenseEdition
    public var capabilities: LicenseCapabilities
    public var basis: Basis
    /// 界面据此提示（**如实**：为什么降级、还剩几天）。
    public var note: String
}

public enum LicenseGate {

    /// 判定当前应呈现哪一档。
    ///
    /// 顺序写死：**版本 → 签名 → 到期 → 档位 → 允许**；任何一步不过都退到 Standard，
    /// 但**降级原因必须能说出来**（用户界面上要显示，而不是悄悄少两块功能区）。
    public static func evaluate(
        _ license: License?,
        payload: Data? = nil,
        signature: Data? = nil,
        verifier: (any LicenseSignatureVerifying)? = nil,
        now: Date = Date()
    ) -> LicenseEntitlements {
        let fallback = LicenseEntitlements(
            edition: .standard,
            capabilities: .notesOnly,
            basis: .missingLicense,
            note: ""
        )
        guard let license else { return fallback }

        if license.version > LicenseFormat.currentVersion {
            return LicenseEntitlements(
                edition: .standard, capabilities: .notesOnly,
                basis: .unsupportedVersion(license.version), note: ""
            )
        }
        if let verifier, let payload, let signature, !verifier.isValid(payload: payload, signature: signature) {
            return LicenseEntitlements(
                edition: .standard, capabilities: .notesOnly, basis: .invalidSignature, note: ""
            )
        }
        if license.isExpired(now: now), let expiresAt = license.expiresAt {
            return LicenseEntitlements(
                edition: .standard, capabilities: .notesOnly, basis: .expired(expiresAt), note: ""
            )
        }
        guard let edition = license.edition else {
            return LicenseEntitlements(
                edition: .standard, capabilities: .notesOnly, basis: .unknownEdition, note: ""
            )
        }
        return LicenseEntitlements(
            edition: edition, capabilities: edition.capabilities, basis: .licensed, note: ""
        )
    }
}

/// 「升级 / 关于」页要**逐条列出各版功能**（已拍板 Q11：不能只写"解锁更多"）。
public enum LicenseEditionCatalog {

    public struct Feature: Equatable, Sendable {
        public var capability: LicenseCapabilities
        public var name: String
    }

    /// 逐条功能清单（顺序即界面顺序）。
    public static let features: [(edition: LicenseEdition, items: [String])] = [
        (.standard, [t(.licFeatureNotes), t(.licFeatureAICapture)]),
        (.pro, [t(.licFeatureDatabase), t(.licFeatureWorkspace)]),
        (.ultra, [t(.licFeatureAllStandard), t(.licFeatureAllPro), t(.licFeatureLink)])
    ]

    public static func items(for edition: LicenseEdition) -> [String] {
        features.first { $0.edition == edition }?.items ?? []
    }
}

/// Core 侧文案（同文件内使用；语言透传见 R-45）。
private func t(_ key: LKey) -> String {
    LocalizedStrings.text(key, language: .simplifiedChinese)
}
