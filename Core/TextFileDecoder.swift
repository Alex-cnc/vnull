import Foundation

/// 导入侧的文件文本解码（FR-IO-03 的对称面）。
///
/// 为什么不能只按 UTF-8 读：中文 Windows 上从 Excel / WPS **另存为 CSV** 得到的是
/// **本地代码页**（ANSI / GBK，GB18030 的超集关系里它是子集）—— 只按 UTF-8 解，
/// 要么直接失败（`String(contentsOf:encoding:.utf8)` 抛错），要么在某些宽松路径上
/// 变成一串替换字符。也就是说：我们自己能"导出 GB18030"，就更该能"读回 GB18030"，
/// 否则这个兼容只做了一半。
///
/// 判定顺序与理由：
/// 1. **有 UTF-8 BOM 就是 UTF-8** —— 这是文件自己声明的，不必猜；
/// 2. 没有 BOM 时**严格**试 UTF-8（`String(data:encoding:)` 对非法序列返回 nil）——
///    GBK 的双字节序列里，第二字节常落在 ASCII 区，但整体构成合法 UTF-8 的概率很低，
///    所以这一步几乎不会误判；
/// 3. 都失败才落到 GB18030（GBK / GB2312 的超集，覆盖旧文件里的常见字符）。
///
/// **已知边界（不夸大）**：GB18030 的编码器是全 Unicode（四字节序列），但**解码**判决
/// 依赖上面这套启发式 —— 一份"恰好也是合法 UTF-8"的 GBK 文件会被当成 UTF-8（现实里
/// 极罕见，出现时表现为个别字错）。这里不引入统计检测（那要读两份代码页表去打分），
/// 因为对"数据库客户端导入自己导出的文件"这个主场景，BOM + 严格 UTF-8 已经够用。
public enum TextFileDecoder {

    /// 解码结果：文本 + 实际使用的编码。
    public struct Decoded: Equatable, Sendable {
        public var text: String
        public var encoding: ResultExportEncoding
        /// 文件开头是否带 UTF-8 BOM。
        public var hadByteOrderMark: Bool

        /// 是否走了**回退**（不是 UTF-8）—— 界面 / CLI 据此如实提示一句。
        public var isFallback: Bool { encoding != .utf8 }
    }

    /// 从字节解出文本。两种编码都解不出来时抛 `TextFileDecodingError`。
    public static func decode(_ data: Data) throws -> Decoded {
        let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]
        if data.starts(with: utf8BOM) {
            guard let text = String(data: data.dropFirst(utf8BOM.count), encoding: .utf8) else {
                throw TextFileDecodingError.unreadable
            }
            return Decoded(text: text, encoding: .utf8, hadByteOrderMark: true)
        }

        if let text = String(data: data, encoding: .utf8) {
            return Decoded(text: text, encoding: .utf8, hadByteOrderMark: false)
        }

        if let encoding = ResultExportEncoding.gb18030.foundationEncoding,
           let text = String(data: data, encoding: encoding) {
            return Decoded(text: text, encoding: .gb18030, hadByteOrderMark: false)
        }

        throw TextFileDecodingError.unreadable
    }

    /// 便捷入口：直接读文件。
    public static func decode(contentsOf url: URL) throws -> Decoded {
        try decode(try Data(contentsOf: url))
    }
}

/// 导入侧解码失败。
public enum TextFileDecodingError: Error, Equatable, LocalizedError {
    /// 按 UTF-8 与 GB18030 都解不出文本（多半是二进制文件或编码不在支持范围）。
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .unreadable:
            return "这个文件既不是 UTF-8 也不是 GB18030 文本（可能是二进制文件，或用了别的编码）。"
        }
    }
}
