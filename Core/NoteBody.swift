import Foundation

/// 笔记正文的**权威源与投影**（Q8 已拍板选 C：Markdown 为源 + 受限样式旁挂）。
///
/// 这一层要回答的不是"格式好不好看"，而是**投影到底有损在哪**。所以它是一个可单测的纯函数对：
///   · `toSpans`：权威源（Markdown + 旁挂样式）→ 编辑器要的 span 树（鸿蒙 `RichEditor` / iOS / Android 各自渲染它）；
///   · `fromSpans`：span 树 → 权威源（**能进 Markdown 的就写进 Markdown，进不了的落旁挂**）；
///   · `exportMarkdown`：给"导出 md 文件"用 —— **必须同时给出降级报告**，不许静默丢样式。
///
/// **支持的子集刻意很小**（Q8 的"不做清单"在这里变成代码）：
/// 粗体 `**x**`、斜体 `*x*`、行内代码 `` `x` ``；**行内颜色与字号 Markdown 表达不了 → 一律进旁挂**；
/// 其余 Markdown 语法（标题、列表、表格、链接…）**原样当纯文本搬运**，不解析也不破坏 ——
/// 这保证了"AI 写进来的 Markdown 不会被我们改坏"。
public enum NoteBodyFormat {
    /// 权威源的版本号：结构变了才升，并必须给出迁移规则（Q8 的硬要求）。
    public static let currentVersion = 1
}

/// 旁挂样式：只承载 **Markdown 表达不了**的属性（颜色 / 字号），并按"文本 + 第几次出现"定位。
///
/// 为什么用"文本 + 序号"而不是偏移量：偏移量在 AI 改写后会整体失效（一改就全错位），
/// 而"这段文字 + 它是第几次出现"在人改、AI 改之后**仍大概率对得上**；对不上就如实降级（见 `toSpans`）。
public struct NoteSidecarStyle: Codable, Equatable, Sendable {
    public var text: String
    /// 同一段文字在一篇笔记里出现的次序（从 0 开始）。
    public var occurrence: Int
    /// `#RRGGBB`。
    public var color: String?
    /// 字号（缺省 nil = 跟随主题）。
    public var size: Int?

    public init(text: String, occurrence: Int = 0, color: String? = nil, size: Int? = nil) {
        self.text = text
        self.occurrence = occurrence
        self.color = color
        self.size = size
    }
}

/// 权威源：Markdown 正文 + 版本号 + 旁挂样式。
public struct NoteBody: Codable, Equatable, Sendable {
    public var version: Int
    public var markdown: String
    public var sidecar: [NoteSidecarStyle]

    public init(version: Int = NoteBodyFormat.currentVersion, markdown: String = "", sidecar: [NoteSidecarStyle] = []) {
        self.version = version
        self.markdown = markdown
        self.sidecar = sidecar
    }

    /// 版本迁移：**只认自己认识的版本**，更高的版本如实拒绝（不猜、不静默降级）。
    public enum MigrationError: Error, Equatable {
        case fromFuture(Int)
    }

    public func migrated() throws -> NoteBody {
        guard version <= NoteBodyFormat.currentVersion else {
            throw MigrationError.fromFuture(version)
        }
        var copy = self
        copy.version = NoteBodyFormat.currentVersion
        return copy
    }
}

/// span 树（编辑器渲染用）：一段文字 + 它带的样式。
public struct NoteSpan: Equatable, Sendable {
    public enum Style: String, Equatable, Sendable, CaseIterable {
        case bold
        case italic
        case code
        /// 行内颜色（Markdown 表达不了，来自旁挂）
        case color
        /// 字号（同上）
        case size
    }

    public var text: String
    public var styles: Set<Style>
    public var color: String?
    public var size: Int?

    public init(text: String, styles: Set<Style> = [], color: String? = nil, size: Int? = nil) {
        self.text = text
        self.styles = styles
        self.color = color
        self.size = size
    }
}

/// 投影结果：spans + **如实报出的降级**（哪些样式没能落到 span 上、为什么）。
public struct NoteProjection: Equatable, Sendable {
    public var spans: [NoteSpan]
    public var degradations: [String]

    public init(spans: [NoteSpan], degradations: [String] = []) {
        self.spans = spans
        self.degradations = degradations
    }
}

public enum NoteBodyProjection {

    // MARK: - 权威源 → span 树

    /// Markdown + 旁挂 → span 树。**解析不了的东西原样保留为纯文本**（不吞、不改写）。
    public static func toSpans(_ body: NoteBody) -> NoteProjection {
        var spans: [NoteSpan] = []
        var degradations: [String] = []
        var remaining = Substring(body.markdown)

        // 只认三个行内标记；扫到谁先出现就切谁，切不动就整段退化成纯文本。
        while !remaining.isEmpty {
            if let marker = nextMarker(in: remaining) {
                let (before, markerText, inner, after) = marker
                if !before.isEmpty {
                    spans.append(NoteSpan(text: String(before)))
                }
                switch markerText {
                case "**": spans.append(NoteSpan(text: String(inner), styles: [.bold]))
                case "*": spans.append(NoteSpan(text: String(inner), styles: [.italic]))
                default: spans.append(NoteSpan(text: String(inner), styles: [.code]))
                }
                remaining = after
            } else {
                spans.append(NoteSpan(text: String(remaining)))
                remaining = ""
            }
        }

        // 旁挂：按"文本 + 第几次出现"定位 —— **要能在 span 内部再切一刀**。
        // 一开始我按"整段 span 文本相等"定位，结果纯文本（没有任何 Markdown 标记）时整篇是一个大 span，
        // 旁挂永远定位不到（测试当场抓到）。正确做法是：找到那段文字后**把 span 切成三份**再上样式。
        // 已知简化：出现次序按"扫描顺序"计，不做跨 span 的严格计数（原型够用，正式实现要写清口径）。
        for style in body.sidecar {
            var seen = 0
            var applied = false
            var index = 0
            while index < spans.count {
                guard let range = spans[index].text.range(of: style.text) else {
                    index += 1
                    continue
                }
                if seen < style.occurrence {
                    seen += 1
                    index += 1
                    continue
                }
                let text = spans[index].text
                var styled = NoteSpan(text: style.text, styles: spans[index].styles, color: style.color, size: style.size)
                if style.color != nil { styled.styles.insert(.color) }
                if style.size != nil { styled.styles.insert(.size) }
                let before = String(text[text.startIndex..<range.lowerBound])
                let after = String(text[range.upperBound...])
                var replacement: [NoteSpan] = []
                if !before.isEmpty { replacement.append(NoteSpan(text: before)) }
                replacement.append(styled)
                if !after.isEmpty { replacement.append(NoteSpan(text: after)) }
                spans.replaceSubrange(index...index, with: replacement)
                applied = true
                break
            }
            if !applied {
                degradations.append(LocalizedStrings.format(.noteSidecarLost, language: .simplifiedChinese, String(style.occurrence + 1), style.text))
            }
        }
        return NoteProjection(spans: spans, degradations: degradations)
    }

    private static func nextMarker(in text: Substring) -> (Substring, String, Substring, Substring)? {
        // **取最早出现的那个标记**（不是"先试代码再试粗体"——那样会把更早的粗体漏掉，
        // 本轮测试当场抓到：`普通 **加粗** … ` 里的粗体被当成了前导纯文本）。
        // 另外**空内容不算一对**（`**粗体` 未闭合时不该被剥掉一颗星）。
        var best: (start: Range<String.Index>, marker: String, inner: Substring, after: Substring)?
        for marker in ["`", "**", "*"] {
            guard let start = text.range(of: marker) else { continue }
            if let best, best.start.lowerBound <= start.lowerBound { continue }
            let afterStart = text[start.upperBound...]
            guard let end = afterStart.range(of: marker) else { continue }
            let inner = afterStart[afterStart.startIndex..<end.lowerBound]
            guard !inner.isEmpty else { continue }
            best = (start, marker, inner, afterStart[end.upperBound...])
        }
        guard let best else { return nil }
        return (text[text.startIndex..<best.start.lowerBound], best.marker, best.inner, best.after)
    }

    // MARK: - span 树 → 权威源

    /// span 树 → 权威源。**能进 Markdown 的进 Markdown，进不了的落旁挂** ——
    /// 这样"编辑器里改过再存"不会悄悄丢掉颜色与字号。
    public static func fromSpans(_ spans: [NoteSpan]) -> NoteBody {
        var markdown = ""
        var sidecar: [NoteSidecarStyle] = []
        var seen: [String: Int] = [:]

        for span in spans {
            var text = span.text
            if span.styles.contains(.code) {
                text = "`" + text + "`"
            } else {
                if span.styles.contains(.bold) { text = "**" + text + "**" }
                if span.styles.contains(.italic) { text = "*" + text + "*" }
            }
            markdown += text

            if span.color != nil || span.size != nil {
                let occurrence = seen[span.text, default: 0]
                seen[span.text] = occurrence + 1
                sidecar.append(NoteSidecarStyle(text: span.text, occurrence: occurrence, color: span.color, size: span.size))
            }
        }
        return NoteBody(markdown: markdown, sidecar: sidecar)
    }

    // MARK: - 导出（给"导出 .md 文件"用，必须报降级）

    public struct ExportResult: Equatable, Sendable {
        public var markdown: String
        /// 导出后**一定会丢**的东西（人要看得到，而不是自己发现）。
        public var degradations: [String]
    }

    public static func exportMarkdown(_ body: NoteBody) -> ExportResult {
        var degradations: [String] = []
        for style in body.sidecar {
            var lost: [String] = []
            if let color = style.color { lost.append(LocalizedStrings.format(.noteLostColor, language: .simplifiedChinese, color)) }
            if let size = style.size { lost.append(LocalizedStrings.format(.noteLostSize, language: .simplifiedChinese, String(size))) }
            if !lost.isEmpty {
                degradations.append(LocalizedStrings.format(.noteExportDegraded, language: .simplifiedChinese, style.text, lost.joined(separator: " / ")))
            }
        }
        // 导出的是**权威源本身**（不重排、不美化）：AI 写进来的排版不该被我们改掉。
        return ExportResult(markdown: body.markdown, degradations: degradations)
    }
}
