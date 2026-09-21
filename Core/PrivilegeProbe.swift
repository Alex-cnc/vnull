import Foundation

/// 权限探测结果的解析与本地预校验（FR-META-11）。
///
/// 独立成纯逻辑，便于单测覆盖：驱动返回的是字符串（`PostgresCellFormatter` 已把
/// 布尔值转成 `t` / `f`），而界面需要的是「可 / 不可 / 未知」三态。
public enum PrivilegeProbe {

    /// 把「能否创建数据库」的探测结果解析为三态。
    ///
    /// - 支持 `t` / `f`（PostgreSQL 布尔文本）、`true` / `false`、`1` / `0`、`on` / `off`、`yes` / `no`
    /// - 空值或无法识别时返回 `nil`：**未知一律不呈现**建库入口
    public static func databaseCreationAllowed(from rawValue: String?) -> Bool? {
        guard let rawValue else { return nil }

        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "t", "true", "1", "on", "yes", "y":
            return true
        case "f", "false", "0", "off", "no", "n":
            return false
        default:
            return nil
        }
    }

    /// 数据库名的本地预校验（服务端仍会再校验一次）。
    ///
    /// 规则按 PostgreSQL 标识符：首字符为字母或下划线，其余为字母 / 数字 / `_` / `$`，
    /// 长度不超过 63 字节（NAT 上限），允许 Unicode 字母（中文库名可用，执行时会加引号）。
    public static func isValidDatabaseName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 63 else { return false }

        for (index, character) in trimmed.enumerated() {
            if index == 0 {
                guard character == "_" || character.isLetter else { return false }
            } else {
                guard character == "_" || character == "$" || character.isLetter || character.isNumber else {
                    return false
                }
            }
        }
        return true
    }
}
