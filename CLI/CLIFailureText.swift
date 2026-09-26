import Foundation
import DoyahCore

/// 命令行「把失败说成人话」的**唯一入口**（开发循环 L-15 定的输出口径）。
///
/// **为什么需要它**：CLI 里把失败说给用户看的地方有几十处，写法原本各按各的
/// （`print("列出表失败：\(error.localizedDescription)")`）。那种写法打出来的是
/// `The operation couldn't be completed. (PostgresNIO.PSQLError error 1.)` ——
/// **既不是人话、也没给方向**，而驱动其实说过原因（SQLSTATE / 驱动码），只是没人接。
/// 第 7~8 轮只把**连接失败**与**查询失败**两条主路接上了可读化链（`ConnectionFailure`），
/// 其余几十处仍是英文调试串 —— 同一条口径散在几十个 `catch` 里，改一处漏一处，
/// 所以这里收成一个入口，并由门禁 `Scripts/check-cli-failure-readability.py` 钉住。
///
/// **口径三条**（门禁按这三条机械对账）：
/// 1. **认得出就给方向**：连接类走 `ConnectionFailure.describe`（人话 + 建议 + 错误码）；
///    驱动报的、但**不是连接类**（取消 / 主动断开 / 协议层 / 未归类…）走
///    `describeNonConnection`（中性归因，逐码一句自己的实话，不说「连接失败」那套方向）。
/// 2. **认不出就不猜、也不丢串**：退回 `error.localizedDescription` **原样**，
///    不套任何方向结论 —— 这样「本地错误」（文件读写 / 编解码 / 钥匙串）的输出**与改动前逐字一致**，
///    不会因为走了这条链而被套上一句不相干的人话。
/// 3. **认得出来时原始串也保留**：以 `（原始信息：…）` 附在末尾。理由与 `调试详情` 那条纪律同源 ——
///    排查时「到底是哪个码 / 哪句话」才是关键，把原串换掉等于帮倒忙。
///
/// **两个显式例外**（不是漏网，是口径）：
/// - 机器可读出口（`--json` 的 `error` 字段）：原样给 `localizedDescription`，脚本要消费它；
/// - `String(reflecting: error)` 的**调试转储**：保留 —— 它是转储、不是给用户的结论，
///   且都出现在已经有人话的那几条路上（连接失败 / 查询失败 / 对象树）。
enum CLIFailureText {

    /// 命令行失败行里用的**一行**可读化文本。
    ///
    /// 返回**一行**（`；` 分隔），因为调用方的写法是 `print("标签：\(CLIFailureText.oneLine(error))")` ——
    /// 多行会把既有的输出形状改掉（那些形状有证据脚本在断言）。
    /// 认不出时返回 `error.localizedDescription` 原样（见口径第 2 条）。
    static func oneLine(_ error: any Error, target: ConnectionFailure.Target? = nil) -> String {
        let raw = error.localizedDescription

        if let failure = ConnectionFailure.describe(error, target: target) {
            var parts = [failure.summary]
            if let suggestion = failure.suggestion, !suggestion.isEmpty { parts.append("建议：" + suggestion) }
            if let code = failure.code, !code.isEmpty { parts.append("错误码：" + code) }
            return parts.joined(separator: "；") + rawSuffix(raw)
        }

        if let neutral = ConnectionFailure.describeNonConnection(error) {
            var parts = [neutral.summary]
            if let suggestion = neutral.suggestion, !suggestion.isEmpty { parts.append("建议：" + suggestion) }
            return parts.joined(separator: "；") + rawSuffix(raw)
        }

        // 认不出：**原样**返回，不猜测、不套方向结论（口径第 2 条）。
        return raw
    }

    /// `（原始信息：…）` 尾巴；空串时不加（免得出现「（原始信息：）」这种空壳）。
    private static func rawSuffix(_ raw: String) -> String {
        raw.isEmpty ? "" : "（原始信息：\(raw)）"
    }
}
