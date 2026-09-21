import SwiftUI
import PostgresClientCore

/// 「库属性…」表单（FR-SESS-05）。
///
/// 只收集改动并**实时预览**将要执行的语句；真正执行交给 `AppState.alterDatabase`。
/// 留空一律表示「不修改」—— 这样就不会因为漏填某个字段而生成半条语句；
/// 填了但非法（例如连接数不是整数）则明确报错并禁用执行，不静默当成「不修改」。
struct DatabasePropertiesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    let databaseName: String
    let onApply: (SQLGenerator.DatabaseAlterations) -> Void

    /// 「允许连接」三态：不修改 / 允许 / 禁止。
    private enum AllowChoice: Hashable {
        case unchanged
        case allow
        case deny
    }

    @State private var owner = ""
    @State private var connectionLimit = ""
    @State private var allowChoice: AllowChoice = .unchanged
    @State private var parameterName = ""
    @State private var parameterValue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L(.dbPropsTitle))
                .font(.headline)

            Text(databaseName)
                .font(.caption)
                .foregroundStyle(.secondary)

            Form {
                TextField(L(.dbPropsOwner), text: $owner)
                TextField(L(.dbPropsConnectionLimit), text: $connectionLimit)

                Picker(L(.dbPropsAllowConnections), selection: $allowChoice) {
                    Text(L(.dbPropsUnchanged)).tag(AllowChoice.unchanged)
                    Text(L(.dbPropsAllow)).tag(AllowChoice.allow)
                    Text(L(.dbPropsDeny)).tag(AllowChoice.deny)
                }

                TextField(L(.dbPropsParameterName), text: $parameterName)
                TextField(L(.dbPropsParameterValue), text: $parameterValue)
            }
            .formStyle(.columns)
            .frame(width: 420)

            previewSection

            HStack {
                Spacer()

                Button(L(.commonCancel)) {
                    dismiss()
                }

                Button(L(.dbPropsApply)) {
                    onApply(alterations)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(statements == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    // MARK: - 预览

    @ViewBuilder
    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L(.dbPropsPreview))
                .font(.caption)
                .foregroundStyle(.secondary)

            if let statements {
                Text(statements)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Label(hint, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// 无法生成语句时的可读原因。
    private var hint: String {
        if !supportsAlteration { return L(.dbPropsUnsupported) }
        if limitIsInvalid { return L(.dbPropsInvalid) }
        return L(.dbPropsEmpty)
    }

    // MARK: - 输入 → 改动

    private var supportsAlteration: Bool {
        appState.selectedConnection?.dbType == .postgresql
    }

    /// 连接数填了内容但不是整数：明确算非法，不当作「不修改」。
    private var limitIsInvalid: Bool {
        let trimmed = connectionLimit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return Int(trimmed) == nil
    }

    private var alterations: SQLGenerator.DatabaseAlterations {
        SQLGenerator.DatabaseAlterations(
            owner: trimmedOrNil(owner),
            connectionLimit: Int(connectionLimit.trimmingCharacters(in: .whitespacesAndNewlines)),
            allowConnections: {
                switch allowChoice {
                case .unchanged: return nil
                case .allow: return true
                case .deny: return false
                }
            }(),
            parameterName: trimmedOrNil(parameterName),
            parameterValue: trimmedOrNil(parameterValue)
        )
    }

    /// 校验用：合法时返回预览语句，否则 `nil`。
    private var isValid: Bool {
        supportsAlteration && !limitIsInvalid && !alterations.isEmpty
    }

    private var statements: String? {
        guard isValid else { return nil }
        return appState.alterDatabaseStatements(name: databaseName, alterations: alterations)
    }

    private func trimmedOrNil(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
