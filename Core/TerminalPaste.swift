import Foundation

/// 粘贴语义（FR-EDIT-29）：剪贴板里的文本要怎么变成发给 PTY 的字节。
///
/// ## 为什么单独抽出来
///
/// "粘贴"看起来是"把字符串写进去"，但有两处必须做对、且都能脱离图形界面验证：
///
/// 1. **括号粘贴（bracketed paste，SGR 2004）**。shell / vim / psql 打开这个模式后，
///    期望粘贴内容被包在 `ESC[200~ … ESC[201~` 之间 —— 这样它才知道"这些不是用户敲的"。
///    不包的话：vim 会按每行重新自动缩进（粘一段代码变成阶梯状），
///    某些 REPL 会把多行里的换行当成"逐行提交"，粘一段 SQL 就直接跑了。
/// 2. **换行符**。剪贴板里的换行在 macOS 上是 `\n`。终端惯例是**原样发送**：
///    PTY 的行规程默认开着 `ICRNL`，会把 CR 转成 NL；反过来把 LF 偷偷改成 CR
///    反而会在某些程序里出现"多一个空行"。所以这里不做任何转换（要改就得两边一起改）。
///
/// 这两条都是**纯逻辑**，所以放在 Core 里单测；视图只负责读剪贴板与调用。
public enum TerminalPaste {

    /// 括号粘贴的开始 / 结束标记（xterm 约定）。
    public static let startMarker = "\u{1B}[200~"
    public static let endMarker = "\u{1B}[201~"

    /// 把要粘贴的文本包成实际发送的字节。
    ///
    /// - Parameters:
    ///   - text: 剪贴板里的文本（原样，不做换行转换）。
    ///   - isBracketedPasteEnabled: 前台程序有没有开 SGR 2004（由 `TerminalScreen` 跟踪）。
    /// - Returns: 发给 PTY 的字节；空文本返回空数组（不发送任何东西，避免给程序塞一个空粘贴）。
    public static func payload(for text: String, isBracketedPasteEnabled: Bool) -> [UInt8] {
        guard !text.isEmpty else { return [] }
        guard isBracketedPasteEnabled else { return Array(text.utf8) }
        return Array((startMarker + text + endMarker).utf8)
    }
}
