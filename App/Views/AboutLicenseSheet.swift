import AppKit
import DoyahCore
import SwiftUI

/// 「版本与许可证」页（FR-LIC-02）。
///
/// 存在的理由很具体：**活动栏上少了一个区，用户第一反应是"我的东西哪去了"**。
/// 所以这一页必须回答四件事，少一件用户就得猜：
///   ① 我现在是什么版（`licAboutEdition`）；
///   ② 为什么是这一版（许可证有效 / 到期 / 没放 / 坏了 / 签名不对 —— 见 `licenseSummary`）；
///   ③ 许可证放哪儿、怎么让它生效（路径 + 打开文件夹 + 重新读取，**不用重启**）；
///   ④ 别的版能做什么（Q11 的口径：**逐条列出**，不写"解锁更多"）。
///
/// 另外刻意把「活动栏上现在有：…」也显示出来：这一页讲的是"你会看到什么"，
/// 那就直接把当前实际呈现的项念一遍，用户不用自己回去数图标。
struct AboutLicenseSheet: View {

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private var entitlements: LicenseEntitlements { appState.licenseLoad.entitlements }

    private var licensePath: String {
        switch appState.licenseLoad.source {
        case .file(let url): return url.path
        case .missing, .unreadable: return LicenseLoader.defaultLicenseURL().path
        }
    }

    /// 许可证文件到底在不在：决定提示句是"还没放"还是"放了但读不出来"。
    private var licenseFileExists: Bool {
        if case .file = appState.licenseLoad.source { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    currentSection
                    Divider()
                    upgradeSection
                }
                .padding(Spacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 560)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L(.licAboutTitle))
                .font(Theme.font(.title))
            Spacer()
            Button(L(.commonClose)) { dismiss() }
        }
        .padding(Spacing.l)
    }

    // MARK: 当前状态

    private var currentSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            line(L(.licAboutEdition), L(LicensePresentation.displayNameKey(of: entitlements.edition)))
            line(L(.licAboutAppVersion), appVersion)
            line(L(.licAboutActivityItems), activityItemsText)

            // 状态这一行是**为什么**：档位是"结果"，状态是"原因"，两者都要在。
            Text(appState.licenseSummary)
                .font(Theme.font(.body))
                .accessibilityIdentifier("license-status")

            Text(licenseFileLine)
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))
                .textSelection(.enabled)
                .accessibilityIdentifier("license-path")

            if !licenseFileExists {
                Text(L(.licAboutInstallHint))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.secondary))
            }

            HStack(spacing: Spacing.s) {
                Button(L(.licAboutOpenFolder)) { revealLicenseFolder() }
                Button(L(.licAboutReload)) { appState.reloadLicense() }
                Spacer()
            }

            Divider()

            Text(L(.licAboutDevicesTitle))
                .font(Theme.font(.bodyStrong))
            Text(deviceUsageText)
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))
                .textSelection(.enabled)
                .accessibilityIdentifier("license-devices")
        }
    }

    // MARK: 其它版本

    private var upgradeSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(L(.licAboutUpgradeTitle))
                .font(Theme.font(.bodyStrong))
            ForEach(LicensePresentation.upgradeLines(for: entitlements.edition), id: \.edition) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(L(LicensePresentation.displayNameKey(of: entry.edition)))
                        .font(Theme.font(.body))
                    ForEach(entry.items, id: \.self) { item in
                        Text("· " + item)
                            .font(Theme.font(.caption))
                            .foregroundStyle(Theme.text(.secondary))
                    }
                }
            }
            Text(L(.licAboutHidden))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))
                .padding(.top, Spacing.xs)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(L(.commonClose)) { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(Spacing.l)
    }

    // MARK: 文案拼装（**界面侧取键**，切语言才跟得上）

    private func line(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Text(label)
                .font(Theme.font(.body))
            Text(value)
                .font(Theme.font(.body))
                .textSelection(.enabled)
        }
    }

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "—"
    }

    private var activityItemsText: String {
        let names = appState.visibleActivityItems.map { L($0.titleKey) }
        return names.isEmpty ? L(.licAboutNoActivityItems) : names.joined(separator: " · ")
    }

    private var licenseFileLine: String {
        let key: LKey = licenseFileExists ? .licAboutLicensePath : .licAboutNoLicenseFile
        return L(key, licensePath)
    }

    /// 设备配额：**没登记设备就说没登记**，不写"0 台"糊过去（配额是防共享的引信，不是卖点）。
    private var deviceUsageText: String {
        guard let license = appState.licenseLoad.license, !license.devices.isEmpty else {
            let quota = appState.licenseLoad.license?.maxDevices ?? License.defaultMaxDevices
            return L(.licAboutNoDevices, String(quota))
        }
        let names = license.devices.map(\.name).joined(separator: "、")
        return L(
            .licAboutDevices,
            String(license.devices.count),
            String(license.maxDevices),
            names
        )
    }

    private func revealLicenseFolder() {
        let folder = LicenseLoader.defaultLicenseURL().deletingLastPathComponent()
        // 目录还不存在（首次安装）时先建出来再打开：不然"打开文件夹"会静默没反应。
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([LicenseLoader.defaultLicenseURL()])
    }
}
