import DoyahCore
import SwiftUI

/// 「连接设置」面板（FR-CONN-20）：保活心跳的开关与间隔。
///
/// **为什么单独开面板，而不是塞进连接表单**：保活是**应用级**策略（一套规则管所有连接），
/// 不是某一条连接的属性 —— 放进连接表单会让人以为"这条开了、那条没开"，
/// 而这恰恰不是实现的语义。
///
/// **为什么还要显示心跳记录**：只给一个开关，用户没法判断它到底有没有在工作。
/// 这里直接展示本次运行的成功 / 失败次数与最近一次失败原因，数据来自 Core 的
/// `KeepAliveRecord`（CLI 与脚本用的是同一份口径，不是界面上另写一套）。
struct ConnectionSettingsSheet: View {

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            keepAliveSection
            Divider()
            footer
        }
        .frame(width: 520)
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(L(.connectionSettingsTitle))
                .font(Theme.font(.title))
            Text(L(.connectionSettingsKeepAliveSection))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
    }

    // MARK: 保活

    private var keepAliveSection: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Toggle(L(.connectionSettingsKeepAliveToggle), isOn: $appState.isKeepAliveEnabled)

            Stepper(
                L(.connectionSettingsKeepAliveInterval, appState.keepAliveIntervalSeconds),
                value: intervalBinding,
                in: KeepAlivePolicy.minimumIntervalSeconds...3600,
                step: 5
            )
            .disabled(!appState.isKeepAliveEnabled)

            Text(L(.connectionSettingsKeepAliveLowerBound))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.tertiary))

            Text(L(.connectionSettingsKeepAliveHint))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))
                .fixedSize(horizontal: false, vertical: true)

            statusLine
        }
        .padding(Spacing.l)
    }

    /// 间隔写入时就夹取下限 —— 存进偏好里的值也应当是有效值，而不是"读出来才发现被 Core 夹了"。
    private var intervalBinding: Binding<Int> {
        Binding(
            get: { appState.keepAliveIntervalSeconds },
            set: { appState.keepAliveIntervalSeconds = max(KeepAlivePolicy.minimumIntervalSeconds, $0) }
        )
    }

    @ViewBuilder
    private var statusLine: some View {
        let record = appState.keepAliveRecord
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if record.total == 0 {
                Text(L(.connectionSettingsKeepAliveNever))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.tertiary))
            } else {
                Text(L(.connectionSettingsKeepAliveStatus, record.successes, record.failures))
                    .font(Theme.font(.caption))
                    .foregroundStyle(record.isHealthy ? Theme.text(.secondary) : Theme.status(.warning))
                if let failure = record.lastFailure {
                    Text(L(.connectionSettingsKeepAliveUnhealthy, failure))
                        .font(Theme.font(.caption))
                        .foregroundStyle(Theme.status(.warning))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: 底部

    private var footer: some View {
        HStack {
            Spacer()
            Button(L(.commonClose)) {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(Spacing.l)
    }
}
