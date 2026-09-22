import SwiftUI
import DoyahCore

/// 「删除数据库…」二次确认（FR-SESS-05）。
///
/// 验收要点要求**必须手输库名**才能删除：只按一个「删除」按钮太容易误触，
/// 而 `DROP DATABASE` 不可回滚、会带走库内全部对象。
struct DropDatabaseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    let databaseName: String
    let onConfirm: (String) -> Void

    @State private var typedName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L(.dropDbTitle))
                .font(.headline)

            Label(L(.dropDbWarning), systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(width: 420, alignment: .leading)

            if let statement = appState.dropDatabaseStatement(name: databaseName) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L(.dbPropsPreview))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(statement)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }

            Text(L(.dropDbTypeToConfirm, databaseName))
                .font(.caption)

            TextField(databaseName, text: $typedName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)

            Text(L(.dropDbActiveConnections))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 420, alignment: .leading)

            HStack {
                Spacer()

                Button(L(.commonCancel)) {
                    dismiss()
                }

                Button(L(.dropDbConfirm), role: .destructive) {
                    onConfirm(databaseName)
                    dismiss()
                }
                .disabled(typedName.trimmingCharacters(in: .whitespacesAndNewlines) != databaseName)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
