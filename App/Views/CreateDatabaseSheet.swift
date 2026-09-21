import SwiftUI
import PostgresClientCore

/// 「新建数据库」命名表单（FR-META-11）。
///
/// 入口只会在「当前登录用户具备建库权限」时呈现（由 `AppState.canCreateDatabase` 决定），
/// 这里只做本地命名预校验；最终仍以服务端校验为准。
struct CreateDatabaseSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onCreate: (String) -> Void

    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L(.createDatabaseTitle))
                .font(.headline)

            TextField(L(.createDatabaseNamePlaceholder), text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(submit)

            Text(L(.createDatabaseHint))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 340, alignment: .leading)

            if !trimmedName.isEmpty, !PrivilegeProbe.isValidDatabaseName(trimmedName) {
                Label(L(.createDatabaseInvalid), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()

                Button(L(.commonCancel)) {
                    dismiss()
                }

                Button(L(.createDatabaseConfirm)) {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!PrivilegeProbe.isValidDatabaseName(trimmedName))
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        guard PrivilegeProbe.isValidDatabaseName(trimmedName) else { return }
        onCreate(trimmedName)
        dismiss()
    }
}
