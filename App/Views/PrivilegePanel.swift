import SwiftUI
import PostgresClientCore

/// 「权限…」面板（FR-SESS-04）。
///
/// 两件事：
/// 1. 查看指定角色在**库 / schema / 表 / 视图 / 序列**上的已授权限（按对象分组）；
/// 2. 生成 `GRANT` / `REVOKE` —— **执行前先把语句摊开给人看**，非法输入直接禁用按钮。
struct PrivilegePanel: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    /// 变更对象类别（面板只暴露最常用的四类）。
    private enum ObjectKindChoice: String, CaseIterable, Identifiable {
        case database
        case schema
        case table
        case sequence

        var id: String { rawValue }
        var title: String { rawValue }
    }

    @State private var role = ""
    @State private var privileges: [ObjectPrivilege] = []
    @State private var hasLoaded = false
    @State private var isLoading = false
    @State private var errorText: String?

    @State private var objectKind: ObjectKindChoice = .table
    @State private var objectName = ""
    @State private var schema = ""
    @State private var privilegeList = "SELECT"
    @State private var grantee = ""
    @State private var withGrantOption = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L(.privilegeTitle))
                    .font(.headline)
                Spacer()
                Button(L(.commonClose)) { dismiss() }
            }

            roleRow
            privilegeListSection
            Divider()
            composerSection
        }
        .padding(20)
        .frame(width: 720, height: 620)
        .task {
            if role.isEmpty {
                role = appState.selectedConnection?.username ?? ""
            }
            await load()
        }
    }

    // MARK: - 已授权限

    private var roleRow: some View {
        HStack(spacing: 8) {
            Text(L(.privilegeRole))
                .font(.caption)
            TextField(L(.privilegeRole), text: $role)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onSubmit { Task { await load() } }

            Button(L(.privilegeLoad)) {
                Task { await load() }
            }
            .disabled(isLoading || !PrivilegeProbe.isValidRoleName(role))

            if isLoading {
                ProgressView().controlSize(.small)
            }

            Spacer()

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var privilegeListSection: some View {
        if privileges.isEmpty {
            Text(hasLoaded ? L(.privilegeEmpty) : " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(ObjectPrivilegeParser.groupedByObject(privileges), id: \.object.id) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(group.object.objectKind.rawValue) \(group.object.qualifiedObjectName)")
                                .font(.caption)
                                .fontWeight(.semibold)
                            ForEach(group.privileges) { privilege in
                                Text("\(privilege.privilege) · \(privilege.grantee)\(privilege.isGrantable ? " · \(L(.privilegeColumnGrantOption))" : "")")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 200)
        }
    }

    // MARK: - 授予 / 回收

    private var composerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L(.privilegeGrantSection))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Picker(L(.privilegeObjectKind), selection: $objectKind) {
                    ForEach(ObjectKindChoice.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .frame(width: 160)

                TextField(L(.privilegeObjectName), text: $objectName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)

                TextField(L(.privilegeSchema), text: $schema)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .disabled(objectKind == .database || objectKind == .schema)
            }

            HStack(spacing: 8) {
                TextField(L(.privilegePrivileges), text: $privilegeList)
                    .textFieldStyle(.roundedBorder)

                TextField(L(.privilegeGrantee), text: $grantee)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }

            Toggle(L(.privilegeWithGrantOption), isOn: $withGrantOption)
                .font(.caption)

            statementPreview

            HStack {
                Spacer()

                Button(L(.privilegeRevoke)) {
                    Task { await apply(revoke: true) }
                }
                .disabled(revokeStatement == nil)

                Button(L(.privilegeGrant)) {
                    Task { await apply(revoke: false) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(grantStatement == nil)
            }
        }
    }

    @ViewBuilder
    private var statementPreview: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L(.privilegePreview))
                .font(.caption)
                .foregroundStyle(.secondary)

            if let statement = grantStatement {
                Text(statement)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Label(L(.privilegeInvalid), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - 组装与执行

    private var change: SQLGenerator.PrivilegeChange? {
        let names = privilegeList
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }

        let trimmedObject = objectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSchema = schema.trimmingCharacters(in: .whitespacesAndNewlines)
        let schemaOrNil = trimmedSchema.isEmpty ? nil : trimmedSchema

        let object: SQLGenerator.PrivilegeObject
        switch objectKind {
        case .database: object = .database(trimmedObject)
        case .schema: object = .schema(trimmedObject)
        case .table: object = .table(schema: schemaOrNil, name: trimmedObject)
        case .sequence: object = .sequence(schema: schemaOrNil, name: trimmedObject)
        }

        return SQLGenerator.PrivilegeChange(
            privileges: names,
            object: object,
            grantee: grantee.trimmingCharacters(in: .whitespacesAndNewlines),
            withGrantOption: withGrantOption
        )
    }

    private var grantStatement: String? {
        guard let change else { return nil }
        return appState.privilegeStatement(change, revoke: false)
    }

    private var revokeStatement: String? {
        guard let change else { return nil }
        return appState.privilegeStatement(change, revoke: true)
    }

    private func load() async {
        guard PrivilegeProbe.isValidRoleName(role) else { return }
        isLoading = true
        errorText = nil
        defer { isLoading = false }

        do {
            privileges = try await appState.loadObjectPrivileges(role: role)
            hasLoaded = true
        } catch {
            privileges = []
            hasLoaded = true
            errorText = ErrorPresenter.message(for: error)
        }
    }

    private func apply(revoke: Bool) async {
        guard let change else { return }
        let succeeded = await appState.applyPrivilegeChange(change, revoke: revoke)
        if succeeded {
            await load()
        } else {
            errorText = appState.errorMessage
        }
    }
}
