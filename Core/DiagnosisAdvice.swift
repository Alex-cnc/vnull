import Foundation

/// 诊断建议的**裁决层**（FR-AI-03）。
///
/// 需求原文两条硬约束，这一层就是它们的实现与守卫：
///   ① 「结论须引用真实计划 / 统计 / 锁数据，**不允许无依据断言**」——
///      没有 `[依据: e…]` 的结论行**整条拒绝**（不是"标注一下就算了"，更不是默默采用）；
///      引用不存在的编号同样拒绝（编造证据比没有证据更坏）；
///   ② 「建议可转成 SQL 但**须走审批**」—— 建议里的 SQL 一律过 `ExecutionSafety`
///      （与"在编辑器里敲这条语句"同一道闸门），只读连接上的写语句**直接拒绝**。
///
/// 解析的是**我们自己声明的行格式**（`DiagnosisContext.promptText()` 里写着），
/// 不猜模型的自由散文：解析不了的行如实报成"没看懂"并**原样留着**，
/// 因为静默丢弃会让用户以为模型没说，而实际上说了。
public struct DiagnosisAdviceItem: Equatable, Sendable {
    /// 结论原文。
    public var conclusion: String
    /// 引用的证据编号（至少一个 —— 否则这条根本不会被构造出来）。
    public var citations: [String]
    /// 建议的 SQL（可能没有）。
    public var suggestedSQL: String?
    /// 建议 SQL 的安全判定（没有 SQL 时为 nil）。**审批与否在这里定，不交给界面自己判。**
    public var decision: ExecutionSafety.Decision?

    public init(
        conclusion: String,
        citations: [String],
        suggestedSQL: String? = nil,
        decision: ExecutionSafety.Decision? = nil
    ) {
        self.conclusion = conclusion
        self.citations = citations
        self.suggestedSQL = suggestedSQL
        self.decision = decision
    }
}

/// 解析结果：采纳的条目 + **被拒绝的条目**（拒绝也要有名字与理由）。
public struct DiagnosisAdviceReport: Equatable, Sendable {

    /// 一条被拒绝的结论（以及为什么）。
    public struct Rejection: Equatable, Sendable {
        public enum Reason: Equatable, Sendable {
            /// 没有引用任何证据 —— 需求原文明确禁止的那一类。
            case missingCitations
            /// 引用了不存在的证据编号（编造证据）。
            case unknownCitation(String)
            /// 行格式不认识（如实留着，不静默丢）。
            case unparsable
        }

        public var line: String
        public var reason: Reason
    }

    public var items: [DiagnosisAdviceItem]
    public var rejections: [Rejection]

    public init(items: [DiagnosisAdviceItem], rejections: [Rejection]) {
        self.items = items
        self.rejections = rejections
    }

    /// 有没有"被拒绝的结论" —— 界面据此提示用户（而不是把拒绝藏起来）。
    public var hasRejections: Bool { !rejections.isEmpty }
}

public enum DiagnosisAdvice {

    /// 解析模型回复。
    ///
    /// - Parameters:
    ///   - reply: 模型回复原文（按行解析）。
    ///   - context: 诊断上下文（提供**合法证据编号**）。
    ///   - databaseType: 方言（影响 `ExecutionSafety` 的语句分类）。
    ///   - policy: 执行安全策略（只读连接 / 生产标签等由调用方给）。
    public static func parse(
        reply: String,
        context: DiagnosisContext,
        databaseType: DatabaseType = .postgresql,
        policy: ExecutionSafetyPolicy = .default
    ) -> DiagnosisAdviceReport {
        let validIDs = context.availableIDs
        var items: [DiagnosisAdviceItem] = []
        var rejections: [DiagnosisAdviceReport.Rejection] = []

        var pendingConclusion: (text: String, citations: [String], line: String)?

        func flushPending() {
            guard let pending = pendingConclusion else { return }
            items.append(
                DiagnosisAdviceItem(conclusion: pending.text, citations: pending.citations)
            )
            pendingConclusion = nil
        }

        for rawLine in reply.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if let conclusion = parseConclusion(line) {
                // 上一条结论（如果还没被拒绝）先落地。
                flushPending()
                switch validate(citations: conclusion.citations, validIDs: validIDs) {
                case .ok:
                    pendingConclusion = (conclusion.text, conclusion.citations, line)
                case .missing:
                    rejections.append(.init(line: line, reason: .missingCitations))
                case .unknown(let id):
                    rejections.append(.init(line: line, reason: .unknownCitation(id)))
                }
                continue
            }

            if let sql = parseSuggestion(line) {
                let text = pendingConclusion?.text ?? ""
                let citations = pendingConclusion?.citations ?? []
                let decision = ExecutionSafety.check(sql: sql, databaseType: databaseType, policy: policy)
                items.append(
                    DiagnosisAdviceItem(
                        conclusion: text,
                        citations: citations,
                        suggestedSQL: sql,
                        decision: decision
                    )
                )
                pendingConclusion = nil
                continue
            }

            // 认不出来的行：**如实留着**（静默丢弃会让用户以为模型没说）。
            rejections.append(.init(line: line, reason: .unparsable))
        }

        flushPending()
        return DiagnosisAdviceReport(items: items, rejections: rejections)
    }

    // MARK: - 行解析（格式由 `DiagnosisContext.promptText()` 声明）

    /// **语法记号直接取自提示词模板**（`LocalizedStrings` 里那两行）。
    ///
    /// 为什么这么做：提示词与解析器是同一份契约的两半 —— 两边各写一份「结论:」，
    /// 迟早会改了一边；而且这么写之后，Core 里**一个汉字字面量都不需要**
    /// （本地化棘轮守着这条：Core 的展示文本必须走语言表）。
    static func grammarTokens() -> (conclusion: [String], evidence: [String], suggestion: [String]) {
        let conclusionLine = LocalizedStrings.text(.diagnosisFormatConclusion, language: .simplifiedChinese)
        let suggestionLine = LocalizedStrings.text(.diagnosisFormatSuggestion, language: .simplifiedChinese)

        func label(_ line: String) -> String {
            String(line.prefix { $0 != " " })
        }
        // `[依据: e1,e2]` → 截到冒号（含）为止，就是引用记号本身。
        func marker(_ line: String) -> String? {
            guard let open = line.firstIndex(of: "["),
                  let colon = line[open...].firstIndex(of: ":") else { return nil }
            return String(line[open...colon])
        }

        func variants(_ token: String) -> [String] {
            let fullWidth = token.replacingOccurrences(of: ":", with: "：")
            let english = token.lowercased()
            return Array(Set([token, fullWidth, english])).sorted()
        }

        let conclusionTokens = variants(label(conclusionLine))
        let suggestionTokens = variants(label(suggestionLine))
        let evidenceTokens = marker(conclusionLine).map(variants) ?? ["[evidence:"]
        return (conclusionTokens, evidenceTokens, suggestionTokens)
    }

    /// `结论: <文本> [依据: e1,e2]`
    static func parseConclusion(_ line: String) -> (text: String, citations: [String])? {
        let tokens = grammarTokens()
        guard let body = firstValue(of: tokens.conclusion, in: line) else { return nil }
        var range: Range<String.Index>?
        for marker in tokens.evidence {
            if let found = body.range(of: marker, options: .backwards) {
                // 取**最靠后**的那个记号（结论正文里可能出现方括号）。
                if range == nil || found.lowerBound > range!.lowerBound { range = found }
            }
        }
        guard let range else {
            return (body.trimmingCharacters(in: .whitespaces), [])
        }
        let text = String(body[body.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        let tail = String(body[range.upperBound...])
        guard let close = tail.firstIndex(of: "]") else {
            return (text, [])
        }
        let ids = tail[tail.startIndex..<close]
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == " " || $0 == "、" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return (text, ids)
    }

    /// `建议: <SQL>`
    static func parseSuggestion(_ line: String) -> String? {
        guard let body = firstValue(of: grammarTokens().suggestion, in: line) else { return nil }
        let sql = body.trimmingCharacters(in: .whitespaces)
        return sql.isEmpty ? nil : sql
    }

    private static func firstValue(of prefixes: [String], in line: String) -> String? {
        let lowered = line.lowercased()
        for prefix in prefixes {
            let candidate = prefix.lowercased()
            if lowered.hasPrefix(candidate) {
                return String(line.dropFirst(prefix.count))
            }
        }
        return nil
    }

    private enum CitationCheck {
        case ok
        case missing
        case unknown(String)
    }

    private static func validate(citations: [String], validIDs: Set<String>) -> CitationCheck {
        guard !citations.isEmpty else { return .missing }
        for id in citations where !validIDs.contains(id) {
            return .unknown(id)
        }
        return .ok
    }
}
