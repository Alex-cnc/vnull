import SwiftUI
import DoyahCore

struct ConnectionFormView: View {
    @Environment(\.dismiss) private var dismiss

    let configuration: ConnectionConfig?
    /// 现有连接（用于"已有分组"提示）—— 由调用方传入，表单不去认识 AppState。
    private let existingConnections: [ConnectionConfig]
    let onSave: (ConnectionConfig, String) -> Void

    @State private var name: String
    @State private var dbType: DatabaseType
    @State private var host: String
    @State private var port: String
    @State private var database: String
    @State private var username: String
    @State private var environment: ConnectionEnvironment?
    @State private var colorTag: CategoricalTone?
    /// 只读连接与启动 SQL（FR-CONN-17）。
    @State private var isReadOnly: Bool
    @State private var startupSQL: String
    /// 分组 / 文件夹（FR-CONN-15）。
    @State private var group: String
    @State private var password: String
    @State private var sslMode: SSLMode
    @State private var timeout: Int
    @State private var bannerMessage: String?
    /// 从连接 URL 导入（FR-CONN-19）。
    @State private var urlText: String = ""
    @State private var urlMessage: String?
    @State private var urlMessageIsError = false
    private var existingGroups: [String] { ConnectionGrouping.groupNames(existingConnections) }
    @State private var isTesting: Bool = false

    init(
        configuration: ConnectionConfig?,
        existingConnections: [ConnectionConfig] = [],
        onSave: @escaping (ConnectionConfig, String) -> Void
    ) {
        self.configuration = configuration
        self.existingConnections = existingConnections
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
        // 编辑已有连接时把标签带进来 —— 否则"编辑一次就丢标签"（这类丢失很难被发现）。
        _environment = State(initialValue: configuration?.environment)
        _colorTag = State(initialValue: configuration?.colorTag)
        _isReadOnly = State(initialValue: configuration?.isReadOnly ?? false)
        _startupSQL = State(initialValue: configuration?.startupSQL ?? "")
        _group = State(initialValue: configuration?.group ?? "")    }

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

                // 从连接 URL 导入（FR-CONN-19）：粘一行 `postgres://…` 就把表单填好。
                // 解析 / 序列化 / "配置文件里不留密码" 三条纪律由 Core 的 `ConnectionURL` 负责
                // （已有单测与脚本），这里只做"填进哪几个字段"的映射，不重复实现解析。
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(L(.connectionFormURLImport))
                        .font(Theme.font(.caption))
                        .foregroundStyle(Theme.text(.secondary))
                    HStack(spacing: Spacing.s) {
                        TextField(L(.connectionFormURLPlaceholder), text: $urlText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { importFromURL() }
                        Button(L(.connectionFormURLImportAction)) {
                            importFromURL()
                        }
                        .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let urlMessage {
                        Text(urlMessage)
                            .font(Theme.font(.caption))
                            .foregroundStyle(urlMessageIsError ? Theme.status(.danger) : Theme.text(.secondary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
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

                // 环境标签与颜色（FR-CONN-16）：**生产标签会让高危语句强制确认**，
                // 因此这里不是"外观选项"，而是安全设置的一部分。
                HStack(spacing: Spacing.m) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(L(.connectionEnvironmentLabel))
                            .font(Theme.font(.caption))
                            .foregroundStyle(Theme.text(.secondary))
                        Picker("", selection: $environment) {
                            Text(L(.connectionEnvironmentNone)).tag(ConnectionEnvironment?.none)
                            ForEach(ConnectionEnvironment.orderedForPick, id: \.self) { value in
                                Text(L(value.labelKey)).tag(ConnectionEnvironment?.some(value))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }

                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(L(.connectionColorLabel))
                            .font(Theme.font(.caption))
                            .foregroundStyle(Theme.text(.secondary))
                        Picker("", selection: $colorTag) {
                            Text(L(.connectionColorNone)).tag(CategoricalTone?.none)
                            ForEach(CategoricalTone.allCases, id: \.self) { tone in
                                Text(tone.rawValue).tag(CategoricalTone?.some(tone))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }

                    ConnectionEnvironmentBadge(appearance: ConnectionAppearance(environment: environment, colorTag: colorTag))
                    Spacer()
                }

                SecureASCIIField(text: $password, placeholder: configuration == nil ? L(.connectionFormPassword) : L(.connectionFormPasswordKeep))
                    .frame(height: 22)

                // 只读连接（FR-CONN-17）：客户端拒绝写语句。
                // 说明文案点明"这是本机保护、不替代数据库权限"，免得用户以为它是权限控制。
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(L(.connectionFormReadOnly), isOn: $isReadOnly)
                    Text(L(.connectionFormReadOnlyHint))
                        .font(Theme.font(.caption))
                        .foregroundStyle(Theme.text(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }

                // 分组（FR-CONN-15）：填了就在侧边栏按组折叠展示；留空 = 未分组。
                VStack(alignment: .leading, spacing: 2) {
                    TextField(L(.connectionFormGroup), text: $group)
                    if !existingGroups.isEmpty {
                        Text(L(.connectionFormGroupExisting, existingGroups.joined(separator: " / ")))
                            .font(Theme.font(.caption))
                            .foregroundStyle(Theme.text(.secondary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // 启动 SQL：连接建立后逐条执行（如 SET search_path / statement_timeout）。
                VStack(alignment: .leading, spacing: 2) {
                    TextField(L(.connectionFormStartupSQL), text: $startupSQL, axis: .vertical)
                        .lineLimit(2...4)
                    Text(L(.connectionFormStartupSQLHint))
                        .font(Theme.font(.caption))
                        .foregroundStyle(Theme.text(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }

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

    /// 把一行连接 URL 映射到表单字段（FR-CONN-19）。
    ///
    /// 三条刻意的选择：
    /// ① **失败只说人话**：直接把 `ConnectionURL.ParseError` 的 `errorDescription` 显示出来，
    ///    它是给用户看的（哪一段不合法、缺什么），不是给开发者看的。
    /// ② **被忽略的参数要报出来**：URL 里带了 `application_name` 之类我们没实现的参数时，
    ///    静默丢弃会让人以为"设置生效了"。
    /// ③ **名称只在空的时候填**：用户已经写了名字就别覆盖。
    private func importFromURL() {
        let raw = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        switch ConnectionURL.parse(raw) {
        case .failure(let error):
            urlMessageIsError = true
            urlMessage = L(.connectionFormURLFailed, error.errorDescription ?? "\(error)")

        case .success(let imported):
            let config = imported.configuration
            dbType = config.dbType
            host = config.host
            port = String(config.port)
            database = config.database
            username = config.username
            sslMode = config.sslMode
            // 两条合并规则在 Core 里（`ConnectionURL.FormMerge`，有单测）：
            // 名称只在空着的时候采用 URL 推断值；密码只在 URL 里带了才覆盖。
            password = ConnectionURL.FormMerge.resolvedPassword(current: password, imported: imported.password)
            name = ConnectionURL.FormMerge.resolvedName(current: name, imported: config.name)

            urlMessageIsError = false
            var message = L(.connectionFormURLImported, config.endpointDescription)
            if !imported.ignoredParameters.isEmpty {
                message += " " + L(.connectionFormURLIgnored, imported.ignoredParameters.joined(separator: ", "))
            }
            urlMessage = message
        }
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
            schemaVersion: ConnectionConfig.currentSchemaVersion,
            environment: environment,
            colorTag: colorTag,
            isReadOnly: isReadOnly,
            startupSQL: startupSQL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : startupSQL,
            group: group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : group
        )
    }
}
