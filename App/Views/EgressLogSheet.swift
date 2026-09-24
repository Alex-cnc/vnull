import SwiftUI
import DoyahCore

/// 「外发日志…」面板（NFR-SEC-08）。
///
/// 一屏回答三个问题：
/// 1. **数据出去过没有**：每条记录给出时间 / 类别 / 目标 / 触发来源 / 结果（`denied` 也在这张表里）；
/// 2. **「默认零外发」是不是真的**：没有任何出网时，这里显示的是空态而不是一张空表 —— 空态本身就是结论；
/// 3. **能不能交出去**：可导出 JSON / CSV（内容由 `EgressLog` 生成，导出前已脱敏），可清空（二次确认）。
///
/// 导出与脱敏**只有一处实现**：界面只负责选路径，不自己拼一份导出 —— 否则脱敏会变成君子协定。
///
/// 版式全部走设计令牌（`Theme` / `Spacing` / `Radius` / `HairlineView`）：
/// 系统语义色与裸间距会被令牌棘轮拦下，这里一开始就不给自己留债。
struct EgressLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    @State private var isClearConfirmPresented = false
    @State private var filter = EgressFilter()

    /// 应用筛选后的记录（新的在前）。
    private var visibleEntries: [EgressEntry] {
        filter.apply(to: appState.egressEntries)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            header
            HairlineView()
            content
            HairlineView()
            footer
        }
        .padding(Spacing.l)
        .frame(minWidth: 760, minHeight: 480)
        .task { await appState.refreshEgressLog() }
    }

    /// 日志里出现过的页签（最近出现的在前）——筛选项从**日志本身**派生，
    /// 而不是从"当前开着的页签"派生：关掉页签后那些记录仍然要能被筛出来。
    private var tabOptions: [(id: UUID, label: String)] {
        var seen: [UUID: String] = [:]
        var order: [UUID] = []
        for entry in appState.egressEntries {
            guard let tabID = entry.tabID else { continue }
            if seen[tabID] == nil {
                order.append(tabID)
                seen[tabID] = entry.tabTitle ?? String(tabID.uuidString.prefix(8))
            } else if seen[tabID]?.count ?? 0 < 12, let title = entry.tabTitle, !title.isEmpty {
                seen[tabID] = title
            }
        }
        return order.map { (id: $0, label: seen[$0] ?? String($0.uuidString.prefix(8))) }
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.s) {
                Text(L(.egressTitle))
                    .font(Theme.font(.title))
                    .foregroundStyle(Theme.text(.primary))
                Text(L(.egressCount, visibleEntries.count))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.tertiary))
                if filter.isActive {
                    Text(L(.egressFilterHint))
                        .font(Theme.font(.caption))
                        .foregroundStyle(Theme.text(.tertiary))
                }
                Spacer()

                // 按类别筛选：浏览器与智能体共用一份日志，能分开看才不会互相淹没。
                Picker("", selection: $filter.kind) {
                    Text(L(.egressFilterAll)).tag(EgressKind?.none)
                    ForEach(EgressKind.allCases, id: \.self) { kind in
                        Text(kindLabel(kind)).tag(EgressKind?.some(kind))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 160)

                Picker("", selection: $filter.outcome) {
                    Text(L(.egressFilterAll)).tag(EgressOutcome?.none)
                    Text(L(.egressOutcomeAllowed)).tag(EgressOutcome?.some(.allowed))
                    Text(L(.egressOutcomeDenied)).tag(EgressOutcome?.some(.denied))
                    Text(L(.egressOutcomeFailed)).tag(EgressOutcome?.some(.failed))
                }
                .labelsHidden()
                .frame(maxWidth: 140)

                // 按**浏览器页签**筛选（FR-EDIT-34）：一个窗口里开着多个页签时，
                // 光看"浏览器 · 页签"这句来源分不清是谁发的 —— 审计要能回答"这条是谁发起的"。
                Picker("", selection: $filter.tabID) {
                    Text(L(.egressFilterAllTabs)).tag(UUID?.none)
                    ForEach(tabOptions, id: \.id) { option in
                        Text(option.label).tag(UUID?.some(option.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 180)
                .disabled(tabOptions.isEmpty)
                Button(L(.egressExportJSON)) {
                    Task { await appState.exportEgressLog(asCSV: false) }
                }
                Button(L(.egressExportCSV)) {
                    Task { await appState.exportEgressLog(asCSV: true) }
                }
                Button(L(.egressClear)) { isClearConfirmPresented = true }
                    .disabled(appState.egressEntries.isEmpty)
            }
            Text(L(.egressSubtitle))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 主体

    @ViewBuilder
    private var content: some View {
        if visibleEntries.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                columnHeader
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleEntries) { entry in
                            entryRow(entry)
                            HairlineView()
                        }
                    }
                }
            }
        }
    }

    /// 空态就是结论本身：没有任何出网时，界面要明确说出这一点。
    private var emptyState: some View {
        VStack(spacing: Spacing.s) {
            Image(systemName: "checkmark.shield")
                .imageScale(.large)
                .foregroundStyle(Theme.status(.success))
            Text(L(.egressEmpty))
                .font(Theme.font(.body))
                .foregroundStyle(Theme.text(.secondary))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var columnHeader: some View {
        HStack(spacing: Spacing.s) {
            Text(L(.egressColumnTime))
                .frame(width: 150, alignment: .leading)
            Text(L(.egressColumnKind))
                .frame(width: 96, alignment: .leading)
            Text(L(.egressColumnTarget))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(L(.egressColumnOrigin))
                .frame(width: 190, alignment: .leading)
            Text(L(.egressColumnOutcome))
                .frame(width: 76, alignment: .leading)
        }
        .font(Theme.font(.caption))
        .foregroundStyle(Theme.text(.secondary))
    }

    private func entryRow(_ entry: EgressEntry) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.s) {
                Text(Self.timestampFormatter.string(from: entry.timestamp))
                    .font(Theme.font(.data))
                    .foregroundStyle(Theme.text(.secondary))
                    .frame(width: 150, alignment: .leading)
                Text(kindLabel(entry.kind))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.primary))
                    .frame(width: 96, alignment: .leading)
                Text(entry.target)
                    .font(Theme.font(.monoSmall))
                    .foregroundStyle(Theme.text(.primary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(entry.origin)
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.secondary))
                    .lineLimit(1)
                    .frame(width: 190, alignment: .leading)
                Text(outcomeLabel(entry.outcome))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.status(entry.outcome.tone))
                    .frame(width: 76, alignment: .leading)
            }
            if let detail = entry.detail, !detail.isEmpty {
                Text(detail)
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.tertiary))
                    .lineLimit(2)
                    .padding(.leading, Spacing.s)
            }
        }
        .padding(.vertical, Spacing.xs)
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: Spacing.s) {
            if let message = appState.egressMessage {
                Label(message, systemImage: "checkmark.circle")
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.status(.success))
            }
            if let error = appState.egressError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.status(.danger))
            }
            Spacer()
            Button(L(.commonClose)) { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .confirmationDialog(
            L(.egressClearConfirmTitle),
            isPresented: $isClearConfirmPresented
        ) {
            Button(L(.egressClear), role: .destructive) {
                Task { await appState.clearEgressLog() }
            }
            Button(L(.commonCancel), role: .cancel) {}
        } message: {
            Text(L(.egressClearConfirmMessage))
        }
    }

    // MARK: 文案映射

    private func kindLabel(_ kind: EgressKind) -> String {
        switch kind {
        case .agentModel: return L(.egressKindAgentModel)
        case .browser: return L(.egressKindBrowser)
        case .externalProgram: return L(.egressKindExternalProgram)
        case .updateCheck: return L(.egressKindUpdateCheck)
        }
    }

    private func outcomeLabel(_ outcome: EgressOutcome) -> String {
        switch outcome {
        case .allowed: return L(.egressOutcomeAllowed)
        case .denied: return L(.egressOutcomeDenied)
        case .failed: return L(.egressOutcomeFailed)
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()
}

private extension EgressOutcome {
    /// 结果色调：被拦下不是错误（是策略生效），失败才是问题 —— 三档区分开才看得懂日志。
    var tone: StatusTone {
        switch self {
        case .allowed: return .success
        case .denied: return .warning
        case .failed: return .danger
        }
    }
}
