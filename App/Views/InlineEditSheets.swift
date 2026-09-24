import SwiftUI
import DoyahCore

/// 内联编辑的草稿持有者（FR-DATA-04）。
///
/// 为什么是 `ObservableObject` 而不是一个 `@State` 的值类型：**就地编辑结束与按钮动作之间
/// 有一次时序竞争**。用户在一格里打完字直接点「预览并执行…」时，AppKit 会先结束编辑
/// （`controlTextDidEndEditing` 把新值交给草稿），再触发按钮动作 —— 而按钮的闭包是**上一次
/// 渲染**时捕获的；如果草稿是值类型，那一刻读到的还是"没有这一格"的旧值，
/// 最后一处改动就会被静默漏掉。放进引用类型，按钮在动作发生时读到的就是最新草稿。
@MainActor
final class InlineEditDraftStore: ObservableObject {
    @Published var draft = InlineEditDraft()
}

/// 提交前预览：把**真正会执行**的那几条语句摊开给用户看（FR-DATA-04 的"确认后才写库"）。
///
/// 语句来自 `InlineEdit.plan`（与执行同一份），这里不重新拼一遍 ——
/// "预览的是 UPDATE、跑的是 DELETE"是这一项最坏的一种错。
struct InlineEditPreviewSheet: View {
    let plan: InlineEdit.Plan
    let onRun: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(L(.inlineEditPreviewTitle))
                .font(Theme.font(.title))

            Text(L(.inlineEditPreviewHint))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 620, alignment: .leading)

            HairlineView()

            if plan.refusals.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(L(.inlineEditStatementCount, plan.statements.count))
                            .font(Theme.font(.caption))
                            .foregroundStyle(Theme.text(.secondary))
                        ForEach(Array(plan.statements.enumerated()), id: \.offset) { _, statement in
                            Text(statement + ";")
                                .font(Theme.font(.mono))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(Spacing.s)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.card)
                            .fill(Theme.surface(Surface.panel))
                    )
                }
                .frame(maxHeight: 260)
            } else {
                // **拒绝理由要显示给人看**，不是静默禁用：没有主键的表就是走这条路的。
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(L(.inlineEditRefused))
                            .font(Theme.font(.bodyStrong))
                            .foregroundStyle(Theme.status(.warning))
                        ForEach(Array(plan.refusals.enumerated()), id: \.offset) { _, refusal in
                            Text("⚠️ " + refusal)
                                .font(Theme.font(.monoSmall))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(Spacing.s)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.card)
                            .fill(Theme.surface(Surface.panel))
                    )
                }
                .frame(maxHeight: 260)
            }

            HStack(spacing: Spacing.s) {
                Spacer()
                Button(L(.commonCancel)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L(.inlineEditCommit)) {
                    onRun()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                // 生成不出语句（被拒绝）时**执行按钮不可用**，但拒绝理由已经摊在上面了 ——
                // 禁用不是"静默"，用户看得见为什么。
                .disabled(!plan.isApplicable)
            }
        }
        .padding(Spacing.l)
        .frame(width: 700, alignment: .leading)
    }
}

/// 追加一行的输入面板（FR-DATA-04 的"加行"）。
///
/// 一行有多个字段，所以它必须有**一个能填多列的界面**（结果表里没有这种空间）——
/// 这也是"加行"没做成表格右键菜单一条命令的原因。
struct InlineEditInsertSheet: View {
    let columns: [ColumnMeta]
    let onAdd: ([String: InlineEdit.Value]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var inputs: [String: String] = [:]
    @State private var isEmptyRefused = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(L(.inlineEditInsertTitle))
                .font(Theme.font(.title))

            Text(L(.inlineEditInsertHint))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 520, alignment: .leading)

            HairlineView()

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    ForEach(columns) { column in
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                            Text(column.name)
                                .font(Theme.font(.bodyStrong))
                                .frame(width: 160, alignment: .leading)
                            TextField("", text: binding(for: column.name))
                                .font(Theme.font(.mono))
                            Text(column.typeName)
                                .font(Theme.font(.caption))
                                .foregroundStyle(Theme.text(.tertiary))
                                .frame(width: 120, alignment: .leading)
                        }
                    }
                }
            }
            .frame(maxHeight: 280)

            if isEmptyRefused {
                Text(L(.inlineEditInsertEmpty))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.status(.warning))
            }

            HStack(spacing: Spacing.s) {
                Spacer()
                Button(L(.commonCancel)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L(.inlineEditInsertConfirm)) { add() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.l)
        .frame(width: 620, alignment: .leading)
    }

    private func binding(for name: String) -> Binding<String> {
        Binding(
            get: { inputs[name] ?? "" },
            set: { inputs[name] = $0 }
        )
    }

    private func add() {
        var values: [String: InlineEdit.Value] = [:]
        for column in columns {
            guard let value = InlineEdit.Value.parsedForInsert(
                inputs[column.name] ?? "",
                typeName: column.typeName
            ) else { continue }
            values[column.name] = value
        }
        // 一列都没填就是一条空 INSERT（`INSERT INTO t () VALUES ()`），数据库必然报错 ——
        // 在这里就说清楚，而不是让它跑一趟换回一句没人看得懂的语法错。
        guard !values.isEmpty else {
            isEmptyRefused = true
            return
        }
        onAdd(values)
        dismiss()
    }
}
