import SwiftUI
import AppKit
import DoyahCore

/// 「备份 / 恢复」面板（FR-IO-04 的界面入口 + FR-IO-05 的「恢复到指定库」）。
///
/// 四条口径：
/// 1. **命令先给用户看**（密码写成 `***`）—— 这类操作最怕"点了不知道它跑了什么"；
/// 2. **执行前先比工具与服务端主版本**：本机 `pg_dump` 16.2 打 18.6 服务端会被服务端拒绝，
///    不提前拦就会跑到一半才失败；
/// 3. **沙箱下起子进程会被拒**：那种失败给可读指引（用非沙箱构建或走 CLI），
///    而不是把一句原始错误丢给用户 —— 这比"放宽沙箱"更符合项目既有纪律；
/// 4. **恢复要有去处**：目标库、分段、`--clean` / `--jobs` 都在这里选，
///    失败后把**可粘贴的续跑命令**写进日志（FR-IO-05）—— 恢复失败最需要的不是"再来一次",
///    而是"从哪一段接着做"。
struct BackupRestoreSheet: View {
    /// 恢复的三种走法。**逐段是默认**：只有逐段才知道"停在哪一段"，也才给得出续跑建议。
    private enum RestoreMode: Hashable {
        /// 逐段依次（结构 → 数据 → 索引与约束），每段内部遇错即停。
        case sectioned
        /// 一次性 `pg_restore`（不分段）。
        case unsectioned
        /// 只跑某一段。
        case single(RestoreSection)
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    @State private var kind: BackupPlan.Kind = .dump
    @State private var format: BackupCommand.Format = .custom
    @State private var archivePath = ""
    @State private var toolPath = ""
    @State private var diagnosis: String?
    @State private var isChecking = false

    // MARK: 恢复（FR-IO-05）

    /// 恢复到**哪一个库**。空 = 用当前连接的库（口径写在提示里，不悄悄替用户决定）。
    @State private var targetDatabase = ""
    @State private var restoreMode: RestoreMode = .sectioned
    @State private var restoreClean = false
    /// 0 = 不并行（`--jobs` 不传）。
    @State private var restoreJobs = 0

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

            if kind == .restore {
                restoreOptions
            }

            TextField(L(.backupRestoreTool), text: $toolPath)

            Text(L(.backupRestoreCommandPreview))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))
            Text(previewCommand)
                .font(Theme.font(.mono))
                .textSelection(.enabled)
                .lineLimit(4)
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

                Button(kind == .restore ? L(.backupRestoreRunRestore) : L(.backupRestoreRun)) {
                    Task { await run() }
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
            if targetDatabase.isEmpty {
                targetDatabase = appState.selectedDatabase ?? appState.selectedConnection?.database ?? ""
            }
        }
        .onChange(of: kind) { _, newValue in
            if toolPath.isEmpty || toolPath == BackupPlan.defaultExecutable(for: .dump)
                || toolPath == BackupPlan.defaultExecutable(for: .restore)
                || toolPath == BackupPlan.defaultExecutable(for: .dumpAll) {
                toolPath = BackupPlan.defaultExecutable(for: newValue)
            }
        }
    }

    // MARK: 恢复的三个选项

    private var restoreOptions: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                Text(L(.backupRestoreTargetDatabase))
                    .font(Theme.font(.body))
                    .frame(width: 200, alignment: .leading)
                TextField("", text: $targetDatabase)
                    .font(Theme.font(.mono))
            }
            Text(L(.backupRestoreTargetDatabaseHint))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Spacing.s) {
                Text(L(.backupRestoreSection))
                    .font(Theme.font(.body))
                    .frame(width: 200, alignment: .leading)
                Picker("", selection: $restoreMode) {
                    Text(L(.backupRestoreModeSectioned)).tag(RestoreMode.sectioned)
                    Text(L(.backupRestoreSectionAll)).tag(RestoreMode.unsectioned)
                    Text(L(.backupRestoreSectionPreData)).tag(RestoreMode.single(.preData))
                    Text(L(.backupRestoreSectionData)).tag(RestoreMode.single(.data))
                    Text(L(.backupRestoreSectionPostData)).tag(RestoreMode.single(.postData))
                }
                .labelsHidden()
                .frame(maxWidth: 360)
            }

            HStack(spacing: Spacing.l) {
                Toggle(L(.backupRestoreClean), isOn: $restoreClean)
                    .toggleStyle(.checkbox)

                Stepper(
                    value: $restoreJobs,
                    in: 0...16
                ) {
                    Text(restoreJobs == 0
                        ? L(.backupRestoreJobsLabelOff)
                        : L(.backupRestoreJobsLabel, restoreJobs))
                        .font(Theme.font(.body))
                }
                .frame(width: 260, alignment: .leading)
            }
        }
        .padding(Spacing.s)
        .background(
            RoundedRectangle(cornerRadius: Radius.card)
                .fill(Theme.surface(Surface.panel))
        )
    }

    // MARK: 草稿

    /// 当前面板内容对应的计划（**预览与执行是同一个来源**）。
    private var draft: BackupPlan {
        let connection = appState.selectedConnection
        let restoreTarget = targetDatabase.trimmingCharacters(in: .whitespacesAndNewlines)
        return BackupPlan(
            kind: kind,
            target: BackupCommand.Target(
                host: connection?.host ?? "127.0.0.1",
                port: connection?.port ?? 5432,
                user: connection?.username,
                // 恢复的去向以**目标库**为准（这正是 FR-IO-05 的"恢复到指定库"）；
                // 备份仍然是对当前连接的库。
                database: kind == .restore
                    ? (restoreTarget.isEmpty ? nil : restoreTarget)
                    : (appState.selectedDatabase ?? connection?.database)
            ),
            format: format,
            filePath: archivePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : archivePath,
            jobs: restoreJobs > 0 ? restoreJobs : nil,
            clean: restoreClean,
            section: previewSection,
            // 单段恢复必须"遇错即停"：不停下来就不知道接下来该从哪一段接着做。
            exitOnError: previewSection != nil,
            executableName: toolPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? BackupPlan.defaultExecutable(for: kind)
                : toolPath
        )
    }

    /// 预览里 `--section` 用哪一段：只有"只跑某一段"这一档才带段号 ——
    /// 逐段是**多条命令**，由下面 `previewCommand` 逐条列出来，不能塞进一条 argv。
    private var previewSection: String? {
        if case .single(let section) = restoreMode { return section.rawValue }
        return nil
    }

    private var isDraftRunnable: Bool { draft.arguments != nil }

    private var previewCommand: String {
        guard kind == .restore else {
            guard let arguments = draft.arguments else {
                return L(.backupRestoreIncomplete)
            }
            return arguments.joined(separator: " ")
        }
        // 逐段：把三段各自的命令都列出来（用户要看到的就是"它到底会跑哪几条"）。
        if case .sectioned = restoreMode {
            let commands = RestoreSection.allCases.compactMap { section -> String? in
                var plan = draft
                plan.section = section.rawValue
                plan.exitOnError = true
                guard let arguments = plan.arguments else { return nil }
                return "\(section.rawValue): " + arguments.joined(separator: " ")
            }
            return commands.isEmpty ? L(.backupRestoreIncomplete) : commands.joined(separator: "\n")
        }
        guard let arguments = draft.arguments else {
            return L(.backupRestoreIncomplete)
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

    // MARK: 执行

    /// 三条走法共用一个入口，但**失败后的交代不同**：只有真的分段过的才知道停在哪一段。
    private func run() async {
        guard kind == .restore else {
            _ = await appState.runBackupPlan(draft, password: nil)
            return
        }
        let archive = draft.filePath ?? ""
        guard let database = draft.target.database else {
            // 目标库都没有：不执行（`BackupPlan.arguments` 也给不出命令），
            // 直接在日志里说清楚，而不是让一个按钮点下去毫无反应。
            appState.noteBackupLog([L(.backupRestoreTargetDatabaseHint)])
            return
        }

        switch restoreMode {
        case .sectioned:
            // 逐段跑到失败为止；续跑建议由 `runRestoreSections` 自己写（它知道停在哪一段）。
            _ = await appState.runRestoreSections(draft, password: nil)
        case .unsectioned:
            let code = await appState.runBackupPlan(draft, password: nil)
            if code != 0 {
                // 没分段 → 不知道停在哪一段：如实说，并从第一段给出续跑建议。
                appState.appendRestoreResumeHint(
                    archive: archive,
                    database: database,
                    failed: nil,
                    jobs: draft.jobs,
                    clean: draft.clean
                )
            }
        case .single(let section):
            var plan = draft
            plan.section = section.rawValue
            plan.exitOnError = true
            let code = await appState.runBackupPlan(plan, password: nil)
            if code != 0 {
                appState.appendRestoreResumeHint(
                    archive: archive,
                    database: database,
                    failed: section,
                    jobs: plan.jobs,
                    clean: plan.clean
                )
            }
        }
    }
}
