import SwiftUI
import DoyahCore

/// 合成数据面板（FR-AI-07）。
///
/// 三件事按"风险从低到高"排开，按钮也照这个顺序：
/// **生成预览**（纯计算）→ **导出 INSERT 到编辑器**（不执行）→ **写入目标表**（走审批闸门）。
/// 规格默认按表结构自动推断 —— 让用户对着十几列手写规则等于把功能藏起来。
struct SyntheticDataPanel: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let object: DatabaseObject

    @State private var spec: SyntheticTableSpec?
    @State private var rows: [[String?]] = []
    @State private var rowCountText = "100"
    @State private var seedText = "1"
    @State private var overwrite = false
    @State private var isLoading = false
    @State private var localError: String?

    private var rowCount: Int { Int(rowCountText.trimmingCharacters(in: .whitespaces)) ?? 100 }
    private var seed: UInt64 { UInt64(seedText.trimmingCharacters(in: .whitespaces)) ?? 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(L(.syntheticTitle, object.name)).font(Theme.font(.title))

            // 说清"规则从哪来"，否则用户会以为要自己填十几个生成器。
            Text(L(.syntheticAutoSpecNote))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.tertiary))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Spacing.m) {
                labelled(L(.syntheticRows)) {
                    TextField("", text: $rowCountText)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.font(.data))
                        .frame(width: 90)
                }
                labelled(L(.syntheticSeed)) {
                    TextField("", text: $seedText)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.font(.data))
                        .frame(width: 90)
                }
                Toggle(L(.syntheticOverwrite), isOn: $overwrite)
                    .font(Theme.font(.caption))
                Spacer()
                Button(L(.syntheticGenerate)) {
                    Task { await regenerate() }
                }
                .disabled(isLoading)
            }

            if let localError {
                Text(localError)
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.status(.danger))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = appState.syntheticDataMessage {
                Text(message)
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.status(.warning))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = appState.syntheticDataError {
                Text(error)
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.status(.danger))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(L(.syntheticColumns)).font(Theme.font(.bodyStrong))
            if let spec {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.hair) {
                        ForEach(Array(spec.columns.enumerated()), id: \.offset) { _, column in
                            HStack(spacing: Spacing.s) {
                                Text(column.name)
                                    .font(Theme.font(.monoSmall))
                                    .frame(width: 160, alignment: .leading)
                                Text(describe(column.generator))
                                    .font(Theme.font(.caption))
                                    .foregroundStyle(Theme.text(.secondary))
                                if column.isUnique {
                                    Text("UNIQUE").font(Theme.font(.caption)).foregroundStyle(Theme.text(.tertiary))
                                }
                                if column.nullProbability > 0 {
                                    Text("NULL \(Int(column.nullProbability * 100))%")
                                        .font(Theme.font(.caption))
                                        .foregroundStyle(Theme.text(.tertiary))
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 120)
            } else if isLoading {
                HStack(spacing: Spacing.s) {
                    ProgressView().controlSize(.small)
                    Text(L(.tableDesignLoading)).font(Theme.font(.body))
                }
            }

            Text(L(.syntheticPreview)).font(Theme.font(.bodyStrong))
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: Spacing.hair) {
                    if let spec {
                        Text(spec.columns.map(\.name).joined(separator: " | "))
                            .font(Theme.font(.monoSmall))
                            .foregroundStyle(Theme.text(.tertiary))
                    }
                    ForEach(Array(rows.prefix(10).enumerated()), id: \.offset) { _, row in
                        Text(row.map { $0 ?? "NULL" }.joined(separator: " | "))
                            .font(Theme.font(.monoSmall))
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.s)
            }
            .frame(height: 120)
            .background(RoundedRectangle(cornerRadius: Radius.control).fill(Theme.surface(.panel)))

            HStack {
                Spacer()
                Button(L(.commonClose)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L(.syntheticExport)) {
                    guard let spec else { return }
                    appState.exportSyntheticInsert(spec, rows: rows, overwrite: overwrite)
                }
                .disabled(rows.isEmpty || spec == nil)
                // 写入是**有副作用**的动作，放在最后且走审批 —— 位置本身就是提示。
                Button(L(.syntheticWrite)) {
                    Task {
                        guard let spec else { return }
                        await appState.writeSyntheticData(spec, rows: rows, overwrite: overwrite)
                    }
                }
                .disabled(rows.isEmpty || spec == nil)
            }
        }
        .padding(Spacing.l)
        .frame(width: 760, height: 620)
        .task { await regenerate() }
    }

    // MARK: 零件

    @ViewBuilder
    private func labelled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title).font(Theme.font(.caption)).foregroundStyle(Theme.text(.secondary))
            content()
        }
    }

    private func regenerate() async {
        isLoading = true
        localError = nil
        appState.syntheticDataMessage = nil
        appState.syntheticDataError = nil
        do {
            let built = try await appState.syntheticSpec(for: object, rowCount: rowCount, seed: seed)
            let generated = try appState.generateSyntheticRows(built)
            spec = built
            rows = generated
        } catch {
            spec = nil
            rows = []
            localError = L(.syntheticSpecIssue, ErrorPresenter.message(for: error))
        }
        isLoading = false
    }

    /// 生成规则的人话描述（Core 只给枚举，文案在界面层）。
    private func describe(_ generator: ColumnGenerator) -> String {
        switch generator {
        case .sequence(let start, let step): return "sequence(\(start), +\(step))"
        case .integer(let min, let max): return "integer(\(min)…\(max))"
        case .decimal(let min, let max, let precision): return "decimal(\(min)…\(max), \(precision) 位)"
        case .boolean(let probability): return "boolean(\(probability))"
        case .text(let min, let max): return "text(\(min)…\(max) 字符)"
        case .choice(let values): return "choice(\(values.joined(separator: "/")))"
        case .weightedChoice(let values): return "weighted(\(values.count) 项)"
        case .email: return "email"
        case .fullName: return "name"
        case .date(let days): return "date(近 \(days) 天)"
        case .timestamp(let days): return "timestamp(近 \(days) 天)"
        case .uuid: return "uuid"
        case .constant(let value): return "constant(\(value))"
        }
    }
}
