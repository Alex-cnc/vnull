import Foundation

/// **Ultra 侧**的 AI 适配器：把诊断结论与维护计划映射成笔记草稿。
///
/// 为什么与 `AICapture` 分开（FR-NOTE-23 的解耦门禁）：
/// 这两个映射**天然引用 Ultra 才有的类型**（`DiagnosisContext` / `MaintenancePlanReview`），
/// 而 `Doyah Notes`（Windows / 移动）没有这些功能 —— 把它们留在 `AICapture` 里，
/// 整个笔记模块就没法在"只有笔记"的构建里独立存在。
/// 拆法：**笔记侧只收标题 / 正文 / 来源**（`AICapture.skillNote` / `sqlNote`，无 Ultra 依赖），
/// Ultra 侧（本文件）再放"诊断 / 维护 → 草稿"的适配器。调用点形状不变（同一个 `AICapture` 类型）。
///
/// **2026-09-26（L-04 插件链回归复核）**：上一轮拆分只搬了三个 `public` 映射函数，
/// 把两个 helper（`fingerprint(of:report:)` / `stateText(_:)`）留在了 `AICapture.swift` ——
/// 它们的**参数就是 Ultra 侧类型**，于是"笔记侧文件可独立构建"这句话当时并不成立。
/// 两个 helper 现在都在本文件；门禁把 Ultra 侧类型名列为禁用，搬回去会红。
extension AICapture {

    /// 诊断结果 → 一条笔记（**只收采纳的条目**；被拒绝的结论不进笔记，它们是过程不是结论）。
    public static func diagnosisNote(
        question: String,
        target: String,
        context: DiagnosisContext,
        report: DiagnosisAdviceReport
    ) -> NoteDraft {
        var lines: [String] = []
        lines.append(t(.aiNoteGoal, target))
        lines.append(t(.aiNoteQuestion, question))
        lines.append("")
        for item in report.items {
            lines.append("## \(item.conclusion)")
            lines.append(t(.aiNoteEvidence, item.citations.joined(separator: ", ")))
            if let sql = item.suggestedSQL {
                lines.append("")
                lines.append("```sql")
                lines.append(sql)
                lines.append("```")
            }
            lines.append("")
        }
        lines.append(t(.aiNoteEvidenceSection))
        for evidence in context.evidence {
            // **只写"取了什么、取没取到"，不写行数据** —— 行数据属于结果集，不属于笔记。
            lines.append(t(.aiNoteEvidenceLine, evidence.id, evidence.kind.displayName, evidence.note))
            lines.append(t(.aiNoteEvidenceSQL, evidence.sql))
        }
        return NoteDraft(
            title: question.isEmpty ? t(.aiNoteDiagnosisTitle) : question,
            body: lines.joined(separator: "\n"),
            tags: [t(.aiNoteTagDiagnosis)],
            source: NoteSource(
                kind: .diagnosis,
                connectionName: connectionName(from: target),
                fingerprint: fingerprint(of: context, report: report)
            )
        )
    }

    /// 维护计划 → 一条笔记（含逐条状态与理由：**为什么被拒也要记**，否则下次还会再提一遍）。
    public static func maintenanceNote(
        planText: String,
        review: MaintenancePlanReview,
        target: String
    ) -> NoteDraft {
        var lines: [String] = []
        lines.append(t(.aiNoteGoal, target))
        lines.append("")
        lines.append("```")
        lines.append(planText.trimmingCharacters(in: .whitespacesAndNewlines))
        lines.append("```")
        lines.append("")
        lines.append(t(.aiNotePlanSection))
        for task in review.tasks {
            lines.append(t(.aiNotePlanLine, task.id, task.kind.rawValue, stateText(task.state), task.summary))
            for note in task.reviewNotes {
                lines.append(t(.aiNotePlanReason, note))
            }
        }
        if !review.unparsableLines.isEmpty {
            lines.append("")
            lines.append(t(.aiNoteUnparsableSection))
            for line in review.unparsableLines {
                lines.append(t(.aiNoteUnparsableLine, line))
            }
        }
        return NoteDraft(
            title: t(.aiNotePlanTitle, String(review.tasks.count)),
            body: lines.joined(separator: "\n"),
            tags: [t(.aiNoteTagMaintenance)],
            source: NoteSource(kind: .maintenance, connectionName: connectionName(from: target))
        )
    }

    // MARK: - Ultra 侧的辅助（**刻意留在这个文件**，别挪回 `AICapture.swift`）

    /// 稳定指纹：证据 SQL 集合 + 采纳的结论。不掺时间，于是"同一场景再存一次"能被识别。
    ///
    /// 为什么在本文件：参数是 `DiagnosisContext` / `DiagnosisAdviceReport` —— Ultra 才有的类型。
    /// 放在笔记侧的文件里，那个文件就没法在"只有笔记"的构建里独立存在
    /// （`Scripts/check-note-module-isolation.py` 现在把 Ultra 侧类型名也列为禁用，挪回去会红）。
    static func fingerprint(of context: DiagnosisContext, report: DiagnosisAdviceReport) -> String {
        let evidencePart = context.evidence.map(\.sql).joined(separator: "|")
        let advicePart = report.items.map { $0.conclusion + $0.citations.joined() }.joined(separator: "|")
        return stableHash(evidencePart + "#" + advicePart)
    }

    /// 维护任务状态的人话（`MaintenanceTask.State` 同样是 Ultra 侧类型）。
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

/// 本文件自用的文案取值（文件级私有，避免与 `AICapture.swift` 里的同名助手冲突）。
private func t(_ key: LKey, _ arguments: CVarArg...) -> String {
    arguments.isEmpty
        ? LocalizedStrings.text(key, language: .simplifiedChinese)
        : LocalizedStrings.format(key, language: .simplifiedChinese, arguments)
}
