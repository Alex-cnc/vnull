import SwiftUI
import AppKit
import DoyahCore

/// 「备份 / 恢复」面板（FR-IO-04 的界面入口）。
///
/// 三条口径：
/// 1. **命令先给用户看**（密码写成 `***`）—— 这类操作最怕"点了不知道它跑了什么"；
/// 2. **执行前先比工具与服务端主版本**：本机 `pg_dump` 16.2 打 18.6 服务端会被服务端拒绝，
///    不提前拦就会跑到一半才失败；
/// 3. **沙箱下起子进程会被拒**：那种失败给可读指引（用非沙箱构建或走 CLI），
///    而不是把一句原始错误丢给用户 —— 这比"放宽沙箱"更符合项目既有纪律。
struct BackupRestoreSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    @State private var kind: BackupPlan.Kind = .dump
    @State private var format: BackupCommand.Format = .custom
    @State private var archivePath = ""
    @State private var toolPath = ""
    @State private var diagnosis: String?
    @State private var isChecking = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .firstTextBaseline) {
                Text(L(.backupRestoreTitle))
                    .font(Theme.font(.title))
                Spacer()
                Button(L(.commonClose)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Text(L(.backupRestoreHint))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 620, alignment: .leading)

            HairlineView()

            Picker("", selection: $kind) {
                Text(L(.backupRestoreKindDump)).tag(BackupPlan.Kind.dump)
                Text(L(.backupRestoreKindRestore)).tag(BackupPlan.Kind.restore)
                Text(L(.backupRestoreKindDumpAll)).tag(BackupPlan.Kind.dumpAll)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if kind == .dump {
                Picker(L(.backupRestoreFormat), selection: $format) {
                    Text("custom").tag(BackupCommand.Format.custom)
                    Text("plain").tag(BackupCommand.Format.plain)
                    Text("directory").tag(BackupCommand.Format.directory)
                }
                .frame(width: 260)
            }

            HStack {
                TextField(L(.backupRestoreArchive), text: $archivePath)
                Button(L(.backupRestoreChoose)) { choosePath() }
            }

            TextField(L(.backupRestoreTool), text: $toolPath)

            Text(L(.backupRestoreCommandPreview))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))
            Text(previewCommand)
                .font(Theme.font(.mono))
                .textSelection(.enabled)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            if let diagnosis {
                Text(diagnosis)
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.status(.warning))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Spacing.s) {
                Button(L(.backupRestoreCheck)) {
                    isChecking = true
                    Task {
                        diagnosis = await appState.diagnoseBackupTool(draft, password: nil)
                        isChecking = false
                    }
                }
                .disabled(isChecking || !isDraftRunnable)

                Button(L(.backupRestoreRun)) {
                    Task { _ = await appState.runBackupPlan(draft, password: nil) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isDraftRunnable || appState.isBackupRunning)

                if appState.isBackupRunning { ProgressView().controlSize(.small) }
                Spacer()
            }

            if !appState.backupRestoreLog.isEmpty {
                HairlineView()
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(appState.backupRestoreLog.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(Theme.font(.mono))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
        }
        .padding(Spacing.l)
        .frame(width: 700, alignment: .leading)
        .onAppear {
            if toolPath.isEmpty {
                toolPath = BackupPlan.defaultExecutable(for: kind)
            }
        }
        .onChange(of: kind) { _, newValue in
            if toolPath.isEmpty || toolPath == BackupPlan.defaultExecutable(for: .dump)
                || toolPath == BackupPlan.defaultExecutable(for: .restore) {
                toolPath = BackupPlan.defaultExecutable(for: newValue)
            }
        }
    }

    // MARK: 草稿

    /// 当前面板内容对应的计划（**预览与执行是同一个来源**）。
    private var draft: BackupPlan {
        let connection = appState.selectedConnection
        return BackupPlan(
            kind: kind,
            target: BackupCommand.Target(
                host: connection?.host ?? "127.0.0.1",
                port: connection?.port ?? 5432,
                user: connection?.username,
                database: appState.selectedDatabase ?? connection?.database
            ),
            format: format,
            filePath: archivePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : archivePath,
            executableName: toolPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? BackupPlan.defaultExecutable(for: kind)
                : toolPath
        )
    }

    private var isDraftRunnable: Bool { draft.arguments != nil }

    private var previewCommand: String {
        guard let arguments = draft.arguments else {
            return "（还缺归档路径 / 目标库，先补齐）"
        }
        return arguments.joined(separator: " ")
    }

    private func choosePath() {
        // 恢复 = 选已有归档（打开面板）；备份 = 选输出的落点（保存面板）。
        // 两类面板**不能写成一个三元表达式**：它们的专有属性不同，合并成父类型就编译不过（我第一版就这么错的）。
        if kind == .restore {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let url = panel.url else { return }
            archivePath = url.path
        } else {
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = format == .directory ? "backup-dir" : "backup.dump"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            archivePath = url.path
        }
    }
}
