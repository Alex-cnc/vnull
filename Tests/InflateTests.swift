import XCTest
@testable import DoyahCore

/// DEFLATE 解压（RFC 1951 / 1950）：三类块、重叠回溯、zlib 包装识别、损坏输入。
///
/// **测试向量全部由另一份实现生成**：下面的 base64 是 Python `zlib.compress(...)`（各压缩级别、
/// 含 level 0 的存储块）的输出，明文在断言里写死。也就是说这里验的是"我们能不能解开别人压的东西"，
/// 而不是"自己压自己解" —— 后者对 DEFLATE 这种规范明确的格式几乎没有信息量。
final class InflateTests: XCTestCase {

    private func decompress(_ base64: String) throws -> String {
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        return String(decoding: try Inflate.decompress(data), as: UTF8.self)
    }

    // MARK: - 三类块

    /// 存储块（BTYPE 00）：level 0 不压缩，直接搬运 —— 这条路径错了会丢整块数据。
    func testStoredBlock() throws {
        let expected = String(repeating: "Doyah 存储块测试 ", count: 8)
        let base64 = "eAEBsABP/0RveWFoIOWtmOWCqOWdl+a1i+ivlSBEb3lhaCDlrZjlgqjlnZfmtYvor5UgRG95YWgg5a2Y5YKo5Z2X5rWL6K+VIERveWFoIOWtmOWCqOWdl+a1i+ivlSBEb3lhaCDlrZjlgqjlnZfmtYvor5UgRG95YWgg5a2Y5YKo5Z2X5rWL6K+VIERveWFoIOWtmOWCqOWdl+a1i+ivlSBEb3lhaCDlrZjlgqjlnZfmtYvor5UgPf1myQ=="
        XCTAssertEqual(try decompress(base64), expected)
    }

    /// 固定 / 动态 Huffman（level 1 与 level 9）：短字符串在各级别下走的分支不同。
    func testHuffmanBlocks() throws {
        let vectors: [(String, String)] = [
            ("hello_L1", "eAHLSM3JyddRSElNy0ksSVUEACwEBVc="),
            ("hello_L6", "eJzLSM3JyddRSElNy0ksSVUEACwEBVc="),
            ("hello_L9", "eNrLSM3JyddRSElNy0ksSVUEACwEBVc="),
        ]
        for (name, base64) in vectors {
            XCTAssertEqual(try decompress(base64), "hello, deflate!", "\(name) 解压结果不对")
        }
    }

    /// 中文 + emoji：多字节 UTF-8 在解压后必须原样（字节层面对齐）。
    func testUTF8Payload() throws {
        XCTAssertEqual(try decompress("eJwBGQDm/+S4reaWh+a1i+ivle+8jGVtb2ppIPCfmIDdMw+x"), "中文测试，emoji 😀")
        XCTAssertEqual(try decompress("eAEBGQDm/+S4reaWh+a1i+ivle+8jGVtb2ppIPCfmIDdMw+x"), "中文测试，emoji 😀")
    }

    /// 重复串（level 1 与 9）：靠**回溯复制**展开，且 `distance < length` 的重叠复制是 DEFLATE 的常规用法。
    func testBackReferenceExpansion() throws {
        // 明文是 `abcabcabc` × 200 = 1800 字节（与 Python 生成向量时用的输入一致）。
        let expected = String(repeating: "abcabcabc", count: 200)
        for base64 in ["eAFLTEpOHEWjITAaAqMhMBoCoyEwUkMAAGUosS8=", "eJxLTEpOHEWjaBSNolE0ikYqAgBlKLEv", "eNpLTEpOHEWjaBSNolE0ikYqAgBlKLEv"] {
            XCTAssertEqual(try decompress(base64), expected)
        }
        // 单字符长串：distance = 1、length 最大 258，连续重叠复制。
        XCTAssertEqual(try decompress("eNpLTBwFxAIA2KhxrQ=="), String(repeating: "a", count: 300))
    }

    /// 动态 Huffman 为主的中等负载（1.2 KB 明文压到 ~200 字节）：实际 xlsx 条目走的就是这条路。
    func testDynamicHuffmanPayload() throws {
        let expected = String(decoding: (0..<120).map { "行\($0 % 7),值\($0 % 13);" }.joined().utf8, as: UTF8.self)
        let base64 = "eNrt0zsNAgAQBFFDFPcHgjkEYAIf2CFBBjlIZlsE0G01ec2+7jc7PK8Pu7zuN9/lu2JX7Mpduat21a7e1btm1+z6VI5UTlTOVNzIuNPxIGSEnFAQSkJFp8kMlSOVE5UzlS8ihSghGsSAMBAOIkAkiALRIAaEgXAhQogUokA0iAFhIBxEgEgQBaJBDAgTwoUIIRJEgWgQA8JAOIgAkSAKRIMYIUwIFyJAJIgC0SAGhIFwEAEiQRSIFmKEMCEcRIBIEAWiQQwIA+EgAkSCKCFaiBHif9EfLvoGq7he+g=="
        XCTAssertEqual(try decompress(base64), expected)
    }

    // MARK: - zlib 包装识别

    func testZlibWrappingDetection() throws {
        let wrapped = try XCTUnwrap(Data(base64Encoded: "eJzLSM3JyddRSElNy0ksSVUEACwEBVc="))
        let raw = try XCTUnwrap(Data(base64Encoded: "y0jNycnXUUhJTctJLElVBAA=") )
        XCTAssertTrue(Inflate.isZlibWrapped([UInt8](wrapped)))
        XCTAssertTrue(Inflate.isZlibWrapped([UInt8](try XCTUnwrap(Data(base64Encoded: "eJxLTEpOHEWjaBSNolE0ikYqAgBlKLEv")))))
        // 裸 deflate 不该被当成 zlib（判据是 CM == 8 且头两字节 mod 31 == 0）。
        XCTAssertEqual(String(decoding: try Inflate.inflateRaw([UInt8](raw)), as: UTF8.self), "hello, deflate!")
    }

    // MARK: - 损坏输入（宁可报错，不要给出半截数据）

    func testTruncatedInputThrows() {
        let full = try! XCTUnwrap(Data(base64Encoded: "eNpLTEpOHEWjaBSNolE0ikYqAgBlKLEv"))
        let truncated = Data(full.dropLast(4))
        XCTAssertThrowsError(try Inflate.decompress(truncated))
    }

    func testStoredLengthMismatchThrows() {
        // 裸 deflate 的存储块：`01` = BFINAL=1 / BTYPE=00，随后 LEN=5、NLEN 故意写错（0x1234）。
        // 这里**不用** `decompress`：那会先按 zlib 头剥 2 字节头与 4 字节尾（本用例没有尾巴）。
        let bytes: [UInt8] = [0x01, 0x05, 0x00, 0x34, 0x12, 0x41, 0x42, 0x43, 0x44, 0x45]
        XCTAssertThrowsError(try Inflate.inflateRaw(bytes)) { error in
            XCTAssertEqual(error as? Inflate.Failure, .storedLengthMismatch)
        }
    }

    func testUnsupportedBlockTypeThrows() {
        // 第一字节 LSB 三位：BFINAL=1、BTYPE=11（非法）。
        XCTAssertThrowsError(try Inflate.decompress(Data([0x07, 0x00]))) { error in
            XCTAssertEqual(error as? Inflate.Failure, .unsupportedBlockType(3))
        }
    }

    func testEmptyInputThrows() {
        XCTAssertThrowsError(try Inflate.decompress(Data()))
    }

    /// 空负载（合法的空 deflate 流）要能解出空数据，而不是报错。
    func testEmptyPayloadDecodesToEmpty() throws {
        // Python: zlib.compress(b"") → 78 9c 03 00 00 00 00 01
        XCTAssertEqual(try Inflate.decompress(Data([0x78, 0x9C, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01])).count, 0)
    }
}
