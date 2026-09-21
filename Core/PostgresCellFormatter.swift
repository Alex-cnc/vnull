import Foundation
import PostgresNIO

/// 将 PostgresNIO 返回的二进制 Cell 转成 UI 可展示的字符串。
///
/// PostgresNIO 在扩展查询协议下默认要求 binary 结果格式，
/// 因此不能直接用 `String(bytes:)` 读所有类型，需要按数据类型解码。
public enum PostgresCellFormatter {
    public static func format(_ cell: PostgresCell) -> String? {
        guard cell.bytes != nil else {
            return nil
        }

        if let known = decodeKnownType(cell) {
            return known
        }

        // 文本格式兜底
        if cell.format == .text,
           let buffer = cell.bytes,
           let string = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) {
            return string
        }

        // 未知类型：尝试用 String 解码；失败则给出可诊断的原始描述
        if let string = try? cell.decode(String.self) {
            return string
        }
        if let buffer = cell.bytes {
            return String(describing: buffer)
        }
        return nil
    }

    private static func decodeKnownType(_ cell: PostgresCell) -> String? {
        switch cell.dataType {
        case .bool:
            if let value = try? cell.decode(Bool.self) {
                return value ? "true" : "false"
            }
        case .int2:
            if let value = try? cell.decode(Int16.self) {
                return String(value)
            }
        case .int4:
            if let value = try? cell.decode(Int32.self) {
                return String(value)
            }
        case .int8:
            if let value = try? cell.decode(Int64.self) {
                return String(value)
            }
        case .oid:
            if let value = try? cell.decode(Int.self) {
                return String(value)
            }
        case .float4:
            if let value = try? cell.decode(Float.self) {
                return String(value)
            }
        case .float8:
            if let value = try? cell.decode(Double.self) {
                return String(value)
            }
        case .numeric:
            if let value = try? cell.decode(Decimal.self) {
                return String(describing: value)
            }
        case .text, .varchar, .bpchar, .name, .json, .jsonb, .xml:
            if let value = try? cell.decode(String.self) {
                return value
            }
        case .uuid:
            if let value = try? cell.decode(UUID.self) {
                return value.uuidString
            }
        case .date, .timestamp, .timestamptz:
            if let value = try? cell.decode(Date.self) {
                return ISO8601DateFormatter().string(from: value)
            }
        default:
            break
        }
        return nil
    }
}
