import SwiftUI
import DoyahCore

/// 任务定义的**版本历史 / 字段级 diff / 回滚**（FR-AI-11 的界面入口）。
///
/// 三条口径来自 Core，界面不重新发明一套：
/// 1. **历史只追加**：回滚是把旧内容作为**新版本**再记一次（`DataTaskStore.save` →
///    `SpecVersionStore.record`），所以这里**没有**「删除版本」这种按钮 ——
///    那会与"历史不可改写"直接冲突；
/// 2. **"是否与当前定义相同"用 `SpecDiff.changes` 判空**，与 Core 的
///    「内容比较」同一口径（`updatedAt` 变了不算改动）；
/// 3. **回滚先确认**，再走 `AppState.rollbackDataTask`（保存的唯一收口点），
///    于是界面回滚与 CLI `specs --rollback` 落的是同一份历史。
struct DataTaskVersionSheet: View {
    /// 要看历史的任务（未保存的新任务没有历史，父面板会禁用入口）。
    let taskID: UUID
    /// 编辑器里的当前定义（`nil` = 还没保存过）。
    let currentDefinition: DataTaskDefinition?
    /// 回滚成功后把落盘后的定义交回父面板（编辑器切成被回滚的那版）。
    var onRollback: (DataTaskDefinition) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    @State private var versions: [SpecVersion] = []
    @State private var leftNumber: Int?
    @State private var rightNumber: Int?
    @State private var pendingRollback: SpecVersion?
    @State private var isRollingBack = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .firstTextBaseline) {
                Text(L(.dataTaskVersionsTitle))
                    .font(Theme.font(.title))
                Spacer()
                Button(L(.commonClose)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Text(L(.dataTaskVersionsHint))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 620, alignment: .leading)

            if let error = appState.dataTaskError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.status(.warning))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HairlineView()

            if versions.isEmpty {
                Text(L(.dataTaskVersionsEmpty))
                    .font(Theme.font(.body))
                    .foregroundStyle(Theme.text(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                compareSection
                HairlineView()
                listSection
            }
        }
        .padding(Spacing.l)
        .frame(width: 760, height: 640, alignment: .leading)
        .task { await load() }
        .alert(
            L(.dataTaskVersionsRollbackConfirmTitle),
            isPresented: Binding(
                get: { pendingRollback != nil },
                set: { if !$0 { pendingRollback = nil } }
            ),
            presenting: pendingRollback
        ) { version in
            Button(L(.commonCancel), role: .cancel) { pendingRollback = nil }
            Button(L(.dataTaskVersionsRollback), role: .destructive) { rollback(version) }
        } message: { version in
            Text(L(.dataTaskVersionsRollbackConfirmMessage, version.number))
        }
    }

    // MARK: - 两个版本对比

    private var compareSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(L(.dataTaskVersionsCompareTitle))
                .font(Theme.font(.bodyStrong))

            HStack(spacing: Spacing.m) {
                picker(L(.dataTaskVersionsCompareLeft), selection: $leftNumber)
                picker(L(.dataTaskVersionsCompareRight), selection: $rightNumber)
                Spacer()
                if leftNumber != nil, rightNumber != nil {
                    Text(changes.isEmpty
                        ? L(.dataTaskVersionsDiffEmpty)
                        : L(.dataTaskVersionsDiffCount, changes.count))
                        .font(Theme.font(.caption))
                        .foregroundStyle(Theme.text(.secondary))
                }
            }

            Text(L(.dataTaskVersionsDiffTitle))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))

            if leftNumber == nil || rightNumber == nil {
                Text(L(.dataTaskVersionsDiffNoSelection))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.tertiary))
            } else if changes.isEmpty {
                Text(L(.dataTaskVersionsDiffEmpty))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.secondary))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.hair) {
                        ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                            VStack(alignment: .leading, spacing: Spacing.hair) {
                                Text(change.field)
                                    .font(Theme.font(.caption))
                                    .foregroundStyle(Theme.text(.secondary))
                                Text(change.before)
                                    .font(Theme.font(.monoSmall))
                                    .foregroundStyle(Theme.status(.danger))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(change.after)
                                    .font(Theme.font(.monoSmall))
                                    .foregroundStyle(Theme.status(.success))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 150)
                .padding(Spacing.s)
                .background(Theme.surface(Surface.panel))
                .clipShape(RoundedRectangle(cornerRadius: Radius.control))
            }
        }
    }

    private func picker(_ title: String, selection: Binding<Int?>) -> some View {
        HStack(spacing: Spacing.xs) {
            Text(title)
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))
            Picker("", selection: selection) {
                ForEach(versions, id: \.number) { version in
                    Text("v\(version.number)").tag(Optional(version.number))
                }
            }
            .labelsHidden()
            .frame(width: 100)
        }
    }

    // MARK: - 版本列表

    private var listSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                Text(L(.dataTaskVersionsColumnNumber)).frame(width: 56, alignment: .leading)
                Text(L(.dataTaskVersionsColumnTime)).frame(width: 140, alignment: .leading)
                Text(L(.dataTaskVersionsColumnCurrent)).frame(width: 80, alignment: .leading)
                Text(L(.dataTaskVersionsColumnNote)).frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 130)
            }
            .font(Theme.font(.caption))
            .foregroundStyle(Theme.text(.tertiary))

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    ForEach(versions, id: \.number) { version in
                        row(version)
                    }
                }
            }
        }
    }

    private func row(_ version: SpecVersion) -> some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Text("v\(version.number)")
                .font(Theme.font(.data))
                .frame(width: 56, alignment: .leading)
            Text(AgentAuditPresentation.timestampText(version.savedAt))
                .font(Theme.font(.caption))
                .frame(width: 140, alignment: .leading)
            currentBadge(version)
                .frame(width: 80, alignment: .leading)
            Text(version.note ?? version.definition.name)
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(L(.dataTaskVersionsRollback)) { pendingRollback = version }
                .font(Theme.font(.caption))
                .disabled(isRollingBack)
        }
        .padding(Spacing.s)
        .background(Theme.surface(Surface.raised))
        .clipShape(RoundedRectangle(cornerRadius: Radius.control))
    }

    /// 与当前定义是否相同（`nil` = 当前任务还没保存过，无从比较）。
    @ViewBuilder
    private func currentBadge(_ version: SpecVersion) -> some View {
        if let same = isSameAsCurrent(version) {
            Label(
                same ? L(.dataTaskVersionsSameCurrent) : L(.dataTaskVersionsDifferentCurrent),
                systemImage: same ? "equal.circle" : "notequal.circle"
            )
            .font(Theme.font(.caption))
            .foregroundStyle(same ? Theme.text(.secondary) : Theme.status(.warning))
        } else {
            Text(L(.dataTaskVersionsUnknownCurrent))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.tertiary))
        }
    }

    // MARK: - 行为

    /// 两个选中版本之间的字段级差异（顺序稳定，Core 给的）。
    private var changes: [SpecChange] {
        guard let leftNumber, let rightNumber,
              let left = versions.first(where: { $0.number == leftNumber }),
              let right = versions.first(where: { $0.number == rightNumber })
        else { return [] }
        return SpecDiff.changes(between: left.definition, and: right.definition)
    }

    private func isSameAsCurrent(_ version: SpecVersion) -> Bool? {
        guard let currentDefinition else { return nil }
        return SpecDiff.changes(between: currentDefinition, and: version.definition).isEmpty
    }

    private func load() async {
        versions = await appState.dataTaskVersions(taskID: taskID)
        // 默认对比"最早 vs 最新"：改动最多的一对通常最想看。
        leftNumber = versions.first?.number
        rightNumber = versions.last?.number
    }

    private func rollback(_ version: SpecVersion) {
        isRollingBack = true
        Task {
            let stored = await appState.rollbackDataTask(taskID: taskID, to: version.number)
            // 回滚会记一条**新版本**，所以列表要重读（"曾经回滚过"也要看得见）。
            versions = await appState.dataTaskVersions(taskID: taskID)
            rightNumber = versions.last?.number
            if let stored { onRollback(stored) }
            pendingRollback = nil
            isRollingBack = false
        }
    }
}
