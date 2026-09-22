import SwiftUI
import DoyahCore

struct ConnectionFormView: View {
    @Environment(\.dismiss) private var dismiss

    let configuration: ConnectionConfig?
    let onSave: (ConnectionConfig, String) -> Void

    @State private var name: String
    @State private var dbType: DatabaseType
    @State private var host: String
    @State private var port: String
    @State private var database: String
    @State private var username: String
    @State private var password: String
    @State private var sslMode: SSLMode
    @State private var timeout: Int
    @State private var bannerMessage: String?
    @State private var isTesting: Bool = false

    init(
        configuration: ConnectionConfig?,
        onSave: @escaping (ConnectionConfig, String) -> Void
    ) {
        self.configuration = configuration
        self.onSave = onSave

        _name = State(initialValue: configuration?.name ?? "")
        _dbType = State(initialValue: configuration?.dbType ?? .postgresql)
        _host = State(initialValue: configuration?.host ?? "127.0.0.1")
        _port = State(initialValue: String(configuration?.port ?? DatabaseType.postgresql.defaultPort))
        _database = State(initialValue: configuration?.database ?? "")
        _username = State(initialValue: configuration?.username ?? "")
        _password = State(initialValue: "")
        _sslMode = State(initialValue: configuration?.sslMode ?? DatabaseType.postgresql.defaultSSLMode)
        _timeout = State(initialValue: configuration?.timeout ?? 5)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(configuration == nil ? L(.connectionFormNew) : L(.connectionFormEdit))
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                Button(L(.commonCancel)) {
                    dismiss()
                }
            }
            .padding()

            Divider()

            Form {
                if let bannerMessage {
                    Text(bannerMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.yellow.opacity(0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                TextField(L(.connectionFormName), text: $name)

                Picker(L(.connectionFormDbType), selection: $dbType) {
                    ForEach(DatabaseType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .onChange(of: dbType) { _, newValue in
                    port = String(newValue.defaultPort)
                    sslMode = newValue.defaultSSLMode
                }

                TextField(L(.connectionFormHost), text: $host)

                TextField(L(.connectionFormPort), text: $port)

                TextField(L(.connectionFormDatabase), text: $database)

                TextField(L(.connectionFormUsername), text: $username)

                SecureASCIIField(text: $password, placeholder: configuration == nil ? L(.connectionFormPassword) : L(.connectionFormPasswordKeep))
                    .frame(height: 22)

                Picker(L(.connectionFormSSLMode), selection: $sslMode) {
                    ForEach(SSLMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                Stepper(L(.connectionFormTimeout, timeout), value: $timeout, in: 1...60)
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button(isTesting ? L(.connectionFormTesting) : L(.connectionFormTest)) {
                    testConnection()
                }
                .disabled(isTesting || !isValid)

                Spacer()

                Button(L(.commonSave)) {
                    onSave(makeConfiguration(), password)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 520, height: 600)
    }

    private func testConnection() {
        let config = makeConfiguration()
        let testPassword = password
        bannerMessage = L(.connectionFormConnecting, config.endpointDescription)
        isTesting = true

        Task { @MainActor in
            let service = DatabaseServiceFactory.make(for: config, password: testPassword)
            do {
                let serverInfo = try await service.connect()
                bannerMessage = L(.connectionFormConnected, serverInfo.version, serverInfo.database, serverInfo.user)
                await service.disconnect()
            } catch {
                let detail = String(reflecting: error)
                let preview = detail.count > 600 ? String(detail.prefix(600)) + "..." : detail
                bannerMessage = L(.connectionFormFailed, preview)
            }
            isTesting = false
        }
    }

    /// 表单校验统一复用 `ConnectionConfig.isValid`（FR-CONN-06 / R-10），
    /// 避免「表单允许保存、模型却判为非法」的两套规则漂移。
    /// 端口先单独解析，防止 `makeConfiguration()` 的默认值把非法输入洗成合法端口。
    private var isValid: Bool {
        guard let portValue = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return (1...65535).contains(portValue) && makeConfiguration().isValid
    }

    private func makeConfiguration() -> ConnectionConfig {
        ConnectionConfig(
            id: configuration?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            dbType: dbType,
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: Int(port) ?? dbType.defaultPort,
            database: database.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            sslMode: sslMode,
            timeout: timeout,
            schemaVersion: ConnectionConfig.currentSchemaVersion
        )
    }
}
