import Foundation

/// DEFLATE 解压（RFC 1951）与 zlib 包装（RFC 1950）识别 —— 纯 Swift、零依赖。
///
/// 为什么自己写而不引库：
/// 1. **平台中立**：Core 要能在 Linux 侧一起编译，而系统 zlib 在两边的模块名与链接方式都不同
///    （Darwin 走 `Compression`/`libz`，Linux 走 `CZlib`），引任何一个都会把 Core 钉在某个平台上；
/// 2. **不引第三方**：这与 FR-RES-14 里"自写 xlsx 写入器"是同一条纪律 —— 能自己写对的东西，
///    不为了省几百行代码去背一个依赖；
/// 3. **可验证**：解压的正确性用**另一份实现**（Python 的 zlib）压出来的数据当输入来验，
///    不是自己压自己解（`Tests/InflateTests.swift` 与 `Scripts/test-xlsx-import.sh`）。
///
/// 口径：**只解压，不压缩**（读 xlsx 只需要解）。实现按 RFC 1951 的三类块全支持：
/// stored（0）/ 固定 Huffman（1）/ 动态 Huffman（2）。
public enum Inflate {

    public enum Failure: Error, Equatable, LocalizedError {
        case truncated
        case unsupportedBlockType(Int)
        case storedLengthMismatch
        case invalidHuffmanCode
        case invalidDistance(Int)
        case invalidCodeLengths
        case incompleteBlock

        public var errorDescription: String? {
            switch self {
            case .truncated: return "压缩数据不完整（提前结束）。"
            case .unsupportedBlockType(let type): return "不支持的 DEFLATE 块类型：\(type)。"
            case .storedLengthMismatch: return "存储块的长度校验（LEN/NLEN）不通过。"
            case .invalidHuffmanCode: return "Huffman 编码非法（码表损坏）。"
            case .invalidDistance(let distance): return "回溯距离超出已输出范围：\(distance)。"
            case .invalidCodeLengths: return "动态 Huffman 的码长表非法。"
            case .incompleteBlock: return "DEFLATE 流在块结束前就没了。"
            }
        }
    }

    /// 解压。自动识别 zlib 包装（RFC 1950 的两字节头 + 尾部 4 字节 Adler-32）。
    ///
    /// 为什么两种都要认：ZIP 条目里是**裸 deflate**，而 `.xlsx` 之外的一些格式（如某些 OOXML
    /// 变体、`.zz`）是 zlib 包装。判据用 zlib 头的两条硬约束（CM = 8、头两字节 mod 31 == 0），
    /// 误判概率极低；**不做**的是猜 gzip（那是 RFC 1952，另一套头）。
    public static func decompress(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        if isZlibWrapped(bytes) {
            // 6 = 2 字节头 + 4 字节 Adler-32。
            guard bytes.count > 6 else { throw Failure.truncated }
            let body = Array(bytes[2..<(bytes.count - 4)])
            return Data(try inflateRaw(body))
        }
        return Data(try inflateRaw(bytes))
    }

    /// zlib 头判据：CM == 8 且 `(CMF << 8 | FLG) % 31 == 0`（RFC 1950 §2.2）。
    static func isZlibWrapped(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 2 else { return false }
        let cmf = Int(bytes[0])
        let flg = Int(bytes[1])
        return (cmf & 0x0F) == 8 && ((cmf << 8) | flg) % 31 == 0
    }

    /// 裸 DEFLATE（无 zlib 包装）。
    public static func inflateRaw(_ bytes: [UInt8]) throws -> [UInt8] {
        var reader = BitReader(bytes)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count * 4)

        while true {
            let isFinal = try reader.readBits(1) == 1
            let type = try reader.readBits(2)
            switch type {
            case 0:
                try copyStoredBlock(reader: &reader, output: &output)
            case 1:
                let tables = try fixedTables()
                try decodeBlock(reader: &reader, output: &output, literals: tables.literals, distances: tables.distances)
            case 2:
                let tables = try dynamicTables(reader: &reader)
                try decodeBlock(reader: &reader, output: &output, literals: tables.literals, distances: tables.distances)
            default:
                throw Failure.unsupportedBlockType(type)
            }
            if isFinal { break }
        }
        return output
    }

    // MARK: - 位读取（DEFLATE 是 LSB-first）

    struct BitReader {
        private let bytes: [UInt8]
        private var byteIndex = 0
        private var bitIndex = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func readBit() throws -> Int {
            guard byteIndex < bytes.count else { throw Failure.truncated }
            let bit = (Int(bytes[byteIndex]) >> bitIndex) & 1
            bitIndex += 1
            if bitIndex == 8 {
                bitIndex = 0
                byteIndex += 1
            }
            return bit
        }

        /// 读 `count` 位小端序（先读到的位是低位）。
        mutating func readBits(_ count: Int) throws -> Int {
            guard count > 0 else { return 0 }
            var value = 0
            for shift in 0..<count {
                value |= try readBit() << shift
            }
            return value
        }

        /// 对齐到字节边界（stored 块用）。
        mutating func alignToByte() {
            if bitIndex != 0 {
                bitIndex = 0
                byteIndex += 1
            }
        }

        mutating func readBytes(_ count: Int) throws -> [UInt8] {
            guard count >= 0 else { throw Failure.truncated }
            guard byteIndex + count <= bytes.count else { throw Failure.truncated }
            let slice = Array(bytes[byteIndex..<(byteIndex + count)])
            byteIndex += count
            return slice
        }

        var isExhausted: Bool { byteIndex >= bytes.count }
    }

    // MARK: - 块

    private static func copyStoredBlock(reader: inout BitReader, output: inout [UInt8]) throws {
        reader.alignToByte()
        let header = try reader.readBytes(4)
        let length = Int(header[0]) | Int(header[1]) << 8
        let complement = Int(header[2]) | Int(header[3]) << 8
        guard (length ^ 0xFFFF) == complement else { throw Failure.storedLengthMismatch }
        output.append(contentsOf: try reader.readBytes(length))
    }

    private static func decodeBlock(
        reader: inout BitReader,
        output: inout [UInt8],
        literals: Huffman,
        distances: Huffman
    ) throws {
        while true {
            let symbol = try decodeSymbol(reader: &reader, table: literals)
            if symbol < 256 {
                output.append(UInt8(symbol))
                continue
            }
            if symbol == 256 { return }

            let lengthIndex = symbol - 257
            guard lengthIndex < lengthBase.count else { throw Failure.invalidCodeLengths }
            let length = lengthBase[lengthIndex] + (try reader.readBits(lengthExtra[lengthIndex]))

            let distanceSymbol = try decodeSymbol(reader: &reader, table: distances)
            guard distanceSymbol < distanceBase.count else { throw Failure.invalidDistance(distanceSymbol) }
            let distance = distanceBase[distanceSymbol] + (try reader.readBits(distanceExtra[distanceSymbol]))

            guard distance > 0, distance <= output.count else { throw Failure.invalidDistance(distance) }
            let start = output.count - distance
            // 逐字节复制：`distance` 可能小于 `length`（重叠复制），这是 DEFLATE 的正常用法
            // （它就是靠这个把重复串展开的），因此不能整段 memcpy。
            for offset in 0..<length {
                output.append(output[start + offset])
            }
        }
    }

    // MARK: - Huffman

    struct Huffman {
        var counts: [Int]
        var symbols: [Int]
        var maxBits: Int
    }

    /// 由码长表构造规范 Huffman（puff 的做法：先数每档码长数量，再按码长填符号）。
    static func buildHuffman(lengths: [Int]) throws -> Huffman {
        let maxBits = lengths.max() ?? 0
        var counts = [Int](repeating: 0, count: max(1, maxBits + 1))
        for length in lengths where length > 0 {
            guard length < counts.count else { throw Failure.invalidCodeLengths }
            counts[length] += 1
        }

        // 完整性检查（RFC 1951 §3.2.7）：不能有"未用完的码"。
        var left = 1
        for bits in 1...max(1, maxBits) {
            left <<= 1
            left -= counts[bits]
            if left < 0 { throw Failure.invalidCodeLengths }
        }

        var offsets = [Int](repeating: 0, count: max(1, maxBits + 2))
        for bits in 1...max(1, maxBits) {
            offsets[bits + 1] = offsets[bits] + counts[bits]
        }
        var symbols = [Int](repeating: 0, count: lengths.count)
        for (symbol, length) in lengths.enumerated() where length > 0 {
            symbols[offsets[length]] = symbol
            offsets[length] += 1
        }
        return Huffman(counts: counts, symbols: symbols, maxBits: maxBits)
    }

    private static func decodeSymbol(reader: inout BitReader, table: Huffman) throws -> Int {
        var code = 0
        var first = 0
        var index = 0
        for length in 1...max(1, table.maxBits) {
            code |= try reader.readBit()
            let count = table.counts[length]
            if code - first < count {
                return table.symbols[index + (code - first)]
            }
            index += count
            first = (first + count) << 1
            code <<= 1
        }
        throw Failure.invalidHuffmanCode
    }

    /// 固定 Huffman（RFC 1951 §3.2.6）。
    static func fixedTables() throws -> (literals: Huffman, distances: Huffman) {
        var literalLengths = [Int](repeating: 0, count: 288)
        for symbol in 0...143 { literalLengths[symbol] = 8 }
        for symbol in 144...255 { literalLengths[symbol] = 9 }
        for symbol in 256...279 { literalLengths[symbol] = 7 }
        for symbol in 280...287 { literalLengths[symbol] = 8 }
        let distanceLengths = [Int](repeating: 5, count: 30)
        return (try buildHuffman(lengths: literalLengths), try buildHuffman(lengths: distanceLengths))
    }

    /// 动态 Huffman（RFC 1951 §3.2.7）。
    static func dynamicTables(reader: inout BitReader) throws -> (literals: Huffman, distances: Huffman) {
        let literalCount = try reader.readBits(5) + 257
        let distanceCount = try reader.readBits(5) + 1
        let codeLengthCount = try reader.readBits(4) + 4

        var codeLengthLengths = [Int](repeating: 0, count: 19)
        for index in 0..<codeLengthCount {
            codeLengthLengths[codeLengthOrder[index]] = try reader.readBits(3)
        }
        let codeLengthTable = try buildHuffman(lengths: codeLengthLengths)

        var lengths: [Int] = []
        lengths.reserveCapacity(literalCount + distanceCount)
        while lengths.count < literalCount + distanceCount {
            let symbol = try decodeSymbol(reader: &reader, table: codeLengthTable)
            switch symbol {
            case 0...15:
                lengths.append(symbol)
            case 16:
                guard let previous = lengths.last else { throw Failure.invalidCodeLengths }
                let repeatCount = try reader.readBits(2) + 3
                lengths.append(contentsOf: [Int](repeating: previous, count: repeatCount))
            case 17:
                lengths.append(contentsOf: [Int](repeating: 0, count: try reader.readBits(3) + 3))
            case 18:
                lengths.append(contentsOf: [Int](repeating: 0, count: try reader.readBits(7) + 11))
            default:
                throw Failure.invalidCodeLengths
            }
            guard lengths.count <= literalCount + distanceCount else { throw Failure.invalidCodeLengths }
        }

        let literalLengths = Array(lengths[0..<literalCount])
        let distanceLengths = Array(lengths[literalCount..<(literalCount + distanceCount)])
        // 全零的 distance 表是合法的（只出现字面量的块）；补一个长度 1 的空表避免建表失败。
        let distances = distanceLengths.allSatisfy { $0 == 0 }
            ? try buildHuffman(lengths: [1, 1])
            : try buildHuffman(lengths: distanceLengths)
        return (try buildHuffman(lengths: literalLengths), distances)
    }

    /// 动态块码长表用的特殊顺序（RFC 1951 §3.2.7）。
    static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    static let lengthBase = [
        3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
        35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
    ]
    static let lengthExtra = [
        0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
        3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
    ]
    static let distanceBase = [
        1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
        257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
    ]
    static let distanceExtra = [
        0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
        7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
    ]
}
