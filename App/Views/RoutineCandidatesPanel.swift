import SwiftUI
import DoyahCore

/// 「例行候选」面板（FR-AI-14 的界面入口）。
///
/// 这一层**只给建议**：它列出"你反复在做什么"，但不会替你建任务、也不会自动执行 ——
/// 误判代价不对称（把排障脚本当例行去定时是危险的），所以决定权必须留在人这边。
///
/// 面板刻意把**未达标项**一起列出来（含"差在哪"的实际数字）：
/// 只给一个空列表，用户会以为"这功能没用"，而不是"我少跑了两次"。
struct RoutineCandidatesPanel: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .firstTextBaseline) {
                Text(L(.routineCandidatesTitle))
                    .font(Theme.font(.title))
                Spacer()
                Button(L(.commonClose)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

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
        .padding(Spacing.l)
        .frame(width: 700, alignment: .leading)
        .task { await appState.refreshRoutineCandidates() }
    }

    // MARK: - 候选

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

    // MARK: - 未达标

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
                        VStack(alignment: .leading, spacing: 2) {
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
}
