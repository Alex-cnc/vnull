import Foundation

/// 产品身份常量 —— **改名的单一事实来源**。
///
/// 为什么要集中到一处：2026-09-22 从 `PostgresClient` 改名为 **Doyah Studio** 时发现，
/// 这几样东西原本散在 9 个文件里：包标识出现在构建脚本、`project.yml` 与钥匙串兜底值里，
/// 而 Application Support 的目录名在 6 个 Store（连接档 / 保存查询 / 智能体配置 /
/// 数据任务 / 审计日志 / 目录书签）里各写了一份字面量。下次再改名，只改这一个文件。
///
/// 注意区分两类常量：
/// - **现行**身份：新代码一律用它们；
/// - **历史**身份（`legacy*`）：只有一次性数据迁移会用（`Scripts/migrate-doyah-identity.sh`），
///   迁移完成后也不要删 —— 老容器/老钥匙串条目可能还在别人机器上，删了就再也迁不动了。
public enum DoyahIdentity {

    // MARK: - 现行身份

    /// 反查 DNS 形式的包标识。必须与 `project.yml` 的 `PRODUCT_BUNDLE_IDENTIFIER`
    /// 以及 `Scripts/build-app.sh` 写进 `Info.plist` 的 `CFBundleIdentifier` 一致。
    ///
    /// 它同时决定三件事：沙箱容器位置、钥匙串 service 名（`KeychainSecretStore` 的默认值）、
    /// 以及 UserDefaults 的域。**改它 = 换容器 + 换钥匙串 = 必须配迁移。**
    public static let bundleIdentifier = "studio.doyah.DoyahStudio"

    /// Application Support 下的数据目录名。
    public static let applicationSupportDirectoryName = "DoyahStudio"

    /// 钥匙串 service 名的默认值：优先取运行时的真实包标识，取不到才退回常量
    /// （例如 CLI 这类没有 bundle 的可执行文件）。
    public static var keychainServiceName: String {
        Bundle.main.bundleIdentifier ?? bundleIdentifier
    }

    /// 终端里对外报出的版本名（XTVERSION 应答，`ESC P > | 名字 ESC \`）。
    ///
    /// **不冒充 xterm**：报自己的名字与版本，程序据此知道对面不是 xterm，
    /// 从而走保守分支（冒充的话它会按 xterm 的能力表来用我们没实现的东西）。
    public static var terminalVersionName: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        if let version, !version.isEmpty { return "DoyahStudio \(version)" }
        return "DoyahStudio"
    }

    // MARK: - 历史身份（仅供一次性迁移）

    /// 改名前的包标识（= 旧钥匙串 service 名、旧沙箱容器名）。
    public static let legacyBundleIdentifier = "com.vnull.PostgresClient"

    /// 改名前的数据目录名。
    public static let legacyApplicationSupportDirectoryName = "PostgresClient"
}
