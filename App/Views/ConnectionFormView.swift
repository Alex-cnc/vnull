import SwiftUI
import DoyahCore

struct ConnectionFormView: View {
    @Environment(\.dismiss) private var dismiss

    let configuration: ConnectionConfig?
    /// 现有连接（用于"已有分组"提示）—— 由调用方传入，表单不去认识 AppState。
    private let existingConnections: [ConnectionConfig]
    /// 保存回调：配置 + 数据库口令 + SSH 口令（没有隧道或口令留空时为 `nil`）。
    ///
    /// 为什么把 SSH 口令单独穿出来而不是塞进 `ConnectionConfig`：口令**不落配置文件**
    /// （NFR-SEC-01），配置结构里连字段都不该有 —— 存进 `SecretStore` 的动作由 AppState 做。
    let onSave: (ConnectionConfig, String, String?) -> Void

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
    /// **可复制的完整文本**：显示层为了不撑爆对话框会截断，但用户要复制的是**全文**
    /// （错误原文常常一长串，截图或转述都会丢信息）。没截断时就与 `bannerMessage` 相同。
    @State private var bannerCopyText: String?
    /// 从连接 URL 导入（FR-CONN-19）。
    @State private var urlText: String = ""
    @State private var urlMessage: String?
    @State private var urlMessageIsError = false
    private var existingGroups: [String] { ConnectionGrouping.groupNames(existingConnections) }
    @State private var isTesting: Bool = false

    // SSH 隧道（FR-CONN-18）：跳板机参数 + 单独的"测试隧道"状态。
    @State private var sshEnabled: Bool
    @State private var sshHost: String
    @State private var sshPort: String
    @State private var sshUsername: String
    @State private var sshAuth: SSHAuthChoice
    @State private var sshKeyPath: String
    @State private var sshKeyEncrypted: Bool
    @State private var sshHostKeyPolicy: SSHTunnelConfig.HostKeyPolicy
    @State private var sshTimeout: Int
    @State private var sshPassword: String = ""
    @State private var sshTestMessage: String?
    @State private var sshTestIsError = false
    @State private var isTestingTunnel = false

    /// 认证方式在界面上的三种选择（Core 的 `Authentication` 带关联值，不适合直接绑 Picker）。
    enum SSHAuthChoice: Hashable, CaseIterable {
        case agent
        case password
        case privateKey

        var labelKey: LKey {
            switch self {
            case .agent: return .sshAuthAgent
            case .password: return .sshAuthPassword
            case .privateKey: return .sshAuthPrivateKey
            }
        }
    }

    init(
        configuration: ConnectionConfig?,
        existingConnections: [ConnectionConfig] = [],
        onSave: @escaping (ConnectionConfig, String, String?) -> Void
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
        _group = State(initialValue: configuration?.group ?? "")

        let tunnel = configuration?.sshTunnel
        _sshEnabled = State(initialValue: tunnel?.isEnabled ?? false)
        _sshHost = State(initialValue: tunnel?.host ?? "")
        _sshPort = State(initialValue: String(tunnel?.port ?? SSHTunnelConfig.defaultPort))
        _sshUsername = State(initialValue: tunnel?.username ?? "")
        _sshHostKeyPolicy = State(initialValue: tunnel?.hostKeyPolicy ?? .acceptNew)
        _sshTimeout = State(initialValue: tunnel?.connectTimeoutSeconds ?? SSHTunnelConfig.defaultTimeoutSeconds)
        switch tunnel?.authentication {
        case .password:
            _sshAuth = State(initialValue: .password)
            _sshKeyPath = State(initialValue: "")
            _sshKeyEncrypted = State(initialValue: false)
        case .privateKey(let path, let isEncrypted):
            _sshAuth = State(initialValue: .privateKey)
            _sshKeyPath = State(initialValue: path)
            _sshKeyEncrypted = State(initialValue: isEncrypted)
        default:
            _sshAuth = State(initialValue: .agent)
            _sshKeyPath = State(initialValue: "")
            _sshKeyEncrypted = State(initialValue: false)
        }
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
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(bannerMessage)
                            .font(Theme.font(.monoSmall))
                            .foregroundStyle(Theme.text(.secondary))
                            // **文本要能选中复制**：以前只能截图或手抄，错误原文一长串就丢了。
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if let copy = bannerCopyText, copy != bannerMessage {
                            HStack(spacing: Spacing.s) {
                                Button(L(.connectionFormCopyFullError)) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(copy, forType: .string)
                                }
                                .font(Theme.font(.caption))
                                Text(L(.connectionFormErrorTruncated))
                                    .font(Theme.font(.caption))
                                    .foregroundStyle(Theme.text(.secondary))
                            }
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface(.panel))
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
                            .textSelection(.enabled)
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

                sshSection

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
                    onSave(makeConfiguration(), password, resolvedSSHPassword)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 520, height: 600)
    }

    // MARK: - SSH 隧道（FR-CONN-18）

    /// 表单里的 SSH 隧道区块。
    ///
    /// 三种认证方式的**默认是 `ssh-agent`**：私钥不出代理、我们既不读私钥也不存口令，
    /// 是三种里最安全的一种；口令模式要显式选。
    @ViewBuilder
    private var sshSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Toggle(L(.sshEnableLabel), isOn: $sshEnabled)

            if sshEnabled {
                Text(L(.sshSectionSubtitle))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.secondary))
                    .fixedSize(horizontal: false, vertical: true)

                if isSandboxed {
                    Text(L(.sshSandboxNotice))
                        .font(Theme.font(.caption))
                        .foregroundStyle(Theme.status(.warning))
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: Spacing.m) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(L(.sshHostLabel))
                            .font(Theme.font(.caption))
                            .foregroundStyle(Theme.text(.secondary))
                        TextField("", text: $sshHost)
                            .textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(L(.sshPortLabel))
                            .font(Theme.font(.caption))
                            .foregroundStyle(Theme.text(.secondary))
                        TextField("", text: $sshPort)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }
                }

                HStack(spacing: Spacing.m) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(L(.sshUserLabel))
                            .font(Theme.font(.caption))
                            .foregroundStyle(Theme.text(.secondary))
                        TextField("", text: $sshUsername)
                            .textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(L(.sshAuthLabel))
                            .font(Theme.font(.caption))
                            .foregroundStyle(Theme.text(.secondary))
                        Picker("", selection: $sshAuth) {
                            ForEach(SSHAuthChoice.allCases, id: \.self) { choice in
                                Text(L(choice.labelKey)).tag(choice)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                }

                if sshAuth == .privateKey {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(L(.sshKeyPathLabel))
                            .font(Theme.font(.caption))
                            .foregroundStyle(Theme.text(.secondary))
                        TextField(L(.sshKeyPathPlaceholder), text: $sshKeyPath)
                            .textFieldStyle(.roundedBorder)
                        Toggle(L(.sshKeyEncryptedLabel), isOn: $sshKeyEncrypted)
                    }
                }

                if sshAuth == .password || (sshAuth == .privateKey && sshKeyEncrypted) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(L(.sshPasswordLabel))
                            .font(Theme.font(.caption))
                            .foregroundStyle(Theme.text(.secondary))
                        SecureASCIIField(
                            text: $sshPassword,
                            placeholder: configuration == nil ? L(.sshPasswordLabel) : L(.sshPasswordPlaceholder)
                        )
                        .frame(height: 22)
                        Text(L(.sshPasswordKeepHint))
                            .font(Theme.font(.caption))
                            .foregroundStyle(Theme.text(.secondary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: Spacing.m) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(L(.sshHostKeyLabel))
                            .font(Theme.font(.caption))
                            .foregroundStyle(Theme.text(.secondary))
                        Picker("", selection: $sshHostKeyPolicy) {
                            Text(L(.sshHostKeyAcceptNew)).tag(SSHTunnelConfig.HostKeyPolicy.acceptNew)
                            Text(L(.sshHostKeyStrict)).tag(SSHTunnelConfig.HostKeyPolicy.strict)
                        }
                        .labelsHidden()
                        .frame(width: 260)
                    }
                    Spacer()
                }
                Text(L(.sshHostKeyHint))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.secondary))
                    .fixedSize(horizontal: false, vertical: true)

                Stepper(L(.sshTimeoutLabel, sshTimeout), value: $sshTimeout, in: 1...120)

                // 界面层的参数问题：**逐条显示**（Core 给的是枚举，文案在这里）。
                ForEach(sshIssueMessages, id: \.self) { message in
                    Text(message)
                        .font(Theme.font(.caption))
                        .foregroundStyle(Theme.status(.danger))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: Spacing.s) {
                    Button(isTestingTunnel ? L(.sshTestRunning) : L(.sshTestButton)) {
                        testTunnel()
                    }
                    .disabled(isTestingTunnel || !sshIssueMessages.isEmpty)
                    if let sshTestMessage {
                        Text(sshTestMessage)
                            .font(Theme.font(.caption))
                            .foregroundStyle(sshTestIsError ? Theme.status(.danger) : Theme.text(.secondary))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// 当前是不是跑在 macOS 沙箱里。
    ///
    /// 沙箱不允许起 `ssh` 子进程，隧道必然失败 —— 提前说清楚，别让用户去查跳板机。
    /// 这个环境变量是 App Store 沙箱进程的标配标记（`TerminalStartupHint` 用的是同源依据）。
    private var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// 隧道参数的问题清单（文案化）。
    /// 注意顺序与 Core `issues()` 一致 —— 用户按字段从上往下修就能清空。
    private var sshIssueMessages: [String] {
        guard sshEnabled else { return [] }
        return makeSSHTunnelConfig().issues().map { issue in
            switch issue {
            case .missingHost: return L(.sshIssueMissingHost)
            case .missingUsername: return L(.sshIssueMissingUsername)
            case .invalidPort: return L(.sshIssueInvalidPort)
            case .missingPrivateKeyPath: return L(.sshIssueMissingPrivateKeyPath)
            case .invalidTimeout: return L(.sshIssueInvalidTimeout)
            }
        }
    }

    /// 表单 → Core 配置。关掉开关就返回 `nil`（配置里不留半个隧道）。
    private func makeSSHTunnelConfig() -> SSHTunnelConfig {
        SSHTunnelConfig(
            isEnabled: sshEnabled,
            host: sshHost.trimmingCharacters(in: .whitespacesAndNewlines),
            port: Int(sshPort.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0,
            username: sshUsername.trimmingCharacters(in: .whitespacesAndNewlines),
            authentication: {
                switch sshAuth {
                case .agent: return .agent
                case .password: return .password
                case .privateKey:
                    return .privateKey(
                        path: sshKeyPath.trimmingCharacters(in: .whitespacesAndNewlines),
                        isEncrypted: sshKeyEncrypted
                    )
                }
            }(),
            hostKeyPolicy: sshHostKeyPolicy,
            connectTimeoutSeconds: sshTimeout
        )
    }

    /// 本次保存要写进钥匙串的 SSH 口令。
    ///
    /// 编辑已有连接时留空 = **不改动已存的口令**（与数据库口令同一套语义）；
    /// 换了认证方式（不再用口令）时返回空串，由 AppState 删掉旧口令，免得留个用不上的秘密。
    private var resolvedSSHPassword: String? {
        guard sshEnabled else { return "" }
        switch sshAuth {
        case .agent:
            return ""
        case .password, .privateKey:
            if sshPassword.isEmpty { return configuration == nil ? "" : nil }
            return sshPassword
        }
    }

    /// 只测隧道：起一条 `ssh -L`，起来后**真的连一下本机转发端口**（连得通说明
    /// 跳板机→数据库那一段也通），然后立刻收掉。不碰数据库连接、不改任何状态。
    private func testTunnel() {
        let tunnelConfig = makeSSHTunnelConfig()
        let target = SSHTunnelTarget(
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: Int(port.trimmingCharacters(in: .whitespacesAndNewlines)) ?? dbType.defaultPort
        )
        let secret = sshPassword.isEmpty ? nil : sshPassword
        isTestingTunnel = true
        sshTestIsError = false
        sshTestMessage = L(.sshTestRunning)

        Task { @MainActor in
            defer { isTestingTunnel = false }
            guard let localPort = LocalPort.free() else {
                sshTestIsError = true
                sshTestMessage = L(.sshTestFailed, L(.sshTunnelNoFreePort))
                return
            }
            let knownHosts = Self.knownHostsPath()
            let tunnel = SSHTunnelProcess(
                config: tunnelConfig,
                target: target,
                localPort: localPort,
                knownHostsPath: knownHosts,
                password: secret,
                executable: SSHTunnelSecrets.executable(),
                isPortOpen: { host, port in LocalPort.isOpen(host: host, port: port) }
            )
            do {
                _ = try await tunnel.start()
                // 隧道就绪 ≠ 目标可达：再连一次本机转发端口，把 `ssh → 跳板机 → 数据库` 整条走通。
                let reachable = LocalPort.isOpen(host: "127.0.0.1", port: localPort)
                tunnel.stop()
                if reachable {
                    sshTestMessage = L(.sshTestSucceeded, String(localPort))
                } else {
                    sshTestIsError = true
                    sshTestMessage = L(
                        .sshTestTargetUnreachable,
                        target.host,
                        String(target.port)
                    )
                }
            } catch {
                tunnel.stop()
                sshTestIsError = true
                sshTestMessage = L(.sshTestFailed, error.localizedDescription)
            }
        }
    }

    /// 我们自己的 known_hosts 路径（与 `AppState.ensureTunnel` 保持一致）。
    private static func knownHostsPath() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent(DoyahIdentity.applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("known_hosts", isDirectory: false)
            .path
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
        let tunnelConfig = sshEnabled ? makeSSHTunnelConfig() : nil
        let secret = sshPassword.isEmpty ? nil : sshPassword
        bannerMessage = L(.connectionFormConnecting, config.endpointDescription)
        isTesting = true

        Task { @MainActor in
            defer { isTesting = false }

            // 配了隧道就先起隧道、再把测试目标指向本机转发端口。
            // 不这样做的话，「测试连接」会在隧道还没建立时去连一个**内网地址**，
            // 失败信息与隧道毫无关系 —— 用户会去查数据库，而问题其实在跳板机。
            var tunnel: SSHTunnelProcess?
            var target = config
            if let tunnelConfig {
                guard let localPort = LocalPort.free() else {
                    bannerMessage = L(.connectionFormFailed, L(.sshTunnelNoFreePort))
                    bannerCopyText = nil
                    return
                }
                let started = SSHTunnelProcess(
                    config: tunnelConfig,
                    target: SSHTunnelTarget(host: config.host, port: config.port),
                    localPort: localPort,
                    knownHostsPath: Self.knownHostsPath(),
                    password: secret,
                    executable: SSHTunnelSecrets.executable(),
                    isPortOpen: { host, port in LocalPort.isOpen(host: host, port: port) }
                )
                do {
                    _ = try await started.start()
                } catch {
                    bannerMessage = L(.sshTestFailed, error.localizedDescription)
                    bannerCopyText = nil
                    return
                }
                tunnel = started
                target = SSHTunnelEndpoint.rewrite(config, localPort: localPort)
            }
            defer { tunnel?.stop() }

            let service = DatabaseServiceFactory.make(for: target, password: testPassword)
            do {
                let serverInfo = try await service.connect()
                bannerMessage = L(.connectionFormConnected, serverInfo.version, serverInfo.database, serverInfo.user)
                bannerCopyText = nil
                await service.disconnect()
            } catch {
                // 失败信息给人看：`String(reflecting:)` 会带上一堆类型名，先截断再说。
                let detail = String(reflecting: error)
                let preview = detail.count > 600 ? String(detail.prefix(600)) + "..." : detail
                bannerMessage = L(.connectionFormFailed, preview)
                // 显示用截断预览，复制用全文 —— 上面那个按钮拿的就是它。
                bannerCopyText = L(.connectionFormFailed, detail)
            }
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
            group: group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : group,
            sshTunnel: sshEnabled ? makeSSHTunnelConfig() : nil
        )
    }
}
