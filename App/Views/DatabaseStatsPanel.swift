import DoyahCore
import SwiftUI

/// 「数据库统计」面板（FR-DIAG-04）：表大小 / 索引命中 / 连接数 / 缓存命中四类指标。
///
/// 两条刻意的口径，与 Core 的解析保持一致：
/// ① **比率没有数据时显示「无扫描数据」，不显示 0%** —— 刚建的库显示 0% 会让人
///    以为"索引完全没被用上"，那是误导；
/// ② **方言不支持时直说**（GBase），而不是摆四个空表格让人以为是"库是空的"。
struct DatabaseStatsPanel: View {

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var report: DatabaseStats.Report?
    @State private var errorMessage: String?
    @State private var isLoading = false

    private let limit = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 660, height: 640)
        .task { await load() }
    }

    // MARK: 头部

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(L(.databaseStatsTitle))
                    .font(Theme.font(.title))
                if let connection = appState.selectedConnection {
                    Text(connection.endpointDescription)
                        .font(Theme.font(.caption))
                        .foregroundStyle(Theme.text(.secondary))
                }
            }
            Spacer()
            Button(L(.databaseStatsRefresh)) {
                Task { await load() }
            }
            .disabled(isLoading)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if isLoading, report == nil {
            VStack(alignment: .leading, spacing: Spacing.s) {
                ProgressView()
                Text(L(.databaseStatsLoading))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.secondary))
            }
            .padding(Spacing.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        } else if let errorMessage {
            Text(errorMessage)
                .font(Theme.font(.body))
                .foregroundStyle(Theme.status(.warning))
                .fixedSize(horizontal: false, vertical: true)
                .padding(Spacing.l)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        } else if let report {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    tableSizesSection(report.tableSizes)
                    Divider()
                    scansSection(report.tableScans)
                    Divider()
                    connectionsSection(report.connections)
                    Divider()
                    cacheSection(report.cacheHit)
                }
                .padding(Spacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

        } else {
            Text(L(.databaseStatsEmpty))
                .font(Theme.font(.body))
                .foregroundStyle(Theme.text(.secondary))
                .padding(Spacing.l)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func sectionHeader(_ key: LKey) -> some View {
        Text(L(key))
            .font(Theme.font(.caption))
            .foregroundStyle(Theme.text(.secondary))
    }

    @ViewBuilder
    private func tableSizesSection(_ sizes: [DatabaseStats.TableSize]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            sectionHeader(.databaseStatsTableSizes)
            if sizes.isEmpty {
                emptyLine
            } else {
                ForEach(sizes, id: \.name) { size in
                    HStack {
                        Text(size.name)
                            .font(Theme.font(.body))
                        Spacer()
                        Text(size.displaySize)
                            .font(Theme.font(.data))
                            .foregroundStyle(Theme.text(.secondary))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func scansSection(_ scans: [DatabaseStats.TableScans]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            sectionHeader(.databaseStatsIndexHit)
            if scans.isEmpty {
                emptyLine
            } else {
                ForEach(scans, id: \.name) { scan in
                    HStack {
                        Text(scan.name)
                            .font(Theme.font(.body))
                        Spacer()
                        // 比率用 Core 的 `indexHitRatio` 判定"有没有数据"，
                        // 但文案在界面层出（Core 不管本地化）。
                        Text(
                            scan.indexHitRatio == nil
                                ? L(.databaseStatsNoScans)
                                : String(format: "%.1f%%", (scan.indexHitRatio ?? 0) * 100)
                        )
                        .font(Theme.font(.data))
                        .foregroundStyle(Theme.text(.secondary))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func connectionsSection(_ summary: DatabaseStats.ConnectionSummary) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            sectionHeader(.databaseStatsConnections)
            if summary.byState.isEmpty {
                emptyLine
            } else {
                ForEach(summary.ordered, id: \.state) { entry in
                    HStack {
                        Text(entry.state)
                            .font(Theme.font(.body))
                        Spacer()
                        Text("\(entry.count)")
                            .font(Theme.font(.data))
                            .foregroundStyle(Theme.text(.secondary))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cacheSection(_ cache: DatabaseStats.CacheHit?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            sectionHeader(.databaseStatsCacheHit)
            if let cache {
                HStack {
                    Text(L(.databaseStatsCacheDetail, cache.hits, cache.reads))
                        .font(Theme.font(.body))
                    Spacer()
                    Text(cache.ratio == nil ? L(.databaseStatsNoScans) : String(format: "%.1f%%", (cache.ratio ?? 0) * 100))
                        .font(Theme.font(.data))
                        .foregroundStyle(Theme.text(.secondary))
                }
            } else {
                emptyLine
            }
        }
    }

    private var emptyLine: some View {
        Text(L(.databaseStatsEmptySection))
            .font(Theme.font(.caption))
            .foregroundStyle(Theme.text(.tertiary))
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

    // MARK: 采集

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let fresh = try await appState.databaseStats(limit: limit)
            report = fresh
            // 四类全空 = 方言不支持（AppState 那边会先抛，这里是双保险）。
            if !fresh.isSupported {
                errorMessage = L(.databaseStatsUnsupported, appState.selectedConnection?.dbType.displayName ?? "")
            }
        } catch {
            errorMessage = L(.databaseStatsFailure, error.localizedDescription)
        }
        isLoading = false
    }
}
