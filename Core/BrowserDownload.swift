import Foundation

/// 浏览器下载的落盘命名与目标解析（FR-EDIT-34）。
///
/// 为什么单独一层：**"文件叫什么名字、落在哪"全是纯逻辑**，而它错起来的后果不轻 ——
/// 服务器给的 `Content-Disposition` 文件名不可信，里面可能有 `../`（写穿授权目录）、
/// 控制字符、或干脆是空的；而"直接覆盖同名文件"会让用户丢数据。这些判断放进 Core 才能单测，
/// 引擎侧只负责把 WebKit 给的建议名与授权目录交进来。
///
/// **落地目录只能是用户显式授权的目录**（与 FR-AI-08 同一套 `SecureDirectoryAccess`）：
/// 沙箱里往别处写既写不进去，也会绕开"不硬编码路径"这条纪律。没授权就**拒绝并说明**，
/// 不偷偷落到容器里。
public enum BrowserDownload {

    public enum Destination: Equatable, Sendable {
        case ready(URL)
        case refused(reason: String)

        public var url: URL? {
            if case .ready(let url) = self { return url }
            return nil
        }
    }

    /// 服务器建议的文件名 → 安全文件名。
    ///
    /// 规则（每条都对应一种真实见过的坏输入）：
    /// - 只取最后一段路径（`../../etc/passwd` → `passwd`、`C:\\tmp\\a.txt` → `a.txt`）；
    /// - 去掉控制字符与路径分隔符（文件名里的 `\0`、换行会被文件系统或界面当怪东西）；
    /// - 去掉首尾空白与结尾的点（Windows 语义里 `name.` 不可用，而 macOS 上它很坑）；
    /// - 全是点 / 空 → `download`（`..` 与 `.` 都是路径语义，不能当文件名）；
    /// - 限长：保留扩展名，主名截到 80 字符（超长名在多数文件系统上会被截断成不可预期的东西）。
    public static func sanitizeFilename(_ raw: String) -> String {
        let lastSegment = raw
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init) ?? ""

        var cleaned = ""
        for scalar in lastSegment.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F { continue }
            cleaned.unicodeScalars.append(scalar)
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasSuffix(".") { cleaned.removeLast() }
        if cleaned.isEmpty || cleaned.allSatisfy({ $0 == "." }) { return "download" }

        // 限长：扩展名整体保留（不超过 16 字符），主名截断。
        let url = URL(fileURLWithPath: cleaned)
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        if base.count <= 80, ext.count <= 16 { return cleaned }
        let trimmedExt = String(ext.prefix(16))
        let trimmedBase = String(base.prefix(80))
        let head = trimmedBase.isEmpty ? "download" : trimmedBase
        return trimmedExt.isEmpty ? head : "\(head).\(trimmedExt)"
    }

    /// 解析落盘目标：授权目录 + 安全文件名 + **不覆盖已有文件**（同名时自动 `-1`、`-2`…）。
    ///
    /// - Parameter fileExists: 注入的判断（测试里给假实现，真机上传 `FileManager.fileExists`）。
    /// - Parameter maximumAttempts: 同名后缀尝试上限；超了拒绝 —— 与其无限试，不如说清楚。
    public static func destination(
        suggestedFilename: String,
        directory: URL,
        fileExists: (URL) -> Bool,
        maximumAttempts: Int = 999
    ) -> Destination {
        let name = sanitizeFilename(suggestedFilename)
        let candidate = directory.appendingPathComponent(name)
        if !fileExists(candidate) { return .ready(candidate) }

        let url = URL(fileURLWithPath: name)
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        for index in 1...max(1, maximumAttempts) {
            let next = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            let candidate = directory.appendingPathComponent(next)
            if !fileExists(candidate) { return .ready(candidate) }
        }
        return .refused(reason: "目录里同名文件太多（已试到 \(maximumAttempts) 个），没有可用的文件名")
    }

    /// 写进外发日志的补充说明：**只记文件名与结果**，不记下载内容。
    public static func logDetail(filename: String, outcome: String) -> String {
        "下载 \(sanitizeFilename(filename))：\(outcome)"
    }

    /// 没授权目录时的可读原因（界面直接显示）。
    public static let noDirectoryReason = "下载需要先指定一个授权目录（与数据任务导出用的是同一个），否则文件写不出去"
}
