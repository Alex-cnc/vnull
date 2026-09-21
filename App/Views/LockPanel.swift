import SwiftUI
import PostgresClientCore

/// 「锁与阻塞…」面板（FR-DIAG-05）。
///
/// 列出**未获得**的锁及其阻塞者：被阻塞 pid、阻塞者 pid、锁类型 / 模式、对象、
/// 已等待时长，并给出「汇总」行。选中某个被阻塞会话后可「定位阻塞者」，
/// 在面板内直接跳到对应的阻塞行（跳进完整会话列表要等会话面板 T-30）。
struct LockPanel: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    @State private var waits: [LockWait] = []
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var hasLoaded = false
    /// 「定位阻塞者」高亮的 pid。
    @State private var highlightedPid: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(L(.lockTitle))
                    .font(.headline)

                if isLoading {
                    ProgressView().controlSize(.small)
                }

                Spacer()

                Button(L(.lockRefresh)) {
                    Task { await load() }
                }
                .disabled(isLoading)

                Button(L(.commonClose)) { dismiss() }
            }

            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }

            // 权限说明常驻：无权限时至少让人知道「看到的信息为什么不全」。
            Text(L(.lockPermissionHint))
                .font(.caption2)
                .foregroundStyle(.secondary)

            if waits.isEmpty {
                Text(hasLoaded ? L(.lockEmpty) : " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                summarySection
                tableSection
            }
        }
        .padding(20)
        .frame(width: 760, height: 560)
        .task { await load() }
    }

    // MARK: - 汇总

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(LockMonitor.summaryLines(for: waits).prefix(3).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - 列表

    private var tableSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(waits) { wait in
                    row(wait)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ wait: LockWait) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("\(L(.lockColumnPid)) \(wait.pid)")
                    .font(.caption)
                    .fontWeight(.semibold)

                Text("→ \(L(.lockColumnBlockedBy)) \(blockersText(wait))")
                    .font(.caption)
                    .foregroundStyle(wait.isBlocked ? .orange : .secondary)

                if let seconds = wait.waitingSeconds {
                    Text("· \(L(.lockColumnWaiting)) \(seconds)s")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text(wait.granted ? "· \(L(.lockGranted))" : "· \(L(.lockWaitingState))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer()

                if let blocker = wait.blockingPids.first, blocker != wait.pid {
                    Button(L(.lockShowBlocker)) {
                        highlightedPid = blocker
                    }
                    .controlSize(.small)
                }
            }

            Text(detailText(wait))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .padding(6)
        .background(
            highlightedPid == wait.pid
                ? Color.accentColor.opacity(0.15)
                : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func blockersText(_ wait: LockWait) -> String {
        wait.blockingPids.isEmpty ? "—" : wait.blockingPids.map(String.init).joined(separator: ", ")
    }

    private func detailText(_ wait: LockWait) -> String {
        var parts: [String] = []
        if let database = wait.database { parts.append("\(L(.lockColumnDatabase)) \(database)") }
        if let user = wait.user { parts.append("\(L(.lockColumnUser)) \(user)") }

        let lock = [wait.lockType, wait.mode, wait.relation]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        if !lock.isEmpty { parts.append(lock) }

        if let query = wait.query, !query.isEmpty {
            parts.append(query.replacingOccurrences(of: "\n", with: " "))
        }
        return parts.joined(separator: " | ")
    }

    // MARK: - 加载

    private func load() async {
        isLoading = true
        errorText = nil
        defer { isLoading = false }

        do {
            waits = try await appState.loadLockWaits()
            hasLoaded = true
            if let highlightedPid, !waits.contains(where: { $0.pid == highlightedPid }) {
                self.highlightedPid = nil
            }
        } catch {
            waits = []
            hasLoaded = true
            errorText = ErrorPresenter.message(for: error)
        }
    }
}
