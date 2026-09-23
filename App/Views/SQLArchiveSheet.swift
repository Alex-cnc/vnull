import SwiftUI
import AppKit
import DoyahCore

/// 「查询归档」面板（FR-EDIT-31）。
///
/// 只有两个动作：开关、选目录。选目录走的是与数据任务同一套**授权书签**机制
/// （`OpenPanelDirectoryPicker` + `SecureDirectoryAccess`），所以：
/// 路径永远来自用户亲手选择、沙箱下下次启动仍可用、书签失效时给可读原因。
struct SQLArchiveSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L(.archiveTitle))
                .font(.headline)

            Toggle(L(.archiveEnable), isOn: $appState.isSQLArchiveEnabled)
                .toggleStyle(.switch)

            Text(L(.archiveEnableHint))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 460, alignment: .leading)

            Divider()

            statusRow

            Text(L(.archiveDirectoryHint))
                .font(.caption2)
                .foregroundStyle(.secondary)

            // 跟随工作区时如实说明：用户会想知道"到底写到哪去了"（FR-EDIT-32 衔接）
            if appState.sqlArchiveSource == .workspace, let path = appState.sqlArchiveDirectoryPath {
                Text(L(.archiveUsingWorkspace, path))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(L(.archiveChooseDirectory)) {
                    Task { await appState.chooseSQLArchiveDirectory() }
                }

                if let path = appState.sqlArchiveDirectoryPath {
                    Button(L(.archiveOpenFolder)) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                    .buttonStyle(.link)
                }

                Spacer()

                Button(L(.commonClose)) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task { await appState.refreshSQLArchiveStatus() }
    }

    @ViewBuilder
    private var statusRow: some View {
        if let status = appState.sqlArchiveStatus {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: symbol(for: status))
                    .foregroundStyle(tint(for: status))
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusText(for: status))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    if let hint = hint(for: status) {
                        Text(hint)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } else {
            Text(L(.archiveDirectoryNotAuthorized))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// 状态整句。
    ///
    /// 「可用」这一态用**归档自己的措辞**（归档目录），不能复用数据任务那句「导出目录」——
    /// 在归档面板里说「导出目录」会让人以为串了功能；其余失败态文案本来就是通用的
    /// （授权目录已不存在 / 无权限 / 书签无法解析），直接复用。
    private func statusText(for status: DirectoryAccessStatus) -> String {
        if case .granted(let path, let isStale) = status {
            return L(.archiveDirectoryGranted, path) + (isStale ? L(.archiveDirectoryStale) : "")
        }
        return status.text
    }

    /// 补救建议：复用 `AgentPresentation` 里已有的 `hintKey` 映射，不另写一套文案。
    private func hint(for status: DirectoryAccessStatus) -> String? {
        status.hintKey.map { L($0) }
    }

    /// 图标与配色同样复用已有映射。
    private func symbol(for status: DirectoryAccessStatus) -> String {
        status.symbolName
    }

    private func tint(for status: DirectoryAccessStatus) -> Color {
        status.tint
    }
}
