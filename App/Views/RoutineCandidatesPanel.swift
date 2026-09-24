import SwiftUI
import DoyahCore

/// 「例行候选 / 记忆治理」面板（FR-AI-14 与 FR-AI-15 共用一个面板）。
///
/// 两块内容住在一起是**故意的**：它们看的是同一份事实源（查询归档派生的记忆层），
/// 拆成两个面板就会出现"候选里看到的指纹，在另一个面板里找不到"这类割裂。
///
/// FR-AI-14 这一半**只给建议**：列出"你反复在做什么"，但不会替你建任务、也不会自动执行 ——
/// 误判代价不对称（把排障脚本当例行去定时是危险的），所以决定权必须留在人这边；
/// 面板刻意把**未达标项**一起列出来（含"差在哪"的实际数字）：只给一个空列表，
/// 用户会以为"这功能没用"，而不是"我少跑了两次"。
///
/// FR-AI-15 这一半是**治理**：浏览 + 来源解释（`MemoryExplanation.describe`）、
/// 单条删除、整层清空（必须显式确认）、以及「本次执行不记录」
/// （`MemoryRecordingPolicy`）。**判定一律由 Core 的纯函数给出**，界面不重写判据 ——
/// 重写就会出现两份互相漂移的规则，而这里漂移的代价是"我说了不记，它还是记了"。
struct RoutineCandidatesPanel: View {
    /// 面板的两个页签。
    private enum Tab: Hashable {
        case candidates
        case memory
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    @State private var tab: Tab = .candidates
    /// 每条记忆选定的类别（键 = 粗指纹）。默认「例行」—— 与 CLI `memory --show` 的默认一致。
    @State private var kinds: [String: MemoryKind] = [:]
    /// 展开了解释的那条（一次只展开一条，否则面板会被理由文本淹掉）。
    @State private var explainedFingerprint: String?
    @State private var pendingDelete: QueryMemory.Memory?
    @State private var isClearConfirmPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .firstTextBaseline) {
                Text(L(.routineCandidatesTitle))
                    .font(Theme.font(.title))
                Spacer()
                Button(L(.commonClose)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Picker("", selection: $tab) {
                Text(L(.memoryGovernanceTabCandidates)).tag(Tab.candidates)
                Text(L(.memoryGovernanceTabMemory)).tag(Tab.memory)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)

            switch tab {
            case .candidates:
                candidatesTab
            case .memory:
                memoryTab
            }
        }
        .padding(Spacing.l)
        .frame(width: 700, alignment: .leading)
        .task { await appState.refreshRoutineCandidates() }
        .alert(
            L(.memoryGovernanceDeleteConfirmTitle),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { memory in
            Button(L(.commonCancel), role: .cancel) { pendingDelete = nil }
            Button(L(.commonDelete), role: .destructive) { deleteMemory(memory) }
        } message: { memory in
            Text(L(.memoryGovernanceDeleteConfirmMessage, memory.latestSQL))
        }
        .alert(L(.memoryGovernanceClearConfirmTitle), isPresented: $isClearConfirmPresented) {
            Button(L(.commonCancel), role: .cancel) {}
            Button(L(.commonDelete), role: .destructive) {
                Task { await appState.clearMemoryEnvironmentLayer() }
            }
        } message: {
            Text(L(.memoryGovernanceClearConfirmMessage, appState.queryMemoryIndex.parsedEntryCount))
        }
    }

    // MARK: - 例行候选（FR-AI-14）

    @ViewBuilder
    private var candidatesTab: some View {
        Text(L(.routineCandidatesHint))
            .font(Theme.font(.caption))
            .foregroundStyle(Theme.text(.secondary))
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 620, alignment: .leading)

        HairlineView()

        if let report = appState.routineReport, !report.candidates.isEmpty {
            candidatesList(report)
        } else {
            Text(L(.routineCandidatesEmpty))
                .font(Theme.font(.body))
                .foregroundStyle(Theme.text(.secondary))
                .fixedSize(horizontal: false, vertical: true)
        }

        if let report = appState.routineReport, !report.assessments.isEmpty {
            blockedList(report)
        }

        // 被否决的如实计数：用户"不再建议"过的，不该看起来像凭空消失了
        if let report = appState.routineReport, !report.vetoedFingerprints.isEmpty {
            Text("\(L(.routineCandidatesVetoed))：\(report.vetoedFingerprints.count)")
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.tertiary))
        }
    }

    @ViewBuilder
    private func candidatesList(_ report: RoutineCandidate.Report) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                ForEach(report.candidates, id: \.fingerprint) { candidate in
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(candidate.template)
                            .font(Theme.font(.mono))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text(statsLine(candidate))
                            .font(Theme.font(.caption))
                            .foregroundStyle(Theme.text(.secondary))

                        if !candidate.slotSamples.isEmpty {
                            Text(samplesLine(candidate))
                                .font(Theme.font(.caption))
                                .foregroundStyle(Theme.text(.tertiary))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        HStack(spacing: Spacing.s) {
                            Button(L(.routineCandidatesInsert)) {
                                appState.insertRoutineTemplate(candidate.template)
                            }
                            Button(L(.routineCandidatesVeto)) {
                                Task { await appState.vetoRoutineCandidate(fingerprint: candidate.fingerprint) }
                            }
                            .buttonStyle(.link)
                        }
                    }
                    .padding(Spacing.s)
                    .background(Theme.surface(.raised))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control))
                }
            }
        }
        .frame(maxHeight: 320)
    }

    /// 统计行：数字与单位都是语言中性的，不需要本地化键（硬塞一个键只会让文案更难改）。
    private func statsLine(_ candidate: RoutineCandidate.Candidate) -> String {
        "执行 \(candidate.runCount) 次 · \(candidate.dayCount) 天 · "
            + "集中 \(candidate.concentration.percent)%（\(candidate.concentration.startHour) 点起 "
            + "\(candidate.concentration.windowHours) 小时）· 变体 \(candidate.variantCount) 条 · "
            + candidate.connections.sorted().joined(separator: " / ")
    }

    private func samplesLine(_ candidate: RoutineCandidate.Candidate) -> String {
        candidate.slotSamples.enumerated()
            .map { "槽位 \($0.offset + 1)：\($0.element.joined(separator: " / "))" }
            .joined(separator: "　")
    }

    @ViewBuilder
    private func blockedList(_ report: RoutineCandidate.Report) -> some View {
        let blocked = report.assessments.filter { !$0.isCandidate }
        if !blocked.isEmpty {
            HairlineView()
            Text(L(.routineCandidatesBlockedTitle))
                .font(Theme.font(.bodyStrong))
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    ForEach(blocked, id: \.fingerprint) { assessment in
                        VStack(alignment: .leading, spacing: Spacing.hair) {
                            Text(assessment.fingerprint)
                                .font(Theme.font(.mono))
                                .foregroundStyle(Theme.text(.secondary))
                                .lineLimit(1)
                            Text(assessment.reasons.joined(separator: "；"))
                                .font(Theme.font(.caption))
                                .foregroundStyle(Theme.text(.tertiary))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
        }
    }

    // MARK: - 记忆治理（FR-AI-15）

    private var memories: [QueryMemory.Memory] { appState.queryMemoryIndex.memories }

    @ViewBuilder
    private var memoryTab: some View {
        Text(L(.memoryGovernanceHint))
            .font(Theme.font(.caption))
            .foregroundStyle(Theme.text(.secondary))
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 620, alignment: .leading)

        if !appState.isSQLArchiveEnabled {
            Label(L(.memoryGovernanceArchiveDisabled), systemImage: "exclamationmark.triangle")
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.status(.warning))
                .fixedSize(horizontal: false, vertical: true)
        }

        Text(L(.memoryGovernanceIndexNote, appState.queryMemoryIndex.parsedEntryCount, memories.count))
            .font(Theme.font(.caption))
            .foregroundStyle(Theme.text(.tertiary))

        recordingPolicyRow

        HairlineView()

        if let error = appState.memoryGovernanceError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.status(.danger))
                .fixedSize(horizontal: false, vertical: true)
        } else if let message = appState.memoryGovernanceMessage {
            Text(message)
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))
                .fixedSize(horizontal: false, vertical: true)
        }

        if memories.isEmpty {
            Text(L(.memoryGovernanceEmpty))
                .font(Theme.font(.body))
                .foregroundStyle(Theme.text(.secondary))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            memoryList
        }
    }

    /// 「本次执行不记录」：开关交给 `MemoryRecordingPolicy`，文案也来自它的结论。
    private var recordingPolicyRow: some View {
        let policy = appState.memoryRecordingPolicy
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(L(.memoryGovernanceRecordingTitle))
                .font(Theme.font(.bodyStrong))
            Toggle(
                L(.memoryGovernanceRecordingToggle),
                isOn: $appState.suppressesCurrentExecutionRecording
            )
            .font(Theme.font(.caption))
            Text(policy.shouldRecord
                ? L(.memoryGovernanceRecordingOff, policy.reason)
                : L(.memoryGovernanceRecordingOn, policy.reason))
                .font(Theme.font(.caption))
                .foregroundStyle(policy.shouldRecord ? Theme.text(.secondary) : Theme.status(.warning))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.s)
        .background(Theme.surface(Surface.panel))
        .clipShape(RoundedRectangle(cornerRadius: Radius.control))
    }

    @ViewBuilder
    private var memoryList: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                Text(L(.memoryGovernanceKindLabel))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.tertiary))
                Spacer()
                // 整层清空不可逆：按钮本身不执行，只负责弹确认（Core 的「清空需确认」纪律）。
                Button(L(.memoryGovernanceClearLayer)) { isClearConfirmPresented = true }
                    .font(Theme.font(.caption))
            }
            Text(L(.memoryGovernanceLayerNote))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.tertiary))
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    ForEach(memories, id: \.fingerprint) { memory in
                        memoryRow(memory)
                    }
                }
            }
        }
    }

    private func memoryRow(_ memory: QueryMemory.Memory) -> some View {
        let kind = kinds[memory.fingerprint] ?? .routine
        // 判定用 Core 的纯函数：闲置天数 / 执行次数都由它算，界面只是把结论显示出来。
        let verdict = RetentionPolicy.standard.evaluate(
            kind: kind,
            stats: MemoryStats(memory: memory),
            now: Date()
        )
        let isExplained = explainedFingerprint == memory.fingerprint

        return VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(memory.latestSQL.replacingOccurrences(of: "\n", with: " "))
                .font(Theme.font(.mono))
                .textSelection(.enabled)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(memoryStatsLine(memory))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))

            HStack(spacing: Spacing.s) {
                Picker("", selection: kindBinding(memory.fingerprint)) {
                    ForEach(MemoryKind.allCases, id: \.self) { candidate in
                        // 类别名来自 Core（与判定理由同一份来源），不在这里另写一套。
                        Text(candidate.label).tag(candidate)
                    }
                }
                .labelsHidden()
                .frame(width: 130)

                Label(
                    verdict.shouldForget
                        ? L(.memoryGovernanceRetentionForget)
                        : L(.memoryGovernanceRetentionKeep),
                    systemImage: verdict.shouldForget ? "clock.badge.exclamationmark" : "pin"
                )
                .font(Theme.font(.caption))
                .foregroundStyle(verdict.shouldForget ? Theme.status(.warning) : Theme.text(.secondary))

                Button(isExplained ? L(.commonClose) : L(.memoryGovernanceExplain)) {
                    explainedFingerprint = isExplained ? nil : memory.fingerprint
                }
                .font(Theme.font(.caption))

                Button(L(.memoryGovernanceDelete)) { pendingDelete = memory }
                    .font(Theme.font(.caption))
                Spacer()
            }

            if isExplained {
                // 逐行解释：来源 / 聚类依据 / 最近原文 / 为什么记了它（或为什么会被忘）。
                VStack(alignment: .leading, spacing: Spacing.hair) {
                    ForEach(
                        Array(
                            MemoryExplanation.describe(memory: memory, kind: kind, verdict: verdict).enumerated()
                        ),
                        id: \.offset
                    ) { _, line in
                        Text(line)
                            .font(Theme.font(.caption))
                            .foregroundStyle(Theme.text(.secondary))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Spacing.s)
                .background(Theme.surface(Surface.panel))
                .clipShape(RoundedRectangle(cornerRadius: Radius.control))
            }
        }
        .padding(Spacing.s)
        .background(Theme.surface(.raised))
        .clipShape(RoundedRectangle(cornerRadius: Radius.control))
    }

    /// 记忆的统计行（与候选列表同一套"数字语言中性的"处理）。
    private func memoryStatsLine(_ memory: QueryMemory.Memory) -> String {
        "执行 \(memory.runCount) 次 · \(memory.days.count) 天 · 变体 \(memory.variantCount) 条 · "
            + memory.connections.sorted().joined(separator: " / ")
    }

    private func kindBinding(_ fingerprint: String) -> Binding<MemoryKind> {
        Binding(
            get: { kinds[fingerprint] ?? .routine },
            set: { kinds[fingerprint] = $0 }
        )
    }

    private func deleteMemory(_ memory: QueryMemory.Memory) {
        pendingDelete = nil
        Task { await appState.deleteMemory(fingerprint: memory.fingerprint) }
    }
}
