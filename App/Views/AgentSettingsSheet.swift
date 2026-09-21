import SwiftUI
import PostgresClientCore

/// 「智能体设置…」面板（FR-AI-01）。
///
/// 界面上把三件事说清楚，避免用户对「发了什么」有误解：
/// 1. **总开关**：关闭时一行提示直接写明「不会向任何模型服务发送数据」（AC-AI-01）；
/// 2. **密钥去向**：API Key 只进系统钥匙串，不写配置文件（面板里明说）；
/// 3. **当前判定**：直接展示 `AgentGate.decide` 的结论 —— 配置不完整 / 缺密钥 / 已放行，
///    用户不用猜「为什么没反应」。
struct AgentSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    @State private var isEnabled = false
    @State private var endpoint = ""
    @State private var model = ""
    @State private var timeoutSeconds = "60"
    @State private var maxRequests = ""
    @State private var maxOutputTokens = ""
    @State private var maxTotalTokens = ""
    /// 新输入的 Key；为空表示「不改动已保存的 Key」。
    @State private var apiKeyInput = ""
    @State private var clearAPIKey = false
    @State private var isLoaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L(.agentSettingsTitle))
                .font(.headline)

            Form {
                Toggle(L(.agentEnabled), isOn: $isEnabled)
                Text(L(.agentEnabledHint))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                TextField(L(.agentEndpoint), text: $endpoint, prompt: Text(L(.agentEndpointPlaceholder)))
                TextField(L(.agentModel), text: $model, prompt: Text(L(.agentModelPlaceholder)))
                TextField(L(.agentTimeout), text: $timeoutSeconds)

                Section(L(.agentQuotaSection)) {
                    TextField(L(.agentMaxRequests), text: $maxRequests)
                    TextField(L(.agentMaxOutputTokens), text: $maxOutputTokens)
                    TextField(L(.agentMaxTotalTokens), text: $maxTotalTokens)
                }

                Section(L(.agentAPIKey)) {
                    SecureField(L(.agentAPIKey), text: $apiKeyInput)
                    Text(appState.hasAgentAPIKey ? L(.agentAPIKeyConfigured) : L(.agentAPIKeyMissing))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if appState.hasAgentAPIKey {
                        Toggle(L(.agentAPIKeyClear), isOn: $clearAPIKey)
                            .font(.caption)
                    }
                }
            }
            .formStyle(.columns)
            .frame(width: 460)

            statusSection

            HStack {
                Spacer()

                Button(L(.commonCancel)) {
                    dismiss()
                }

                Button(L(.agentSave)) {
                    save()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task {
            guard !isLoaded else { return }
            isLoaded = true
            let configuration = appState.agentConfiguration
            isEnabled = configuration.isEnabled
            endpoint = configuration.endpoint
            model = configuration.model
            timeoutSeconds = String(Int(configuration.timeoutSeconds))
            maxRequests = configuration.quota.maxRequestsPerSession.map(String.init) ?? ""
            maxOutputTokens = configuration.quota.maxOutputTokensPerRequest.map(String.init) ?? ""
            maxTotalTokens = configuration.quota.maxTotalTokens.map(String.init) ?? ""
        }
    }

    // MARK: - 状态

    /// 用「即将保存的配置」算判定，用户改一下开关就能立刻看到结论变化。
    private var decision: AgentOutboundDecision {
        AgentGate.decide(configuration: draftConfiguration, apiKey: effectiveAPIKey)
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L(.agentStatusSection))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Image(systemName: decision.isAllowed ? "checkmark.circle.fill" : "info.circle")
                    .foregroundStyle(decision.isAllowed ? .green : .secondary)
                Text(decision.message)
                    .font(.caption)
                    .foregroundStyle(decision.isAllowed ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !draftConfiguration.issues.isEmpty {
                Label(L(.agentInvalidHint), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .frame(width: 460, alignment: .leading)
    }

    // MARK: - 输入 → 配置

    private var draftConfiguration: AgentConfiguration {
        AgentConfiguration(
            isEnabled: isEnabled,
            endpoint: endpoint,
            model: model,
            timeoutSeconds: Double(timeoutSeconds.trimmingCharacters(in: .whitespaces)) ?? 0,
            quota: AgentQuota(
                maxRequestsPerSession: positiveInt(maxRequests),
                maxOutputTokensPerRequest: positiveInt(maxOutputTokens),
                maxTotalTokens: positiveInt(maxTotalTokens)
            )
        )
    }

    /// 空串 = 不限；非数字 / 非正数一律当作不限（配额是「保护性上限」，填错字符不该误伤）。
    private func positiveInt(_ text: String) -> Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)) else { return nil }
        return value > 0 ? value : nil
    }

    /// 面板里「将要使用的 Key」：新输入优先，其次看是否要清除，最后用已保存的。
    private var effectiveAPIKey: String? {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if clearAPIKey { return nil }
        return appState.agentAPIKey
    }

    private func save() {
        let key: String?
        if !apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            key = apiKeyInput
        } else if clearAPIKey {
            key = ""
        } else {
            key = nil // 不改动
        }

        Task {
            let succeeded = await appState.saveAgentConfiguration(draftConfiguration, apiKey: key)
            if succeeded {
                dismiss()
            }
        }
    }
}
