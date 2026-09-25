import DoyahCore
import Foundation

/// **许可签发工具**（发行方侧；不进 .app 包）。
///
/// 用法：
///   doyah-license-tool keygen --out <私钥文件>          # 生成一对密钥，打印公钥（粘进 Core/LicensePublicKey.swift）
///   doyah-license-tool issue --key <私钥文件> --to <署名> --edition ultra|pro|standard \
///        [--max-devices 5] [--expires 2027-12-31] [--out license.doyahlicense]
///   doyah-license-tool verify --license <文件> [--public-key <base64>]   # 校验并打印内容（不带私钥）
///   doyah-license-tool inspect --license <文件>                          # 只解析不看签名（排障用）
///
/// 三条纪律：
///   · **私钥只以文件形式由使用者提供**，本工具不生成副本、不写日志；
///   · `keygen` 生成的文件权限设为 0600，并提示"别把它放进仓库"；
///   · 公钥**打印成一行 base64**，方便粘进 `Core/LicensePublicKey.swift`（多处手抄会抄错）。

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func value(_ flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    fail("用法：keygen | issue | verify | inspect（见源文件顶部说明）")
}

switch command {
case "keygen":
    let outPath = value("--out", in: arguments) ?? "issuer.key"
    let keys = LicenseIssuing.makeKeyPair()
    let url = URL(fileURLWithPath: outPath)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? keys.privateKey.write(to: url, options: [.atomic])
    // 0600：只有本人可读（私钥不该被别人顺手看到）
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outPath)
    print("私钥已写入：\(outPath)（权限 0600；**别放进仓库**，丢了就换钥匙）")
    print("公钥（base64，粘进 Core/LicensePublicKey.swift 的 productionPublicKeysBase64）：")
    print(keys.publicKey.base64EncodedString())

case "issue":
    guard let keyPath = value("--key", in: arguments),
          let issuedTo = value("--to", in: arguments),
          let editionName = value("--edition", in: arguments) else {
        fail("用法：issue --key <私钥文件> --to <署名> --edition ultra|pro|standard [--max-devices 5] [--expires YYYY-MM-DD] [--out <文件>]")
    }
    guard let privateKey = try? Data(contentsOf: URL(fileURLWithPath: keyPath)) else {
        fail("读不到私钥：\(keyPath)")
    }
    let edition: LicenseEdition
    switch editionName.lowercased() {
    case "ultra": edition = .ultra
    case "pro": edition = .pro
    case "standard": edition = .standard
    default: fail("--edition 只支持 ultra / pro / standard")
    }
    var expiresAt: Date?
    if let text = value("--expires", in: arguments) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        guard let date = formatter.date(from: text) else { fail("--expires 需要 YYYY-MM-DD") }
        expiresAt = date
    }
    let license = License(
        issuedTo: issuedTo,
        capabilities: edition.capabilities,
        maxDevices: Int(value("--max-devices", in: arguments) ?? "") ?? License.defaultMaxDevices,
        expiresAt: expiresAt
    )
    do {
        let file = try LicenseIssuing.sign(license, privateKey: privateKey)
        let text = file.encoded()
        if let outPath = value("--out", in: arguments) {
            try text.write(toFile: outPath, atomically: true, encoding: .utf8)
            print("许可证已写入：\(outPath)（\(edition.rawValue)，署名 \(issuedTo)）")
        } else {
            print(text)
        }
    } catch {
        fail("签发失败：\(error.localizedDescription)")
    }

case "verify", "inspect":
    guard let path = value("--license", in: arguments),
          let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("用法：\(command) --license <文件> [--public-key <base64>]")
    }
    guard let file = LicenseFile.decode(text), let license = file.license() else {
        fail("这不是有效的许可证文件（坏格式 / 坏 JSON）")
    }
    print("署名：\(license.issuedTo)")
    print("档位：\(license.edition?.rawValue ?? "未知（能力位组合不是我们卖的档位）")")
    print("设备：\(license.devices.count)/\(license.maxDevices) 台")
    if let expiresAt = license.expiresAt {
        let formatter = ISO8601DateFormatter()
        print("到期：\(formatter.string(from: expiresAt))\(license.isExpired ? "（已过期）" : "")")
    } else {
        print("到期：永久")
    }
    if command == "verify" {
        let keyText = value("--public-key", in: arguments)
            ?? ProcessInfo.processInfo.environment["DOYAH_LICENSE_PUBLIC_KEY"]
        guard let keyText, let verifier = Ed25519LicenseVerifier(rawPublicKey: Data(base64Encoded: keyText) ?? Data()) else {
            fail("需要公钥：--public-key <base64> 或环境变量 DOYAH_LICENSE_PUBLIC_KEY")
        }
        let ok = verifier.isValid(payload: file.payload, signature: file.signature)
        print(ok ? "签名：有效" : "签名：无效（许可证被改过，或公钥不对）")
        exit(ok ? 0 : 1)
    }

default:
    fail("未知子命令：\(command)")
}
