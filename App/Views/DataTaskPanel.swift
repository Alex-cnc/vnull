import SwiftUI
import PostgresClientCore

/// 「数据任务…」面板（FR-AI-05 / FR-AI-06 / FR-AI-08）。
///
/// 三条需求共用这一个面板，因此布局按「一条任务的完整生命周期」排：
/// 1. **定义**（FR-AI-05）：specs + 源 / 转换 / 目标 / 调度 / 导出，全部可编辑、可保存；
///    保存前**必须**试运行一次 —— 分步说明 + 预览语句（只取 10 行）+ 覆盖告警 + 问题清单，
///    试运行只读、绝不执行；定义有问题时保存按钮直接禁用，并把「哪个字段不行」写出来；
/// 2. **调度**（FR-AI-06）：启用 / 停用、`nextRun`、状态（等待 / 到点 / 错过）、
///    执行历史（状态 / 行数 / 耗时 / 消息）；错过窗口**默认不自动补跑**，只给可读提示；
/// 3. **导出**（FR-AI-08）：只能通过「选择目录…」（`NSOpenPanel` + security-scoped bookmark）
///    指定产物位置，未授权 / 书签失效都给可读状态与补救建议。
///
/// 执行一律走既有闸门：`AppState.requestDataTaskRun` → `AgentActionGate` →（需要时）审批单。
/// 本视图里**没有任何**直接下发 SQL 的入口。
struct DataTaskPanel: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    @State private var query = ""
    @State private var onlyEnabled = false
    @State private var selectedID: UUID?
    /// 正在编辑的副本：改这个不会动到已保存的定义，除非点「保存任务」。
    @State private var draft: DataTaskDefinition?
    /// 最近一次试运行结果；**任何改动都会清掉它**，从而强制「改了就先试运行」。
    @State private var dryRun: TaskDryRun?
    @State private var isSpecSheetPresented = false
    @State private var isDeleteConfirmPresented = false

    // 列表类 / 时间类字段用本地文本承接，避免「输入中的逗号被立刻吃掉」这类问题。
    @State private var sourceColumnsText = ""
    @State private var keyColumnsText = ""
    @State private var runAtText = ""
    @State private var startAtText = ""
    @State private var intervalText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            HStack(alignment: .top, spacing: 12) {
                sidebar
                    .frame(width: 230)
                Divider()
                detail
            }
            Divider()
            footer
        }
        .padding(18)
        .frame(width: 1_060, height: 860)
        .task {
            await appState.loadDataTasks()
            if selectedID == nil, let first = visibleTasks.first {
                loadDraft(first)
            }
        }
        .onChange(of: draft) { _, _ in
            // 定义一改，上一次的试运行结论就作废（保存前必须重新试运行）。
            dryRun = nil
        }
        .onChange(of: sourceColumnsText) { _, newValue in
            draft?.source.columns = Self.parseList(newValue)
        }
        .onChange(of: keyColumnsText) { _, newValue in
            draft?.target.keyColumns = Self.parseList(newValue)
        }
        .onChange(of: runAtText) { _, newValue in
            draft?.schedule.runAt = DataTaskPresentation.parseDate(newValue)
        }
        .onChange(of: startAtText) { _, newValue in
            draft?.schedule.startAt = DataTaskPresentation.parseDate(newValue)
        }
        .onChange(of: intervalText) { _, newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            draft?.schedule.intervalSeconds = trimmed.isEmpty ? nil : TimeInterval(trimmed)
        }
        .sheet(isPresented: $isSpecSheetPresented) {
            DataTaskSpecSheet { definition in
                loadDraft(definition)
                selectedID = nil
                appState.dataTaskMessage = L(.dataTaskSpecGenerated)
            }
        }
        // 审批单挂在本面板上：数据任务的写语句同样要逐次批准（FR-AI-09）。
        .sheet(item: $appState.agentApprovalRequest) { approval in
            AgentApprovalSheet(approval: approval)
        }
        .alert(L(.dataTaskDeleteConfirmTitle), isPresented: $isDeleteConfirmPresented) {
            Button(L(.commonCancel), role: .cancel) {}
            Button(L(.dataTaskDelete), role: .destructive) { deleteSelected() }
        } message: {
            Text(L(.dataTaskDeleteConfirmMessage, draft?.name ?? ""))
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 8) {
            Text(L(.dataTaskTitle))
                .font(.headline)

            Spacer()

            Button(L(.dataTaskNew)) { createNewTask() }
            Button(L(.dataTaskSpecOpen)) { isSpecSheetPresented = true }
            Button(L(.dataTaskRefresh)) {
                Task { await appState.loadDataTasks() }
            }
            Button(L(.commonClose)) { dismiss() }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let error = appState.dataTaskError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else if let message = appState.dataTaskMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L(.dataTaskNotExecutedHint))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 左侧列表

    private var visibleTasks: [DataTaskDefinition] {
        DataTaskPresentation.filter(appState.dataTasks, query: query, onlyEnabled: onlyEnabled)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(L(.dataTaskSearchPlaceholder), text: $query, prompt: Text(L(.dataTaskSearchPlaceholder)))
                .textFieldStyle(.roundedBorder)
            Toggle(L(.dataTaskOnlyEnabled), isOn: $onlyEnabled)
                .font(.caption)

            if visibleTasks.isEmpty {
                Text(appState.dataTasks.isEmpty ? L(.dataTaskListEmpty) : L(.agentAuditFilteredEmpty))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(visibleTasks) { task in
                            taskRow(task)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func taskRow(_ task: DataTaskDefinition) -> some View {
        let decision = appState.dataTaskDecision(for: task)
        let status = DataTaskPresentation.status(for: decision)
        let isSelected = task.id == selectedID

        return Button {
            loadDraft(task)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: status.symbolName)
                        .foregroundStyle(status.tint)
                    Text(task.name)
                        .lineLimit(1)
                    if task.id == draft?.id, isDirty(task) {
                        Circle().fill(.orange).frame(width: 5, height: 5)
                    }
                }
                HStack(spacing: 4) {
                    Text(status.text)
                        .foregroundStyle(status.tint)
                    if !task.isEnabled {
                        Text("· " + L(.dataTaskStatusDisabled))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption2)
            }
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(task.specs)
    }

    /// 当前草稿与给定任务是否有差异（列表上的小圆点）。
    private func isDirty(_ task: DataTaskDefinition) -> Bool {
        guard let draft, draft.id == task.id else { return false }
        return draft != task
    }

    // MARK: - 右侧详情

    @ViewBuilder
    private var detail: some View {
        if draft == nil {
            VStack(alignment: .leading, spacing: 6) {
                Text(L(.dataTaskNoSelection))
                    .font(.callout)
                Text(L(.dataTaskSelectHint))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    specsSection
                    sourceSection
                    transformationSection
                    targetSection
                    scheduleSection
                    exportSection
                    Divider()
                    previewSection
                    Divider()
                    runtimeSection
                    Divider()
                    historySection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - 定义（FR-AI-05）

    private var specsSection: some View {
        section(L(.dataTaskSectionSpecs), hint: L(.dataTaskSpecsHint)) {
            TextEditor(text: binding(\.specs, default: ""))
                .font(.system(.caption, design: .monospaced))
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            HStack(spacing: 8) {
                Text(L(.dataTaskName))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .leading)
                TextField("", text: binding(\.name, default: ""))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var sourceSection: some View {
        section(L(.dataTaskSectionSource)) {
            HStack(spacing: 8) {
                labeledField(L(.dataTaskSchema), text: nullableBinding(\.source.schema))
                labeledField(L(.dataTaskTable), text: binding(\.source.table, default: ""))
            }
            labeledField(L(.dataTaskSourceColumns), text: $sourceColumnsText, hint: L(.dataTaskSourceColumnsHint))
            labeledField(L(.dataTaskFilter), text: nullableBinding(\.source.filter), hint: L(.dataTaskFilterHint))
        }
    }

    private var transformationSection: some View {
        section(L(.dataTaskSectionTransformations)) {
            if draft?.transformations.isEmpty ?? true {
                Text(L(.dataTaskTransformEmpty))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array((draft?.transformations ?? []).indices), id: \.self) { index in
                    transformationRow(index)
                }
            }
            Button(L(.dataTaskAddTransformation)) {
                draft?.transformations.append(.init(kind: .rename))
            }
            .font(.caption)
        }
    }

    private func transformationRow(_ index: Int) -> some View {
        let transformation = draft?.transformations[index] ?? .init(kind: .rename)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Picker("", selection: transformationBinding(index, \.kind, default: .rename)) {
                    ForEach(DataTaskDefinition.Transformation.Kind.allCases, id: \.self) { kind in
                        Text(kind.text).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 130)

                TextField(L(.dataTaskTransformationColumn), text: optionalTransformationBinding(index, \.column))
                    .textFieldStyle(.roundedBorder)
                TextField(L(.dataTaskTransformationTargetColumn), text: optionalTransformationBinding(index, \.targetColumn))
                    .textFieldStyle(.roundedBorder)
                TextField(L(.dataTaskTransformationExpression), text: optionalTransformationBinding(index, \.expression))
                    .textFieldStyle(.roundedBorder)

                Button {
                    if (draft?.transformations.indices.contains(index) ?? false) {
                        draft?.transformations.remove(at: index)
                    }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .help(L(.dataTaskRemoveTransformation))
            }
            .font(.caption)

            if let note = transformation.note, !note.isEmpty {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 138)
            }
        }
    }

    private var targetSection: some View {
        section(L(.dataTaskSectionTarget)) {
            HStack(spacing: 8) {
                labeledField(L(.dataTaskSchema), text: nullableBinding(\.target.schema))
                labeledField(L(.dataTaskTargetTable), text: binding(\.target.table, default: ""))
            }
            HStack(spacing: 8) {
                Text(L(.dataTaskWriteMode))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .leading)
                Picker("", selection: binding(\.target.writeMode, default: .append)) {
                    ForEach(DataTaskDefinition.Target.WriteMode.allCases, id: \.self) { mode in
                        Text(mode.text).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
                Spacer()
            }
            labeledField(L(.dataTaskKeyColumns), text: $keyColumnsText, hint: L(.dataTaskKeyColumnsHint))

            if let draft, draft.target.writeMode == .overwrite {
                warningLabel(L(.dataTaskOverwriteWarning))
            }
            if let draft, draft.target.writeMode == .upsert {
                warningLabel(L(.dataTaskUpsertWarning))
            }
        }
    }

    private var scheduleSection: some View {
        section(L(.dataTaskSectionSchedule)) {
            HStack(spacing: 8) {
                Text(L(.dataTaskScheduleKind))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .leading)
                Picker("", selection: binding(\.schedule.kind, default: .manual)) {
                    ForEach(TaskSchedule.Kind.allCases, id: \.self) { kind in
                        Text(kind.text).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 140)

                Toggle(L(.dataTaskEnabled), isOn: binding(\.isEnabled, default: true))
                    .font(.caption)
                Spacer()
            }

            if let draft, draft.schedule.kind == .once {
                labeledField(L(.dataTaskRunAt), text: $runAtText, hint: L(.dataTaskDateHint))
            }
            if let draft, draft.schedule.kind == .recurring {
                labeledField(L(.dataTaskIntervalSeconds), text: $intervalText, hint: L(.dataTaskDateHint))
                labeledField(L(.dataTaskStartAt), text: $startAtText, hint: L(.dataTaskDateHint))
            }
        }
    }

    // MARK: - 导出（FR-AI-08）

    private var exportSection: some View {
        section(L(.dataTaskSectionExport)) {
            HStack(spacing: 8) {
                Text(L(.dataTaskExportFormat))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .leading)
                Picker("", selection: exportFormatBinding) {
                    ForEach(DataTaskDefinition.ExportSettings.Format.allCases, id: \.self) { format in
                        Text(format.rawValue.uppercased()).tag(format)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
                Spacer()
                Button(L(.dataTaskChooseDirectory)) { chooseDirectory() }
                Menu {
                    if appState.storedDirectoryBookmarks.isEmpty {
                        Text(L(.dataTaskNoStoredDirectory))
                    } else {
                        ForEach(appState.storedDirectoryBookmarks) { bookmark in
                            Button(bookmark.displayName) { useStoredBookmark(bookmark) }
                        }
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L(.dataTaskUseStoredDirectory))
            }
            .font(.caption)

            labeledField(L(.dataTaskFileNameTemplate), text: fileNameTemplateBinding, hint: L(.dataTaskFileNameHint))

            directoryStatusRow

            if draft?.output != nil {
                Button(L(.dataTaskExportVerify)) { verifyDirectory() }
                    .font(.caption)
                    .disabled(directoryStatus?.isUsable != true)
            }
        }
    }

    private var exportFormatBinding: Binding<DataTaskDefinition.ExportSettings.Format> {
        Binding(
            get: { draft?.output?.format ?? .csv },
            set: { newValue in
                guard var draft else { return }
                let template = draft.output?.fileNameTemplate
                if draft.output == nil {
                    draft.output = .init(format: newValue, fileNameTemplate: template)
                } else {
                    draft.output?.format = newValue
                }
                self.draft = draft
            }
        )
    }

    private var fileNameTemplateBinding: Binding<String> {
        Binding(
            get: { draft?.output?.fileNameTemplate ?? "" },
            set: { newValue in
                guard var draft else { return }
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let template: String? = trimmed.isEmpty ? nil : newValue
                if draft.output == nil {
                    draft.output = .init(format: .csv, fileNameTemplate: template)
                } else {
                    draft.output?.fileNameTemplate = template
                }
                self.draft = draft
            }
        )
    }

    private var directoryStatus: DirectoryAccessStatus? {
        appState.dataTaskDirectoryStatus(draft?.output)
    }

    @ViewBuilder
    private var directoryStatusRow: some View {
        if let status = directoryStatus {
            VStack(alignment: .leading, spacing: 2) {
                Label(status.text, systemImage: status.symbolName)
                    .font(.caption2)
                    .foregroundStyle(status.tint)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let hintKey = status.hintKey {
                    Text(L(hintKey))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            Label(L(.dataTaskDirectoryNotAuthorized), systemImage: "folder.badge.plus")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(L(.dataTaskDirectoryHintNotAuthorized))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 试运行与预览（FR-AI-05）

    private var previewSection: some View {
        section(L(.dataTaskSectionPreview), hint: L(.dataTaskDryRunHint)) {
            HStack(spacing: 8) {
                Button(L(.dataTaskDryRun)) { runDryRun() }
                Button(L(.dataTaskRevert)) { revertDraft() }
                    .disabled(draft == nil)
                Spacer()
                Button(L(.dataTaskSave)) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                Button(L(.dataTaskDelete), role: .destructive) {
                    isDeleteConfirmPresented = true
                }
                .disabled(appState.dataTasks.first { $0.id == draft?.id } == nil)
            }
            .font(.caption)

            // 两种「存不了」的原因分开说：定义有问题，还是改完没重新试运行。
            if let draft, !draft.isValid {
                Text(L(.dataTaskSaveBlocked))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if dryRun == nil {
                Text(L(.dataTaskNeedDryRun))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            // 定义校验：把「哪个字段、为什么不行」逐条摊开（Core 的 issues 原文）。
            VStack(alignment: .leading, spacing: 2) {
                Text(L(.dataTaskPreviewIssues))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                let issues = draft?.issues ?? []
                if issues.isEmpty {
                    Label(L(.dataTaskNoIssues), systemImage: "checkmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.green)
                } else {
                    ForEach(issues, id: \.self) { issue in
                        Label(issue, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let dryRun {
                if !dryRun.steps.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L(.dataTaskPreviewSteps))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        ForEach(dryRun.steps, id: \.self) { step in
                            Text("· " + step)
                                .font(.caption2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(L(.dataTaskPreviewSQL))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(dryRun.previewStatements.joined(separator: "\n"))
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    }
                    .frame(height: 96)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                if !dryRun.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L(.dataTaskPreviewWarnings))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        ForEach(dryRun.warnings, id: \.self) { warning in
                            warningLabel(warning)
                        }
                    }
                }
            }

            // 写入语句 + 护栏判定：保存前就能看到「只读模式下会被拒」。
            if let draft {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L(.dataTaskWriteStatement))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let sql = try? DataTaskRunner.writeStatementText(for: draft, dialect: appState.dataTaskDialect) {
                        Text(sql)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(L(.dataTaskSaveBlocked))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if let assessment = DataTaskRunner.guardAssessment(
                        for: draft,
                        policy: appState.agentGuardPolicy,
                        databaseType: appState.selectedConnection?.dbType ?? .postgresql
                    ) {
                        Label(
                            L(.dataTaskGuardVerdict) + "：" + assessment.message,
                            systemImage: assessment.verdict.isAllowed ? "checkmark.shield" : "exclamationmark.shield.fill"
                        )
                        .font(.caption2)
                        .foregroundStyle(assessment.verdict.isAllowed ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// 保存条件：定义合法 **且** 针对当前这份定义试运行过。
    private var canSave: Bool {
        guard let draft else { return false }
        return draft.isValid && dryRun != nil
    }

    // MARK: - 调度状态与执行（FR-AI-06）

    private var runtimeSection: some View {
        section(L(.dataTaskSectionRuntime)) {
            if let draft {
                let decision = appState.dataTaskDecision(for: draft)
                let status = DataTaskPresentation.status(for: decision)

                HStack(spacing: 8) {
                    Label(status.text, systemImage: status.symbolName)
                        .font(.caption)
                        .foregroundStyle(status.tint)

                    if let planned = DataTaskPresentation.plannedAt(decision) {
                        Text(L(.dataTaskPlannedAt, AgentAuditPresentation.timestampText(planned)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let next = DataTaskPresentation.nextRunText(
                        for: draft,
                        lastRun: appState.dataTaskLastSuccessfulRun(for: draft.id)
                    ) {
                        Text(L(.dataTaskNextRun, next))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                // 错过窗口默认不自动补跑：只给可读提示，由用户决定。
                if status == .missed, let minutes = DataTaskPresentation.overdueMinutes(decision) {
                    warningLabel(L(.dataTaskMissedNotice, minutes))
                }
                if !draft.isEnabled, appState.dataTasks.first(where: { $0.id == draft.id }) != nil {
                    Text(L(.dataTaskDisabledHint))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Button(L(.dataTaskRunNow)) {
                        Task { await appState.runDataTaskNow(draft, plannedAt: DataTaskPresentation.plannedAt(decision)) }
                    }
                    .font(.caption)
                    // 没保存过的任务没有执行历史可归属，先保存再执行。
                    .disabled(appState.dataTasks.first { $0.id == draft.id } == nil)

                    if let stored = appState.dataTasks.first(where: { $0.id == draft.id }) {
                        Button(stored.isEnabled ? L(.dataTaskDisable) : L(.dataTaskEnable)) {
                            Task { await toggleEnabled(stored) }
                        }
                        .font(.caption)
                    }
                    Spacer()
                }
            }
        }
    }

    private var historySection: some View {
        let records = (draft.map { task in appState.dataTaskRuns.filter { $0.taskID == task.id } } ?? []).reversed()

        return section(L(.dataTaskSectionHistory), hint: L(.dataTaskHistoryCount, records.count)) {
            if records.isEmpty {
                Text(L(.dataTaskHistoryEmpty))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(L(.dataTaskHistoryColumnTime)).frame(width: 150, alignment: .leading)
                        Text(L(.dataTaskHistoryColumnStatus)).frame(width: 90, alignment: .leading)
                        Text(L(.dataTaskHistoryColumnRows)).frame(width: 60, alignment: .leading)
                        Text(L(.dataTaskHistoryColumnDuration)).frame(width: 90, alignment: .leading)
                        Text(L(.dataTaskHistoryColumnMessage)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                    ForEach(records) { record in
                        historyRow(record)
                    }
                }
            }
        }
    }

    private func historyRow(_ record: TaskRunRecord) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(AgentAuditPresentation.timestampText(record.startedAt))
                .frame(width: 150, alignment: .leading)
            Label(record.status.text, systemImage: record.status.symbolName)
                .foregroundStyle(record.status.tint)
                .frame(width: 90, alignment: .leading)
            Text(DataTaskPresentation.rowsText(record.rowsWritten))
                .frame(width: 60, alignment: .leading)
            Text(DataTaskPresentation.durationText(record.duration))
                .frame(width: 90, alignment: .leading)
            Text(record.message ?? "—")
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption2)
    }

    // MARK: - 行为

    private func createNewTask() {
        let task = DataTaskDefinition(
            name: L(.dataTaskNew),
            specs: "",
            source: .init(table: ""),
            target: .init(table: "")
        )
        loadDraft(task)
        selectedID = nil
    }

    private func loadDraft(_ task: DataTaskDefinition) {
        draft = task
        selectedID = task.id
        dryRun = nil
        sourceColumnsText = task.source.columns.joined(separator: ", ")
        keyColumnsText = task.target.keyColumns.joined(separator: ", ")
        runAtText = DataTaskPresentation.dateText(task.schedule.runAt)
        startAtText = DataTaskPresentation.dateText(task.schedule.startAt)
        intervalText = task.schedule.intervalSeconds.map { String(Int($0)) } ?? ""
    }

    /// 放弃改动：回到已保存的版本（未保存过的新任务则清空选择）。
    private func revertDraft() {
        guard let draft else { return }
        if let stored = appState.dataTasks.first(where: { $0.id == draft.id }) {
            loadDraft(stored)
        } else {
            self.draft = nil
            selectedID = nil
            dryRun = nil
        }
    }

    private func runDryRun() {
        guard let draft else { return }
        dryRun = draft.dryRun(dialect: appState.dataTaskDialect)
        appState.dataTaskError = nil
    }

    private func save() {
        guard let draft, canSave else { return }
        Task {
            if await appState.saveDataTask(draft) {
                await appState.loadDataTasks()
                if let stored = appState.dataTasks.first(where: { $0.id == draft.id }) {
                    loadDraft(stored)
                }
            }
        }
    }

    private func deleteSelected() {
        guard let draft else { return }
        Task {
            if await appState.deleteDataTask(id: draft.id) {
                self.draft = nil
                selectedID = nil
                dryRun = nil
            }
        }
    }

    private func chooseDirectory() {
        guard let draft else { return }
        Task {
            let settings = await appState.chooseDataTaskExportDirectory(
                displayName: draft.name,
                format: self.draft?.output?.format ?? .csv,
                fileNameTemplate: self.draft?.output?.fileNameTemplate
            )
            guard let settings else { return } // 用户取消：不是错误
            self.draft?.output = settings
        }
    }

    private func useStoredBookmark(_ bookmark: DirectoryBookmark) {
        guard let draft = self.draft else { return }
        self.draft?.output = appState.dataTaskExportSettings(
            using: bookmark,
            format: draft.output?.format ?? .csv,
            fileNameTemplate: draft.output?.fileNameTemplate
        )
    }

    private func verifyDirectory() {
        guard let draft else { return }
        Task { await appState.verifyDataTaskExportDirectory(draft) }
    }

    /// 停用 / 恢复：写盘后把编辑器里的副本也同步过去，免得界面显示的还是旧开关。
    private func toggleEnabled(_ stored: DataTaskDefinition) async {
        let target = !stored.isEnabled
        await appState.setDataTaskEnabled(target, id: stored.id)
        if var current = draft, current.id == stored.id, current.isEnabled != target {
            current.isEnabled = target
            draft = current
        }
    }

    // MARK: - 小部件

    private func section<Content: View>(
        _ title: String,
        hint: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let hint {
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content()
        }
    }

    private func labeledField(_ title: String, text: Binding<String>, hint: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .leading)
                TextField("", text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }
            if let hint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 128)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func warningLabel(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption2)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 可空字符串字段的绑定：空串写回 `nil`（保持「没填」与「填了空」是同一件事）。
    private func nullableBinding(
        _ keyPath: WritableKeyPath<DataTaskDefinition, String?>
    ) -> Binding<String> {
        Binding(
            get: { draft?[keyPath: keyPath] ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                draft?[keyPath: keyPath] = trimmed.isEmpty ? nil : newValue
            }
        )
    }

    private func binding<T>(_ keyPath: WritableKeyPath<DataTaskDefinition, T>, default defaultValue: T) -> Binding<T> {
        Binding(
            get: { draft?[keyPath: keyPath] ?? defaultValue },
            set: { draft?[keyPath: keyPath] = $0 }
        )
    }

    private func transformationBinding<T>(
        _ index: Int,
        _ keyPath: WritableKeyPath<DataTaskDefinition.Transformation, T>,
        default defaultValue: T
    ) -> Binding<T> {
        Binding(
            get: {
                guard let transformations = draft?.transformations, transformations.indices.contains(index) else {
                    return defaultValue
                }
                return transformations[index][keyPath: keyPath]
            },
            set: { newValue in
                guard let draft, draft.transformations.indices.contains(index) else { return }
                self.draft?.transformations[index][keyPath: keyPath] = newValue
            }
        )
    }

    /// 转换步骤里可空字段的绑定（空串写回 `nil`）。
    private func optionalTransformationBinding(
        _ index: Int,
        _ keyPath: WritableKeyPath<DataTaskDefinition.Transformation, String?>
    ) -> Binding<String> {
        Binding(
            get: {
                guard let transformations = draft?.transformations, transformations.indices.contains(index) else {
                    return ""
                }
                return transformations[index][keyPath: keyPath] ?? ""
            },
            set: { newValue in
                guard let draft, draft.transformations.indices.contains(index) else { return }
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                self.draft?.transformations[index][keyPath: keyPath] = trimmed.isEmpty ? nil : newValue
            }
        )
    }

    /// 逗号 / 换行分隔的列表文本 → 数组（空项丢掉）。
    static func parseList(_ text: String) -> [String] {
        text
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
