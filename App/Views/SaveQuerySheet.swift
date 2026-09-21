import SwiftUI

/// 「保存查询」命名表单。
struct SaveQuerySheet: View {
    @Environment(\.dismiss) private var dismiss

    let isDuplicate: (String) -> Bool
    let onSave: (String) -> Void

    @State private var name: String

    init(
        defaultName: String,
        isDuplicate: @escaping (String) -> Bool,
        onSave: @escaping (String) -> Void
    ) {
        _name = State(initialValue: defaultName)
        self.isDuplicate = isDuplicate
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L(.saveQueryTitle))
                .font(.headline)

            TextField(L(.saveQueryName), text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)

            if isDuplicate(trimmedName) {
                Label(L(.saveQueryDuplicate), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()

                Button(L(.commonCancel)) {
                    dismiss()
                }

                Button(isDuplicate(trimmedName) ? L(.saveQueryOverwrite) : L(.commonSave)) {
                    onSave(trimmedName)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 「跳到行 / 列」表单。
struct GoToLineSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onGo: (Int, Int?) -> Void

    @State private var line = ""
    @State private var column = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L(.goToLineTitle))
                .font(.headline)

            TextField(L(.goToLineLine), text: $line)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)

            TextField(L(.goToLineColumn), text: $column)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)

            if !line.isEmpty && parsedLine == nil {
                Text(L(.goToLineInvalid))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()

                Button(L(.commonCancel)) {
                    dismiss()
                }

                Button(L(.goToLineConfirm)) {
                    if let parsedLine {
                        onGo(parsedLine, parsedColumn)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(parsedLine == nil)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private var parsedLine: Int? {
        guard let value = Int(line.trimmingCharacters(in: .whitespaces)), value >= 1 else {
            return nil
        }
        return value
    }

    private var parsedColumn: Int? {
        guard let value = Int(column.trimmingCharacters(in: .whitespaces)), value >= 1 else {
            return nil
        }
        return value
    }
}
