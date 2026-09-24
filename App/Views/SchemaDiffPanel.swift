import DoyahCore
import SwiftUI

/// 「Schema 对比与同步」面板（FR-DDL-04 的界面差异视图）。
///
/// 需求原文要的是「并排对比 + 勾选要应用的变更」。这一版给的是**能执行的最小闭环**：
/// 选两侧（连接 + 库 + schema）→ 抓快照 → 列出差异 → 生成同步脚本 →
/// **复制脚本或在新查询页签打开脚本**（不在面板里直接执行 —— 执行走编辑器与既有的
/// Safe Mode / 审批路径，这样"谁来执行、执行了什么"还是同一条动线，不额外开一条后门）。
///
/// 两处刻意不做"聪明"的事：
/// ① 删除**默认关闭**（`allowDrop`）：需求原文是"默认不动目标库多出来的表"；
/// ② 破坏性变更（改类型 / 删列）会在列表里单独标出来，不只写在脚本注释里。
struct SchemaDiffPanel: View {

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var sourceID: UUID?
    @State private var sourceDatabase = ""
    @State private var targetID: UUID?
    @State private var targetDatabase = ""
    @State private var schema = "public"
    @State private var allowsDrop = false
    @State private var plan: SchemaSyncPlan?
    @State private var errorMessage: String?
    @State private var isComparing = false
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            controls
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 760, height: 700)
        .onAppear { preselect() }
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(L(.schemaDiffTitle))
                .font(Theme.font(.title))
            Text(L(.schemaDiffHint))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
    }

    // MARK: 两侧选择

    private var controls: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .top, spacing: Spacing.l) {
                sidePicker(
                    title: .schemaDiffSource,
                    connectionID: $sourceID,
                    database: $sourceDatabase
                )
                sidePicker(
                    title: .schemaDiffTarget,
                    connectionID: $targetID,
                    database: $targetDatabase
                )
            }

            HStack(spacing: Spacing.m) {
                HStack(spacing: Spacing.xs) {
                    Text(L(.schemaDiffSchema))
                        .font(Theme.font(.caption))
                        .foregroundStyle(Theme.text(.secondary))
                    TextField("public", text: $schema)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                }

                Toggle(L(.schemaDiffAllowDrop), isOn: $allowsDrop)

                Spacer()
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
    }

    private func sidePicker(
        title: LKey,
        connectionID: Binding<UUID?>,
        database: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(L(title))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))

            Picker("", selection: connectionID) {
                ForEach(appState.connections) { connection in
                    Text(connection.name).tag(Optional(connection.id))
                }
            }
            .labelsHidden()

            TextField(L(.schemaDiffDatabase), text: database)
                .textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 结果

    @ViewBuilder
    private var content: some View {
        if isComparing {
            HStack(spacing: Spacing.s) {
                ProgressView()
                Text(L(.schemaDiffLoading))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.secondary))
            }
            .padding(Spacing.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        } else if let errorMessage {
            Text(errorMessage)
                .font(Theme.font(.body))
                .foregroundStyle(Theme.status(.danger))
                .fixedSize(horizontal: false, vertical: true)
                .padding(Spacing.l)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        } else if let plan {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    if plan.isIdentical {
                        Text(L(.schemaDiffIdentical))
                            .font(Theme.font(.body))
                            .foregroundStyle(Theme.status(.success))
                    } else {
                        diffSection(plan)
                    }
                    if !plan.skippedDestructive.isEmpty {
                        Text(L(.schemaDiffSkipped, plan.skippedDestructive.count))
                            .font(Theme.font(.caption))
                            .foregroundStyle(Theme.status(.warning))
                    }
                    scriptSection(plan)
                }
                .padding(Spacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

        } else {
            Text(L(.schemaDiffPickConnections))
                .font(Theme.font(.body))
                .foregroundStyle(Theme.text(.secondary))
                .padding(Spacing.l)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func diffSection(_ plan: SchemaSyncPlan) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            ForEach(plan.diffs, id: \.table.qualifiedName) { diff in
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack(spacing: Spacing.s) {
                        Text(diff.table.qualifiedName)
                            .font(Theme.font(.body))
                        Text(kindLabel(diff.kind))
                            .font(Theme.font(.caption))
                            .foregroundStyle(kindTone(diff.kind))
                    }
                    ForEach(Array(diff.columnChanges.enumerated()), id: \.offset) { _, change in
                        HStack(spacing: Spacing.xs) {
                            // 列级描述来自 Core（`SchemaDiffer.describe`）——
                            // 英文界面下这里仍是中文，与 R-45 属同一类残留，已登记。
                            Text(SchemaDiffer.describe(change))
                                .font(Theme.font(.caption))
                                .foregroundStyle(change.isDestructive ? Theme.status(.warning) : Theme.text(.secondary))
                        }
                    }
                }
            }
        }
    }

    private func kindLabel(_ kind: TableDiff.Kind) -> String {
        switch kind {
        case .missingInTarget: return L(.schemaDiffMissingInTarget)
        case .extraInTarget: return L(.schemaDiffExtraInTarget)
        case .changed: return L(.schemaDiffChanged)
        }
    }

    private func kindTone(_ kind: TableDiff.Kind) -> Color {
        switch kind {
        case .missingInTarget: return Theme.status(.success)
        case .extraInTarget: return Theme.text(.tertiary)
        case .changed: return Theme.status(.warning)
        }
    }

    private func scriptSection(_ plan: SchemaSyncPlan) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(plan.statements.isEmpty ? L(.schemaDiffNoStatements) : L(.schemaDiffStatements, plan.statements.count))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))

            if !plan.statements.isEmpty {
                ScrollView {
                    Text(plan.statements.joined(separator: ";\n") + ";")
                        .font(Theme.font(.data))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.s)
                }
                .frame(height: 160)
                .background(Theme.surface(.panel))
                .clipShape(RoundedRectangle(cornerRadius: Radius.card))

                HStack(spacing: Spacing.s) {
                    Button(didCopy ? L(.schemaDiffCopied) : L(.schemaDiffCopy)) {
                        copyScript(plan)
                    }
                    Button(L(.schemaDiffOpenInTab)) {
                        appState.openSQLInNewTab(plan.statements.joined(separator: ";\n") + ";")
                        dismiss()
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: 底部

    private var footer: some View {
        HStack {
            Spacer()
            Button(L(.commonClose)) {
                dismiss()
            }
            Button(L(.schemaDiffCompare)) {
                Task { await compare() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isComparing || sourceID == nil || targetID == nil)
        }
        .padding(Spacing.l)
    }

    // MARK: 行为

    private func preselect() {
        guard sourceID == nil else { return }
        let fallback = appState.selectedConnection ?? appState.connections.first
        sourceID = fallback?.id
        sourceDatabase = fallback?.database ?? ""
        // 默认两侧同一连接、同一个库 —— 用户只需改"目标库"就能对比两个库。
        targetID = fallback?.id
        targetDatabase = fallback?.database ?? ""
    }

    private func compare() async {
        guard let sourceID, let targetID else {
            errorMessage = L(.schemaDiffPickConnections)
            return
        }
        isComparing = true
        errorMessage = nil
        didCopy = false
        do {
            plan = try await appState.schemaDiffPlan(
                sourceConnectionID: sourceID,
                sourceDatabase: sourceDatabase,
                targetConnectionID: targetID,
                targetDatabase: targetDatabase,
                schema: schema.trimmingCharacters(in: .whitespacesAndNewlines),
                allowsDrop: allowsDrop
            )
        } catch {
            plan = nil
            errorMessage = L(.schemaDiffFailed, error.localizedDescription)
        }
        isComparing = false
    }

    private func copyScript(_ plan: SchemaSyncPlan) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(plan.statements.joined(separator: ";\n") + ";", forType: .string)
        didCopy = true
    }
}
