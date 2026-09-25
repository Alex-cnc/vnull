import Foundation

/// **AI 产物 → 笔记** 的桥（DOYAH-10 / 任务 1）。
///
/// 为什么单列一层：AI 的三条能力（诊断 FR-AI-03、维护编排 FR-AI-04、MCP FR-AI-10）各自产出不同形状的结果，
/// 而"存进笔记"必须**同一套元信息**（来源类型 / 连接名 / 指纹 / 时间），否则半年后在笔记里
/// 分不清这条是诊断结论还是维护计划，也不知道当时连的是哪个库。
///
/// **三条边界在类型上落地**（与 `NoteDraft` 一起构成"不能绕过"的约束）：
///   ① 证据里的**行数据不进笔记**（只留编号、种类、说明与取证 SQL）—— 需要带数据必须走显式 `.withRowData()`；
///   ② 来源只记**连接名字**；
///   ③ 指纹可复算（同一份产物重复保存能识别出来）。
public enum AICapture {

    /// **skill 草稿**：AI 攒出来的提示词 / 步骤 / 写法（DOYAH-10 的核心场景）。
    public static func skillNote(
        title: String,
        body: String,
        connectionName: String? = nil,
        tags: [String]? = nil
    ) -> NoteDraft {
        NoteDraft(
            title: title,
            body: body,
            tags: tags ?? [t(.aiNoteTagSkill)],
            source: NoteSource(kind: .skill, connectionName: connectionName)
        )
    }

    /// 纯 SQL 收藏。
    public static func sqlNote(sql: String, connectionName: String?, title: String? = nil) -> NoteDraft {
        NoteDraft(
            title: title ?? firstLine(of: sql),
            body: "```sql\n\(sql)\n```",
            tags: [t(.aiNoteTagSQL)],
            source: NoteSource(kind: .sql, connectionName: connectionName)
        )
    }

    // MARK: - 内部

    /// 从"目标"字符串里取连接名：`user@host:port/db（版本）` → 尽量给一个**人能认出来**的短名。
    /// 注意这里**只是显示用**，来源里绝不存连接串（口令更不可能）。
    static func connectionName(from target: String) -> String? {
        guard let at = target.firstIndex(of: "@") else { return target.isEmpty ? nil : target }
        let hostPart = target[target.index(after: at)...]
        let host = hostPart.split(separator: ":").first.map(String.init) ?? String(hostPart)
        return host.isEmpty ? nil : host
    }

    static func fingerprint(of context: DiagnosisContext, report: DiagnosisAdviceReport) -> String {
        // 稳定指纹：证据 SQL 集合 + 采纳的结论。不掺时间，于是"同一场景再存一次"能被识别。
        let evidencePart = context.evidence.map(\.sql).joined(separator: "|")
        let advicePart = report.items.map { $0.conclusion + $0.citations.joined() }.joined(separator: "|")
        return stableHash(evidencePart + "#" + advicePart)
    }

    static func stableHash(_ text: String) -> String {
        // FNV-1a：小、确定、跨平台（不引哈希库，也不用 `Hasher` —— 后者每次进程启动都不一样）。
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    private static func firstLine(of sql: String) -> String {
        let line = sql.split(separator: "\n").first.map(String.init) ?? "SQL"
        return line.count > 60 ? String(line.prefix(60)) + "…" : line
    }

    /// 维护任务状态的人话（Ultra 侧的适配器在另一个文件里用 → 不能 private）。
    static func stateText(_ state: MaintenanceTask.State) -> String {
        switch state {
        case .pending: return t(.aiNoteStatePending)
        case .approved: return t(.aiNoteStateApproved)
        case .rejected: return t(.aiNoteStateRejected)
        case .executed: return t(.aiNoteStateExecuted)
        case .failed(let reason): return t(.aiNoteStateFailed, reason)
        }
    }
}

/// Core 侧文案（同文件内使用；语言透传见 R-45）。
private func t(_ key: LKey, _ arguments: CVarArg...) -> String {
    arguments.isEmpty
        ? LocalizedStrings.text(key, language: .simplifiedChinese)
        : LocalizedStrings.format(key, language: .simplifiedChinese, arguments)
}
