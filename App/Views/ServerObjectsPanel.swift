import DoyahCore
import SwiftUI

/// 一类服务器级对象在界面上的形态：**要么有对象，要么有一句可读的「不支持 / 近似」说明**。
///
/// 为什么不是直接给 `[ServerObject]`：空数组会被读成「这一类恰好一个都没有」，
/// 而 GBase 的表空间是「根本没有这个概念」—— 两者在界面上必须长得不一样
/// （需求原话：GBase 要显式说「该方言不支持」，不能给空列表）。
struct ServerObjectSection: Identifiable, Equatable {
    let kind: ServerObjectKind
    var objects: [ServerObject] = []
    /// 该方言不支持这一类对象时的可读理由（来自 Core 的方言能力开口）。
    var unsupportedReason: String?
    /// 「有近似物但不是一回事」时的说明（例如 GBase 用 `information_schema.PLUGINS` 近似扩展）。
    var approximationNote: String?

    var id: String { kind.rawValue }
    var isSupported: Bool { unsupportedReason == nil }
}

/// 「服务器级对象」面板（FR-SESS-03）：角色 / 表空间 / 扩展的浏览与增删改。
///
/// 三条与 Core 一致的口径，界面上逐条落地：
/// ① **不支持就直说**：GBase 的表空间 / 扩展显示 Core 给的理由，而不是一个空列表；
/// ② **先预览再执行**：所有写操作先出语句 + 风险等级 + 提醒，破坏性操作用危险色标出来，
///    点「执行」还要过一次确认对话框 —— 这是 FR-SESS-03 的「每个写操作都要能预览与拒绝」；
/// ③ **表空间只读**：`CREATE TABLESPACE` 需要超级用户与真实磁盘目录，本面板不提供。
struct ServerObjectsPanel: View {

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var sections: [ServerObjectSection] = []
    @State private var selectedKind: ServerObjectKind = .role
    @State private var selectedName: String?
    @State private var errorMessage: String?
    @State private var isLoading = false

    // 写操作表单（角色 / 扩展共用；按当前分段显示不同的字段）
    @State private var name = ""
    @State private var password = ""
    @State private var host = "%"
    @State private var extensionSchema = ""
    @State private var canLogin = true
    @State private var isSuperuser = false

    /// 预览结果（先看后做里的「看」）。
    @State private var preview: ServerObjectWritePlan?
    /// 待确认执行的命令（非 nil 时弹确认框）。
    @State private var pendingCommand: ServerObjectCommand?

    /// 统一安全闸门要求二次确认时挂在这里 —— 弹的是**与编辑器同一张**弹窗。
    ///
    /// 与 `pendingCommand`（面板自己那次"确认创建 / 确认删除"）分开：两者语义不同，
    /// 前者是"用户确实要执行这个操作"，后者是"策略要求更高一级确认"（生产标签 /
    /// 全写确认 / 只读拒绝）。同一次点击**最多问一次**：策略要问就走这张。
    @State private var pendingUnifiedConfirm: PendingUnifiedConfirm?
    @State private var notice: String?

    private let limit = ServerObjects.defaultLimit

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            kindPicker
            Divider()
            content
            Divider()
            writeArea
            Divider()
            footer
        }
        .frame(width: 720, height: 700)
        .task { await load() }
        .onChange(of: selectedKind) { _, _ in
            // 换了一类对象，选中项与预览都失效 —— 留着会让「删除选中」删掉另一类里的同名对象。
            selectedName = nil
            preview = nil
            notice = nil
        }
        .confirmationDialog(
            pendingCommand?.isDestructive == true ? L(.serverObjectsConfirmDestructive) : L(.serverObjectsConfirmCreate),
            isPresented: Binding(
                get: { pendingCommand != nil },
                set: { if !$0 { pendingCommand = nil } }
            ),
            presenting: pendingCommand
        ) { command in
            Button(L(.serverObjectsConfirm), role: .destructive) {
                pendingCommand = nil
                Task { await execute(command) }
            }
            Button(L(.commonCancel), role: .cancel) {
                pendingCommand = nil
            }
        } message: { command in
            Text(command.statement)
        }
        .sheet(item: $pendingUnifiedConfirm) { pending in
            SafeModeConfirmSheet(
                reasons: pending.reasons,
                statements: pending.statements,
                onConfirm: { Task { await confirmAndExecute(pending.command) } },
                onCancel: { pendingUnifiedConfirm = nil }
            )
        }
    }

    // MARK: 头部 / 分段

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(L(.serverObjectsTitle))
                    .font(Theme.font(.title))
                if let connection = appState.selectedConnection {
                    Text(connection.endpointDescription)
                        .font(Theme.font(.caption))
                        .foregroundStyle(Theme.text(.secondary))
                }
            }
            Spacer()
            Button(L(.serverObjectsRefresh)) {
                Task { await load() }
            }
            .disabled(isLoading)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
    }

    private var kindPicker: some View {
        Picker("", selection: $selectedKind) {
            ForEach(ServerObjectKind.allCases, id: \.self) { kind in
                Text(kindTitle(kind)).tag(kind)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if isLoading, sections.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.s) {
                ProgressView()
                Text(L(.serverObjectsLoading))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.secondary))
            }
            .padding(Spacing.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        } else if let errorMessage {
            Text(errorMessage)
                .font(Theme.font(.body))
                .foregroundStyle(Theme.status(.warning))
                .fixedSize(horizontal: false, vertical: true)
                .padding(Spacing.l)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        } else if let section = currentSection {
            VStack(alignment: .leading, spacing: Spacing.s) {
                if let reason = section.unsupportedReason {
                    unsupportedView(kind: section.kind, reason: reason)
                } else {
                    if let note = section.approximationNote {
                        noteView(note)
                    }
                    if section.objects.isEmpty {
                        Text(L(.serverObjectsEmpty))
                            .font(Theme.font(.body))
                            .foregroundStyle(Theme.text(.secondary))
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: Spacing.hair) {
                                ForEach(section.objects) { object in
                                    objectRow(object)
                                }
                            }
                        }
                    }
                }
            }
            .padding(Spacing.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        } else {
            Text(L(.serverObjectsEmpty))
                .font(Theme.font(.body))
                .foregroundStyle(Theme.text(.secondary))
                .padding(Spacing.l)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// 「不支持」不是错误、也不是空列表：给一句人话 + Core 的具体理由。
    private func unsupportedView(kind: ServerObjectKind, reason: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label(
                L(.serverObjectsUnsupported, appState.selectedConnection?.dbType.displayName ?? "", kindTitle(kind)),
                systemImage: "nosign"
            )
            .font(Theme.font(.bodyStrong))
            .foregroundStyle(Theme.status(.warning))

            Text(reason)
                .font(Theme.font(.body))
                .foregroundStyle(Theme.text(.secondary))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(Theme.surface(.panel)))
    }

    /// 「近似物」必须和真对象区分开，否则用户会以为 GBase 的插件就是 PostgreSQL 的扩展。
    private func noteView(_ note: String) -> some View {
        Text(L(.serverObjectsApproximation, appState.selectedConnection?.dbType.displayName ?? "") + "\n" + note)
            .font(Theme.font(.caption))
            .foregroundStyle(Theme.text(.secondary))
            .fixedSize(horizontal: false, vertical: true)
            .padding(Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.badge).fill(Theme.surface(.panel)))
    }

    private func objectRow(_ object: ServerObject) -> some View {
        let isSelected = selectedName == object.name
        return Button {
            // 选中即把名字填进表单：这样「删除选中」与「新建」用的是同一个可见的输入，
            // 不会出现"列表里选了一个、表单里写着另一个"的错位。
            selectedName = object.name
            name = object.name
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Text(object.name)
                    .font(Theme.font(.body))
                    .foregroundStyle(Theme.text(.primary))
                Spacer(minLength: Spacing.s)
                Text(object.displaySummary)
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.secondary))
            }
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Radius.control)
                    .fill(isSelected ? Theme.surface(.raised) : Theme.surface(.content))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: 写操作（先预览，再确认）

    @ViewBuilder
    private var writeArea: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(L(.serverObjectsCreateTitle))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))

            switch selectedKind {
            case .tablespace:
                // 明确说清"为什么这里没有建表空间" —— 需求要求本面板不提供 CREATE TABLESPACE。
                Text(L(.serverObjectsTablespaceReadOnly))
                    .font(Theme.font(.body))
                    .foregroundStyle(Theme.text(.secondary))
                    .fixedSize(horizontal: false, vertical: true)

            case .role:
                roleForm

            case .extension:
                extensionForm
            }

            previewBlock
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
    }

    private var roleForm: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                TextField(L(.serverObjectsNamePlaceholder), text: $name)
                    .textFieldStyle(.roundedBorder)
                SecureField(L(.serverObjectsPasswordPlaceholder), text: $password)
                    .textFieldStyle(.roundedBorder)
                TextField(L(.serverObjectsHostPlaceholder), text: $host)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }

            HStack(spacing: Spacing.l) {
                Toggle(L(.serverObjectsCanLogin), isOn: $canLogin)
                Toggle(L(.serverObjectsSuperuser), isOn: $isSuperuser)
                Spacer()
                Button(L(.serverObjectsPreviewCreateRole)) { previewCreateRole() }
                Button(L(.serverObjectsPreviewDropRole)) { previewDropRole() }
            }
        }
    }

    private var extensionForm: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                TextField(L(.serverObjectsNamePlaceholder), text: $name)
                    .textFieldStyle(.roundedBorder)
                TextField(L(.serverObjectsSchemaPlaceholder), text: $extensionSchema)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: Spacing.s) {
                Spacer()
                Button(L(.serverObjectsPreviewCreateExtension)) { previewCreateExtension() }
                Button(L(.serverObjectsPreviewDropExtension)) { previewDropExtension() }
            }
        }
    }

    /// 预览区：语句 / 风险 / 提醒 / 执行按钮。**没有预览就没有执行按钮**。
    @ViewBuilder
    private var previewBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if let command = preview?.command {
                Text(command.statement)
                    .font(Theme.font(.mono))
                    .foregroundStyle(Theme.text(.primary))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Spacing.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Radius.badge).fill(Theme.surface(.panel)))

                Text(L(.serverObjectsRisk, riskTitle(command.risk)))
                    .font(Theme.font(.caption))
                    .foregroundStyle(command.isDestructive ? Theme.status(.danger) : Theme.status(.warning))

                if !command.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.hair) {
                        Text(L(.serverObjectsWarnings))
                            .font(Theme.font(.caption))
                            .foregroundStyle(Theme.text(.tertiary))
                        ForEach(command.warnings, id: \.self) { warning in
                            Text("· " + warning)
                                .font(Theme.font(.caption))
                                .foregroundStyle(Theme.text(.secondary))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                HStack(spacing: Spacing.s) {
                    Button(L(.serverObjectsConfirm)) { requestExecution(command) }
                    Text(L(.serverObjectsDryRunHint))
                        .font(Theme.font(.caption))
                        .foregroundStyle(Theme.text(.tertiary))
                }
            } else {
                Text(L(.serverObjectsNoPreview))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.tertiary))
            }

            if let notice {
                Text(notice)
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.status(.warning))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(L(.commonClose)) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
    }

    // MARK: 动作

    private var currentSection: ServerObjectSection? {
        sections.first { $0.kind == selectedKind }
    }

    private func kindTitle(_ kind: ServerObjectKind) -> String {
        switch kind {
        case .role: return L(.serverObjectsKindRole)
        case .tablespace: return L(.serverObjectsKindTablespace)
        case .extension: return L(.serverObjectsKindExtension)
        }
    }

    private func riskTitle(_ risk: AgentRiskLevel) -> String {
        risk == .destructive ? L(.serverObjectsRiskDestructive) : L(.serverObjectsRiskElevated)
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            sections = try await appState.serverObjectSections(limit: limit)
        } catch {
            errorMessage = ErrorPresenter.message(for: error)
        }
        isLoading = false
    }

    private func previewCreateRole() {
        previewPlan(
            .createRole(
                RoleSpec(
                    name: trimmed(name),
                    password: password.isEmpty ? nil : password,
                    canLogin: canLogin,
                    isSuperuser: isSuperuser,
                    host: trimmed(host).isEmpty ? "%" : trimmed(host)
                )
            )
        )
    }

    private func previewDropRole() {
        guard let target = selectedName else {
            notice = L(.serverObjectsNoSelection)
            return
        }
        previewPlan(.dropRole(name: target, host: trimmed(host).isEmpty ? "%" : trimmed(host)))
    }

    private func previewCreateExtension() {
        let schema = trimmed(extensionSchema)
        previewPlan(.createExtension(ExtensionSpec(name: trimmed(name), schema: schema.isEmpty ? nil : schema)))
    }

    private func previewDropExtension() {
        guard let target = selectedName else {
            notice = L(.serverObjectsNoSelection)
            return
        }
        previewPlan(.dropExtension(name: target))
    }

    /// 生成预览。**不执行任何 SQL**；拒绝与不支持都在这里变成一句可读的话。
    private func previewPlan(_ request: ServerObjectRequest) {
        notice = nil
        do {
            let plan = try appState.serverObjectWritePlan(request)
            preview = plan
            if let reason = plan.rejectionReason {
                notice = L(.serverObjectsRejected, reason)
            } else if let reason = plan.unsupportedReason {
                // 方言不支持：Core 的理由已经是一整句话，直接显示（不再套一层前缀）。
                notice = reason
            }
        } catch {
            preview = nil
            notice = ErrorPresenter.message(for: error)
        }
    }

    /// 点「确认」之后先过**统一安全闸门**，再决定是执行、再确认一次、还是拒绝。
    ///
    /// 为什么要在这里先问一次：策略可能要求更高一级确认（生产标签 / 全写确认），
    /// 那就弹与编辑器同一张弹窗；而**只读连接的拒绝不走确认流程** —— 它不是
    /// 「要不要冒险」，而是「这条连接不写」，点一次「仍然执行」不该等于关掉只读标记。
    private func requestExecution(_ command: ServerObjectCommand) {
        let decision = appState.serverObjectSafetyDecision(command)
        switch decision {
        case .refused(let reasons, let statements):
            let detail = (reasons + statements.map { "· " + $0 }).joined(separator: "\n")
            notice = L(.serverObjectsFailure, detail)
        case .needsConfirmation:
            pendingUnifiedConfirm = PendingUnifiedConfirm(command: command, decision: decision)
        case .allow:
            // 策略没要求更高一级确认时，破坏性操作仍保留面板自己那一次确认。
            if command.isDestructive {
                pendingCommand = command
            } else {
                Task { await execute(command) }
            }
        }
    }

    private func execute(_ command: ServerObjectCommand) async {
        do {
            let start = try await appState.executeServerObjectWrite(command)
            switch start {
            case .started:
                preview = nil
                notice = nil
                await load()
            case .needsConfirmation(let decision):
                pendingUnifiedConfirm = PendingUnifiedConfirm(command: command, decision: decision)
            case .refused(let detail):
                notice = L(.serverObjectsFailure, detail)
            }
        } catch {
            notice = L(.serverObjectsFailure, ErrorPresenter.message(for: error))
        }
    }

    /// 用户在统一确认弹窗里点了「仍然执行」。
    private func confirmAndExecute(_ command: ServerObjectCommand) async {
        pendingUnifiedConfirm = nil
        do {
            let start = try await appState.executeServerObjectWrite(command, bypassingSafetyCheck: true)
            switch start {
            case .started:
                preview = nil
                notice = nil
                await load()
            case .needsConfirmation(let decision):
                pendingUnifiedConfirm = PendingUnifiedConfirm(command: command, decision: decision)
            case .refused(let detail):
                notice = L(.serverObjectsFailure, detail)
            }
        } catch {
            notice = L(.serverObjectsFailure, ErrorPresenter.message(for: error))
        }
    }
}

/// 统一安全闸门要求二次确认的写操作（弹与编辑器同一张弹窗）。
private struct PendingUnifiedConfirm: Identifiable {
    let id = UUID()
    let command: ServerObjectCommand
    let decision: ExecutionSafety.Decision

    var reasons: [String] {
        if case .needsConfirmation(let reasons, _, _) = decision { return reasons }
        return []
    }

    var statements: [String] {
        if case .needsConfirmation(_, _, let statements) = decision { return statements }
        return []
    }
}
