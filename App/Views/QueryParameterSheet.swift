import SwiftUI
import DoyahCore

/// 查询参数填写面板（FR-EXEC-17）。
///
/// 触发方式是**执行时自动弹出**：SQL 里有 `:name` / `$1` 就先把值填了再执行 ——
/// 不在没填值的情况下跑（那会得到一句语法错误），也不给工具栏再加一个按钮。
///
/// 一个刻意的选择：**填完只执行、不改写编辑器**。占位符是可复用的模板，
/// 被一次取值覆盖掉就再也拿不回来了（想改成具体语句是另一件事，用户可以自己复制）。
struct QueryParameterSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var values: [String: String] = [:]
    @State private var types: [String: SQLParameters.ValueType] = [:]

    private var pending: AppState.PendingQueryParameters? { appState.pendingQueryParameters }

    private var missing: [String] {
        guard let pending else { return [] }
        return pending.parameters
            .filter { values[$0.identifier]?.isEmpty ?? true }
            .map(\.identifier)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(L(.queryParameterTitle)).font(Theme.font(.title))

            Text(L(.queryParameterHint))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))
                .fixedSize(horizontal: false, vertical: true)

            if let pending {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        ForEach(pending.parameters, id: \.identifier) { parameter in
                            row(parameter)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)

                Text(pending.sql)
                    .font(Theme.font(.monoSmall))
                    .foregroundStyle(Theme.text(.tertiary))
                    .lineLimit(3)
                    .textSelection(.enabled)
            } else {
                Text(L(.queryParameterEmpty))
                    .font(Theme.font(.body))
                    .foregroundStyle(Theme.text(.secondary))
            }

            if let error = appState.queryParameterError {
                Text(error)
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.status(.danger))
                    .fixedSize(horizontal: false, vertical: true)
            } else if !missing.isEmpty {
                Text(L(.queryParameterMissing) + "：" + missing.joined(separator: "、"))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.status(.warning))
            }

            HStack {
                Spacer()
                Button(L(.commonCancel)) {
                    appState.cancelPendingQueryParameters()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(L(.queryParameterRun)) {
                    Task {
                        await appState.runPendingQueryParameters(values: collected())
                        if appState.pendingQueryParameters == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(pending == nil || !missing.isEmpty)
            }
        }
        .padding(Spacing.l)
        .frame(width: 620)
        .onAppear {
            for parameter in pending?.parameters ?? [] {
                if values[parameter.identifier] == nil { values[parameter.identifier] = "" }
                if types[parameter.identifier] == nil { types[parameter.identifier] = .text }
            }
        }
    }

    private func row(_ parameter: SQLParameters.Parameter) -> some View {
        HStack(spacing: Spacing.s) {
            Text(parameter.identifier)
                .font(Theme.font(.monoSmall))
                .frame(width: 140, alignment: .leading)

            Picker("", selection: Binding(
                get: { types[parameter.identifier] ?? .text },
                set: { types[parameter.identifier] = $0 }
            )) {
                ForEach(SQLParameters.ValueType.allCases, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .labelsHidden()
            .frame(width: 110)

            TextField(L(.queryParameterValue), text: Binding(
                get: { values[parameter.identifier] ?? "" },
                set: { values[parameter.identifier] = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .font(Theme.font(.mono))
            // NULL 类型不需要值，禁用输入框把这一点表达出来。
            .disabled((types[parameter.identifier] ?? .text) == .null)
        }
    }

    /// 收集面板上的值。`null` 类型不要求填值。
    private func collected() -> [String: (type: SQLParameters.ValueType, raw: String)] {
        var result: [String: (type: SQLParameters.ValueType, raw: String)] = [:]
        for parameter in pending?.parameters ?? [] {
            let type = types[parameter.identifier] ?? .text
            result[parameter.identifier] = (type, values[parameter.identifier] ?? "")
        }
        return result
    }
}
