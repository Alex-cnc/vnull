import Foundation

/// 单元格 / 单行的**值检查**（FR-DATA-05）：宽表竖排看、长 JSON 格式化看。
///
/// 为什么单独做一层：这两件事都有"看着对、其实错"的坑 ——
/// ① JSON 识别太宽会把 `123`、`{不是 JSON}` 也当 JSON（然后格式化失败或原样显示），
///    太严又会让 `[...]` 这种数组漏掉；
/// ② 长值截断如果不把**原始长度**一起说出来，用户会以为拿到的就是全部；
/// ③ NULL 与空字符串必须继续区分（与 FR-RES-04 同一纪律）。
///
/// 因此这里只做**纯计算**：判定类型、给出展示文本与元信息。界面只负责排版。
public enum CellInspector {

    /// 值的形态。
    public enum Shape: Equatable, Sendable {
        case null
        case empty
        case jsonObject
        case jsonArray
        /// 二进制（`bytea` 的十六进制文本形态：`\x48656c6c6f`）。
        case binary(byteCount: Int)
        case scalarJSON
        case text
    }

    /// 一个值的完整描述。
    public struct Value: Equatable, Sendable {
        public var shape: Shape
        /// 展示用文本（JSON 已美化、二进制已摘要）。
        public var display: String
        /// 原始文本长度（**字符数**：用户看到的是字符，不是字节）。
        public var originalCharacterCount: Int
        /// 原始文本的 UTF-8 字节数（与"占多少空间"相关）。
        public var originalByteCount: Int
        /// 展示文本被截断了吗。
        public var isTruncated: Bool
        /// 原始文本的行数（1 起）；长 JSON 在竖排视图里想知道"它有多少行"。
        public var lineCount: Int

        public init(
            shape: Shape,
            display: String,
            originalCharacterCount: Int,
            originalByteCount: Int,
            isTruncated: Bool,
            lineCount: Int
        ) {
            self.shape = shape
            self.display = display
            self.originalCharacterCount = originalCharacterCount
            self.originalByteCount = originalByteCount
            self.isTruncated = isTruncated
            self.lineCount = lineCount
        }

        /// 一句话摘要，供列表 / 状态栏用：`JSON 对象 · 42 字符 · 6 行`。
        ///
        /// - Parameter language: 语言（R-45：这段文本会直接显示在行详情侧栏，固定中文会让
        ///   英文界面上冒出几个中文字）。默认中文，兼容既有调用点与 CLI。
        public func summary(language: AppLanguage = .simplifiedChinese) -> String {
            func text(_ key: LKey) -> String { LocalizedStrings.text(key, language: language) }
            var parts: [String] = []
            switch shape {
            case .null: parts.append("NULL")
            case .empty: parts.append(text(.cellSummaryEmpty))
            case .jsonObject: parts.append(text(.cellSummaryJsonObject))
            case .jsonArray: parts.append(text(.cellSummaryJsonArray))
            case .binary(let bytes): parts.append(LocalizedStrings.format(.cellSummaryBinary, language: language, bytes))
            case .scalarJSON: parts.append(text(.cellSummaryScalarJSON))
            case .text: parts.append(text(.cellSummaryText))
            }
            if shape != .null && shape != .empty {
                parts.append(LocalizedStrings.format(.cellSummaryCharacters, language: language, originalCharacterCount))
                if lineCount > 1 {
                    parts.append(LocalizedStrings.format(.cellSummaryLines, language: language, lineCount))
                }
            }
            if isTruncated { parts.append(text(.cellSummaryTruncated)) }
            return parts.joined(separator: " · ")
        }
    }

    /// 竖排视图里的一行（列名 → 值）。
    public struct Field: Equatable, Sendable {
        public var columnName: String
        public var typeName: String
        public var value: Value

        public init(columnName: String, typeName: String, value: Value) {
            self.columnName = columnName
            self.typeName = typeName
            self.value = value
        }
    }

    /// 单行详情：按**列顺序**给出每个字段（竖排看宽表）。
    public static func row(
        columns: [ColumnMeta],
        row: [String?],
        displayLimit: Int = defaultDisplayLimit
    ) -> [Field] {
        columns.enumerated().map { index, column in
            let raw = row.indices.contains(index) ? row[index] : nil
            return Field(
                columnName: column.name,
                typeName: column.typeName,
                value: inspect(raw, displayLimit: displayLimit)
            )
        }
    }

    /// 默认展示上限。长 JSON 常见几千字符，超过就截断 —— 但**必须**同时告诉用户原始长度。
    public static let defaultDisplayLimit = 4_000

    /// 检查一个单元格值。
    public static func inspect(_ raw: String?, displayLimit: Int = defaultDisplayLimit) -> Value {
        guard let raw else {
            return Value(shape: .null, display: "NULL", originalCharacterCount: 0,
                         originalByteCount: 0, isTruncated: false, lineCount: 0)
        }
        if raw.isEmpty {
            return Value(shape: .empty, display: "", originalCharacterCount: 0,
                         originalByteCount: 0, isTruncated: false, lineCount: 1)
        }

        let characters = raw.count
        let bytes = raw.utf8.count
        let lines = raw.components(separatedBy: .newlines).count

        // 二进制：PostgreSQL 的 `bytea` 文本形态是 `\x` + 偶数个十六进制字符。
        if let binary = binaryByteCount(raw) {
            let preview = String(raw.prefix(32))
            let display = raw.count > 32 ? "\(preview)…" : preview
            return Value(shape: .binary(byteCount: binary), display: display,
                         originalCharacterCount: characters, originalByteCount: bytes,
                         isTruncated: raw.count > 32, lineCount: lines)
        }

        // JSON：先看**首字符**再交给解析器 —— 不靠"包含花括号"这种宽判据。
        if let jsonShape = jsonShape(raw), let pretty = prettyJSON(raw) {
            let truncated = pretty.count > displayLimit
            return Value(
                shape: jsonShape,
                display: truncated ? String(pretty.prefix(displayLimit)) + "…" : pretty,
                originalCharacterCount: characters,
                originalByteCount: bytes,
                isTruncated: truncated,
                lineCount: lines
            )
        }

        // 普通文本：超长也截断，并如实标注。
        let truncated = raw.count > displayLimit
        return Value(
            shape: .text,
            display: truncated ? String(raw.prefix(displayLimit)) + "…" : raw,
            originalCharacterCount: characters,
            originalByteCount: bytes,
            isTruncated: truncated,
            lineCount: lines
        )
    }

    /// `\x48656c6c6f` → 5 字节；不是这种形态返回 nil。
    static func binaryByteCount(_ text: String) -> Int? {
        guard text.hasPrefix("\\x") else { return nil }
        let hex = text.dropFirst(2)
        guard !hex.isEmpty, hex.count % 2 == 0, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hex.count / 2
    }

    /// JSON 形态判定：只认「以 `{` / `[` / 引号 / 数字 / `true` / `false` / `null` 开头
    /// **且真能被解析**」的值。
    ///
    /// 为什么不能只看首字符：`{不是 JSON}`、`[未闭合` 在真实数据里很常见（尤其是半截日志），
    /// 把它们当 JSON 会显示一句解析错误，还不如按文本原样显示。
    static func jsonShape(_ text: String) -> Shape? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let first = trimmed.first else { return nil }

        let looksJSONLike: Bool
        switch first {
        case "{", "[", "\"": looksJSONLike = true
        case "t", "f", "n": looksJSONLike = ["true", "false", "null"].contains(trimmed)
        default: looksJSONLike = first.isNumber || first == "-"
        }
        guard looksJSONLike else { return nil }
        guard (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed])) != nil else {
            return nil
        }

        switch first {
        case "{": return .jsonObject
        case "[": return .jsonArray
        default: return .scalarJSON
        }
    }

    /// 美化 JSON。**键按字典序**：`JSONSerialization` 不保留原顺序，
    /// 与其让每次显示的顺序不稳定，不如固定成排序后的（对阅读也更友好）。
    static func prettyJSON(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return trimmed }

        // **只在容器上调用 `data(withJSONObject:)`**：它对顶层标量（字符串 / 数字 / null）
        // 会抛 **Objective-C 异常**（`Invalid top-level type in JSON write`）——`try?` 拦不住它，
        // 进程会直接崩。本轮实测踩到：`inspect("123")` 把测试进程打崩。
        // 标量本来也没什么可"美化"的，原样返回即可。
        guard JSONSerialization.isValidJSONObject(object) else { return trimmed }

        guard let pretty = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return trimmed }
        return String(data: pretty, encoding: .utf8) ?? trimmed
    }
}
