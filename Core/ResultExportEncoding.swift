import Foundation

/// 导出文本的编码（FR-IO-07）。
///
/// 为什么需要它：CSV 是纯文本，**编码不由文件内容决定** —— 双击打开的人用什么编码解，
/// 决定了他看到中文还是一堆乱码。UTF-8 带 BOM 对现代 Excel / WPS 是足够的（BOM 就是
/// 用来告诉它们"这是 UTF-8"的），但中文 Windows 上仍有一批工具链（旧版 Office、
/// 部分自研导表程序、`cmd` 里的 `type`）按本地代码页（CP936 / GBK）解 —— 对它们，
/// UTF-8 中文必然是乱码，而 GB18030 才是"双击就能看"的那个。
///
/// 两种编码的取舍写明在这里，而不是让调用方自己猜：
/// - `.utf8`：**默认**。带 BOM，现代 Excel / WPS / Numbers / LibreOffice 都认；
/// - `.gb18030`：GBK / GB2312 的**超集**（GBK 能表示的它都能表示，反之不成立），
///   不带 BOM（GB18030 没有 BOM 的概念，塞 BOM 反而会变成第一个单元格里的乱码字符）。
public enum ResultExportEncoding: String, CaseIterable, Sendable {
    case utf8
    case gb18030

    /// 界面与文档共用的显示名。
    public var displayName: String {
        switch self {
        case .utf8: return "UTF-8（带 BOM）"
        case .gb18030: return "GB18030（中文 Windows 的 Excel / WPS）"
        }
    }

    /// 命令行 / 日志里的短名。
    public var shortName: String {
        switch self {
        case .utf8: return "UTF-8"
        case .gb18030: return "GB18030"
        }
    }

    /// 写文件前要落的字节序标记；GB18030 没有 BOM。
    ///
    /// 注意这里是**字节**层面的 BOM，而不是往字符串前面放一个 `U+FEFF` 字符：
    /// 后者在 GB18030 下会被当成真实字符编码出去（GB18030 里 `U+FEFF` 不是"标记"），
    /// 用户打开文件会在第一格看到一个不可见字符。
    public var byteOrderMark: [UInt8] {
        switch self {
        case .utf8: return [0xEF, 0xBB, 0xBF]
        case .gb18030: return []
        }
    }

    /// 解析命令行 / 配置里的编码名。
    ///
    /// 别名收得宽一些是有意的：用户嘴里说的是「GBK」「ANSI」「中文编码」，而
    /// **GB18030 是它们的超集** —— 用超集编码输出的文件，按 GBK / GB2312 解也能读出
    /// 其中的 GBK 子集，所以这三种说法落到同一个实现上不会出错，只是会把 GB18030
    /// 独有的字也写出来（这正是我们想要的）。
    public static func parse(_ raw: String) -> ResultExportEncoding? {
        switch raw.lowercased().trimmingCharacters(in: .whitespaces) {
        case "utf8", "utf-8", "utf_8": return .utf8
        case "gb18030", "gbk", "gb2312", "cp936", "ansi", "gb-18030": return .gb18030
        default: return nil
        }
    }

    /// Foundation 里的编码。平台不支持时返回 nil（见 `isAvailable`）。
    var foundationEncoding: String.Encoding? {
        switch self {
        case .utf8: return .utf8
        case .gb18030:
            // 这个数值就是 `CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000)`
            // 的返回值（`0x8000_0000 | 0x0632`，实测打印核对过）。
            //
            // 为什么不直接调那个函数：它要传 `CFStringEncoding`，而 `CF*` 是 Core 里
            // 明令禁止的平台专属类型（`Scripts/check-core-portability.py`）—— Core 要能在
            // Linux 侧一起编译。代价是这个魔数不可读，所以用一个**能力探测**兜底：
            // 编码器不存在时 `isAvailable` 为 false，调用方拿到的是可读错误而不是空文件。
            let encoding = String.Encoding(rawValue: 0x8000_0000 | 0x0632)
            return "测".data(using: encoding) == nil ? nil : encoding
        }
    }

    /// 当前平台上这个编码能不能用。
    public var isAvailable: Bool { foundationEncoding != nil }

    /// 把文本编成字节（**含 BOM**）。一次性导出用这个。
    ///
    /// 失败是**抛错**而不是丢字符：若按"能编的先编、编不了的变 `?`"处理，用户会拿到一个
    /// "看起来成功、数据已经错了"的文件 —— 导出这条路上，宁可失败也不要静默改数据。
    ///
    /// **实测订正（2026-09-24）**：写这段时我以为 GB18030 表达不了 emoji，实测**不成立** ——
    /// GB18030 是**全 Unicode** 编码（`😀` → `94 39 FC 36`，四字节序列），生僻字、
    /// 罗马数字、欧元符号都能编且往返一致。因此 `unencodableCharacter` 在本机是**防御性**
    /// 分支，触发条件只剩"某个平台提供的表更窄（例如只有 GBK）"或输入本身损坏。
    /// 检测器本身的正确性用 ASCII 去测（`Tests/ResultExportEncodingTests.swift`），
    /// 而不是留一个没人跑过的分支。
    public func encode(_ text: String) throws -> Data {
        let body = try encodeBody(text)
        guard !byteOrderMark.isEmpty else { return body }
        var data = Data(byteOrderMark)
        data.append(body)
        return data
    }

    /// 把文本编成字节（**不含 BOM**）。
    ///
    /// 分块写入（`ResultStreamWriter`）必须用它：BOM 是**整份文件一个**的标记，
    /// 若每个分块都带一次，文件中间会周期性冒出 `EF BB BF` —— 本轮实测踩到
    /// （流式 CSV 比一次性多出 9 字节，正是被插进每行的 BOM）。BOM 由调用方在
    /// 开头写一次（`byteOrderMark`）。
    public func encodeBody(_ text: String) throws -> Data {
        guard let encoding = foundationEncoding else {
            throw ResultExportEncodingError.encodingUnavailable(self)
        }
        guard let body = text.data(using: encoding) else {
            throw ResultExportEncodingError.unencodableCharacter(
                encoding: self,
                character: Self.firstUnencodableCharacter(in: text, encoding: encoding) ?? "?"
            )
        }
        return body
    }

    /// 按本编码解回文本（自检 / 对照用）。
    func decode(_ data: Data) throws -> String {
        guard let encoding = foundationEncoding else {
            throw ResultExportEncodingError.encodingUnavailable(self)
        }
        // UTF-8 路径上 BOM 是合法字符（会被解成 `U+FEFF`），先剥掉再比。
        var body = data
        if !byteOrderMark.isEmpty, body.starts(with: byteOrderMark) {
            body = body.dropFirst(byteOrderMark.count)
        }
        guard let text = String(data: body, encoding: encoding) else {
            throw ResultExportEncodingError.malformedBytes(self)
        }
        return text
    }

    /// 找出第一个编不出来的字符（**只在失败路径上跑**，不拖慢正常导出）。
    ///
    /// 抽成 `static` 是为了能被单测直接喂一个**故意很窄**的编码（ASCII），
    /// 从而在"本机编码器从不失败"的前提下仍然钉住这段逻辑。
    static func firstUnencodableCharacter(in text: String, encoding: String.Encoding) -> String? {
        for character in text where String(character).data(using: encoding) == nil {
            return String(character)
        }
        return nil
    }
}

/// 导出编码相关的失败（FR-IO-07）。
public enum ResultExportEncodingError: Error, Equatable, LocalizedError {
    /// 该格式不支持这个编码（目前只有 CSV 支持非 UTF-8）。
    case notApplicableToFormat(encoding: ResultExportEncoding, format: ResultExportFormat)
    /// 当前平台的 Foundation 没有这个编码器。
    case encodingUnavailable(ResultExportEncoding)
    /// 文本里有该编码表达不了的字符（例如 GB18030 下的 emoji）。
    case unencodableCharacter(encoding: ResultExportEncoding, character: String)
    /// 用该编码解不回来（自检用）。
    case malformedBytes(ResultExportEncoding)

    public var errorDescription: String? {
        switch self {
        case .notApplicableToFormat(let encoding, let format):
            return "\(format.fileExtension.uppercased()) 固定使用 UTF-8，\(encoding.shortName) 只对 CSV 生效。"
        case .encodingUnavailable(let encoding):
            return "当前系统不支持 \(encoding.shortName) 编码，无法按该编码导出（已中止，未写出文件）。"
        case .unencodableCharacter(let encoding, let character):
            return "结果里有 \(encoding.shortName) 表达不了的字符「\(character)」—— 请改用 UTF-8 导出（未写出文件）。"
        case .malformedBytes(let encoding):
            return "这些字节不是合法的 \(encoding.shortName) 文本。"
        }
    }
}
