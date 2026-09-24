import DoyahCore
import SwiftUI

/// 一列被**多条外键**引用时，让用户挑一个跳转目标（FR-DATA-06）。
///
/// 为什么不让程序自己挑：同一列被两条外键引用是合法的（例如 `orders.customer_id`
/// 同时引用 `customers` 与 `archived_customers`）。按字母序或按第一条挑，
/// 都会在用户完全不知情的情况下跳到另一个库里的另一张表 —— 那不是"聪明"，是错。
struct ForeignKeyJumpSheet: View {

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let request: ForeignKeyJumpRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            options
            Divider()
            footer
        }
        .frame(width: 480)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(L(.fkJumpTitle))
                .font(Theme.font(.title))
            Text(L(.fkJumpSource, request.source.qualifiedName, request.column, request.value))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(L(.fkJumpPickTarget))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))
            ForEach(Array(request.options.enumerated()), id: \.offset) { _, option in
                Button {
                    Task {
                        await appState.performForeignKeyJump(request, option: option)
                        dismiss()
                    }
                } label: {
                    HStack {
                        Text(label(for: option))
                            .font(Theme.font(.body))
                        Spacer()
                        if let constraint = option.constraintName {
                            Text(constraint)
                                .font(Theme.font(.caption))
                                .foregroundStyle(Theme.text(.tertiary))
                        }
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(Spacing.l)
    }

    /// 目标描述在界面层拼（Core 的 `Option.title` 是中文，英文界面下不能用）。
    private func label(for option: ForeignKeyNavigation.Option) -> String {
        let target = option.targetSchema.map { "\($0).\(option.targetTable)" } ?? option.targetTable
        return "\(target)（\(option.targetColumn)）"
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(L(.commonCancel)) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(Spacing.l)
    }
}
