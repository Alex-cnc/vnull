import Foundation

/// 人工对记忆层做的决定（FR-AI-14 的验收③④：建议**可被否决**、槽位**可人工订正**）。
///
/// 为什么要**持久化**：判据只能给建议，而建议必须能被长期压下去 ——
/// 手滑否决一次却在下一次启动就复活，等于没有否决（用户会学会不再相信这个列表，
/// 于是"可被否决"就退化成一句空话）。
///
/// 两条口径，别混：
/// - **否决（veto）**：只把该指纹从**候选列表**里摘掉。**不改聚类、不改频次、不删归档** ——
///   补全与记忆概览照旧：那是事实，不是建议。
/// - **保留字面量（keep literal）**：**只影响模板渲染**（该槽位改回字面量），
///   同样**不改聚类、不改频次** —— 聚类靠粗指纹，动它会与 FR-AI-13 的语义打架
///   （同一骨架的两条原文会突然被拆成两条记忆，补全立刻开始张冠李戴）。
public struct MemoryDecisions: Codable, Equatable, Sendable {

    /// 决定文件名（放在调用方给的目录里，与归档同目录：`--dir` 一处指定，不可能对不上）。
    public static let fileName = "memory-decisions.json"

    /// 被否决的指纹（**排序去重**：顺序稳定，文件内容才可复现、diff 才可读）。
    public private(set) var vetoedFingerprints: [String]
    /// 指纹 → 被标记为"这不是参数"的字面量（各自排序去重）。
    public private(set) var keptLiterals: [String: [String]]

    public init(
        vetoedFingerprints: [String] = [],
        keptLiterals: [String: [String]] = [:]
    ) {
        self.vetoedFingerprints = Array(Set(vetoedFingerprints)).sorted()
        self.keptLiterals = keptLiterals.reduce(into: [:]) { result, pair in
            result[pair.key] = Array(Set(pair.value)).sorted()
        }
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case vetoedFingerprints
        case keptLiterals
    }

    /// 手写解码：文件里的顺序不可信（可能是人手改的 / 旧版本写的），读进来一律归一化。
    /// 字段缺失按空处理 —— 少一个键不该让整份决定集失效。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let vetoed = try container.decodeIfPresent([String].self, forKey: .vetoedFingerprints) ?? []
        let kept = try container.decodeIfPresent([String: [String]].self, forKey: .keptLiterals) ?? [:]
        self.init(vetoedFingerprints: vetoed, keptLiterals: kept)
    }

    // MARK: - 否决

    public func isVetoed(_ fingerprint: String) -> Bool {
        vetoedFingerprints.contains(fingerprint)
    }

    public mutating func veto(fingerprint: String) {
        guard !fingerprint.isEmpty, !vetoedFingerprints.contains(fingerprint) else { return }
        vetoedFingerprints.append(fingerprint)
        vetoedFingerprints.sort()
    }

    public mutating func unveto(fingerprint: String) {
        vetoedFingerprints.removeAll { $0 == fingerprint }
    }

    // MARK: - 保留字面量

    /// 把该指纹下某个字面量标为"这不是参数"。
    ///
    /// 渲染模板时，**取值样例里含这个字面量**的槽位改回字面量
    /// （例如 `... where status = 'paid' and id = ?`）。
    /// 已知边界：槽位样例有上限（默认 5 个），若某个取值被挤出了样例表，
    /// 针对它的保留决定就暂时不再生效 —— 这是"有界"必然的代价，写在这里而不是留给读者发现。
    public mutating func keepLiteral(fingerprint: String, literal: String) {
        guard !fingerprint.isEmpty, !literal.isEmpty else { return }
        var literals = keptLiterals[fingerprint] ?? []
        guard !literals.contains(literal) else { return }
        literals.append(literal)
        literals.sort()
        keptLiterals[fingerprint] = literals
    }

    /// 该指纹下被保留的字面量（无则空数组）。
    public func keptLiterals(for fingerprint: String) -> [String] {
        keptLiterals[fingerprint] ?? []
    }

    public var isEmpty: Bool {
        vetoedFingerprints.isEmpty && keptLiterals.isEmpty
    }
}

/// 人工决定的落盘 / 读取。
///
/// 读取**不抛异常**：坏文件 / 读不了时回退为空决定集并**报告**（`warnings`）——
/// 沿用 `QueryMemory.buildIndex` 对坏文件的处理风格。理由一样：一个坏的决定文件
/// 不该让整个记忆层不可用，但也不能静默吞掉（那样用户会以为"我的否决丢了"）。
public enum MemoryDecisionsStore {

    public struct LoadResult: Equatable, Sendable {
        public var decisions: MemoryDecisions
        /// 读取失败 / 被跳过时的说明（空 = 一切正常）。
        public var warnings: [String]

        public init(decisions: MemoryDecisions = MemoryDecisions(), warnings: [String] = []) {
            self.decisions = decisions
            self.warnings = warnings
        }
    }

    public static func fileURL(in directory: URL) -> URL {
        directory.appendingPathComponent(MemoryDecisions.fileName, isDirectory: false)
    }

    /// 读决定集。文件不存在 = 空决定集（不是错误，更不是警告：大多数目录从来没有过人工决定）。
    public static func load(from directory: URL, fileManager: FileManager = .default) -> LoadResult {
        let url = fileURL(in: directory)
        guard fileManager.fileExists(atPath: url.path) else {
            return LoadResult()
        }
        do {
            let data = try Data(contentsOf: url)
            let decisions = try JSONDecoder().decode(MemoryDecisions.self, from: data)
            return LoadResult(decisions: decisions)
        } catch {
            return LoadResult(warnings: [
                "\(MemoryDecisions.fileName) 读不了（\(error.localizedDescription)），本次按「无人工决定」继续"
            ])
        }
    }

    /// 写决定集（原子写：磁盘上不会留半截文件，否则下次启动会读到"全丢了"的假象）。
    @discardableResult
    public static func save(
        _ decisions: MemoryDecisions,
        to directory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        // `sortedKeys` + 内部排序的数组：文件内容确定，跑两次逐字一致（可 diff、可进版本库）。
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(decisions)
        let url = fileURL(in: directory)
        try data.write(to: url, options: [.atomic])
        return url
    }
}
