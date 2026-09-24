import Foundation

/// specs 与任务定义的版本化、diff、回滚与重跑语义（FR-AI-11）。
///
/// 三条口径：
/// 1. **版本记录只追加、不修改**（`task-versions.jsonl`，一行一条）。历史一旦可被改写就不叫历史；
///    回滚也不是"删掉后面的版本"，而是**把旧版本的内容再存一次** —— 于是"曾经回滚过"这件事
///    本身也留在历史里（否则事后没人说得清中间发生过什么）。
/// 2. **内容没变就不记新版本**：否则每次保存（哪怕只点了下确定）都会堆一条空历史，
///    真正的改动会被噪音淹掉。
/// 3. **重跑必须显式选幂等语义**（覆盖 / 追加 / 断点）：默认值是有害的 ——
///    "顺手追加"会让重复数据悄悄堆积，"顺手覆盖"会丢数据。所以这里不提供默认。
public enum SpecVersioning {}

// MARK: - 版本

/// 一个历史版本（不可变快照）。
public struct SpecVersion: Codable, Equatable, Sendable {
    public var taskID: UUID
    /// 从 1 开始的版本号（按任务各自计数）。
    public var number: Int
    public var savedAt: Date
    /// 当时的自然语言规格（与定义同时留存）。
    public var specs: String
    /// 当时的完整定义快照。
    public var definition: DataTaskDefinition
    /// 这次保存的原因（例如「回滚到 v2」）—— 历史要能自己解释自己。
    public var note: String?

    public init(
        taskID: UUID,
        number: Int,
        savedAt: Date,
        specs: String,
        definition: DataTaskDefinition,
        note: String? = nil
    ) {
        self.taskID = taskID
        self.number = number
        self.savedAt = savedAt
        self.specs = specs
        self.definition = definition
        self.note = note
    }
}

/// 版本存储：只追加的 JSONL。
public struct SpecVersionStore: Sendable {
    public static let fileName = "task-versions.jsonl"

    private let fileURL: URL

    public init(directoryURL: URL) {
        self.fileURL = directoryURL.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    public var location: URL { fileURL }

    public enum StoreError: Error, LocalizedError {
        case writeFailed(reason: String)
        public var errorDescription: String? {
            switch self {
            case .writeFailed(let reason): return "版本记录写入失败：\(reason)"
            }
        }
    }

    /// 读取全部版本（坏行跳过 —— 一行坏了不该让整段历史不可用）。
    public func versions() -> [SpecVersion] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { line in
            try? decoder.decode(SpecVersion.self, from: Data(line.utf8))
        }
    }

    public func versions(taskID: UUID) -> [SpecVersion] {
        versions().filter { $0.taskID == taskID }.sorted { $0.number < $1.number }
    }

    public func version(taskID: UUID, number: Int) -> SpecVersion? {
        versions(taskID: taskID).first { $0.number == number }
    }

    /// 记一条新版本。
    ///
    /// - Returns: 新版本；**内容与最新版本相同**时返回 `nil`（不记空历史）。
    @discardableResult
    public func record(
        definition: DataTaskDefinition,
        note: String? = nil,
        now: Date = Date()
    ) throws -> SpecVersion? {
        let existing = versions(taskID: definition.id)
        if let latest = existing.last, Self.sameContent(latest.definition, definition) {
            return nil
        }
        let version = SpecVersion(
            taskID: definition.id,
            number: (existing.last?.number ?? 0) + 1,
            savedAt: now,
            specs: definition.specs,
            definition: definition,
            note: note
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(version) else {
            throw StoreError.writeFailed(reason: "无法编码版本记录")
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data + Data("\n".utf8))
            } else {
                try (data + Data("\n".utf8)).write(to: fileURL)
            }
        } catch {
            throw StoreError.writeFailed(reason: error.localizedDescription)
        }
        return version
    }

    /// 内容比较：**只看会影响执行的东西**（`updatedAt` / `createdAt` 变了不算改动）。
    static func sameContent(_ lhs: DataTaskDefinition, _ rhs: DataTaskDefinition) -> Bool {
        var a = lhs, b = rhs
        a.createdAt = Date(timeIntervalSince1970: 0)
        a.updatedAt = a.createdAt
        b.createdAt = a.createdAt
        b.updatedAt = a.createdAt
        return a == b
    }
}

// MARK: - diff

/// 一处改动（字段级）。
public struct SpecChange: Equatable, Sendable {
    /// 字段名（可读，例如「名称」「目标表」「转换（第 2 条）」）。
    public var field: String
    public var before: String
    public var after: String

    public init(field: String, before: String, after: String) {
        self.field = field
        self.before = before
        self.after = after
    }

    public var description: String { "\(field)：\(before) → \(after)" }
}

public enum SpecDiff {

    /// 字段级比较。**顺序稳定**（先定义字段，再按转换下标），便于断言与人工比对。
    public static func changes(between old: DataTaskDefinition, and new: DataTaskDefinition) -> [SpecChange] {
        var changes: [SpecChange] = []

        if old.name != new.name {
            changes.append(SpecChange(field: "名称", before: old.name, after: new.name))
        }
        if old.specs != new.specs {
            changes.append(SpecChange(field: "规格说明", before: old.specs, after: new.specs))
        }
        if old.isEnabled != new.isEnabled {
            changes.append(SpecChange(field: "是否启用", before: old.isEnabled ? "启用" : "停用",
                                      after: new.isEnabled ? "启用" : "停用"))
        }
        if String(describing: old.source) != String(describing: new.source) {
            changes.append(SpecChange(field: "数据源", before: String(describing: old.source),
                                      after: String(describing: new.source)))
        }
        if old.transformations.count != new.transformations.count {
            changes.append(SpecChange(field: "转换条数",
                                      before: "\(old.transformations.count)",
                                      after: "\(new.transformations.count)"))
        }
        for index in 0..<min(old.transformations.count, new.transformations.count) {
            let before = String(describing: old.transformations[index])
            let after = String(describing: new.transformations[index])
            if before != after {
                changes.append(SpecChange(field: "转换（第 \(index + 1) 条）", before: before, after: after))
            }
        }
        if String(describing: old.target) != String(describing: new.target) {
            changes.append(SpecChange(field: "目标", before: String(describing: old.target),
                                      after: String(describing: new.target)))
        }
        if String(describing: old.schedule) != String(describing: new.schedule) {
            changes.append(SpecChange(field: "调度", before: String(describing: old.schedule),
                                      after: String(describing: new.schedule)))
        }
        if String(describing: old.output) != String(describing: new.output) {
            changes.append(SpecChange(field: "输出", before: String(describing: old.output),
                                      after: String(describing: new.output)))
        }
        return changes
    }

    /// 规格说明的**逐行**差异（新增行 / 删除行），供"文字改了什么"用。
    public static func lineChanges(from old: String, to new: String) -> [SpecChange] {
        let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var changes: [SpecChange] = []
        let count = max(oldLines.count, newLines.count)
        for index in 0..<count {
            let before = index < oldLines.count ? oldLines[index] : ""
            let after = index < newLines.count ? newLines[index] : ""
            if before != after {
                changes.append(SpecChange(field: "第 \(index + 1) 行", before: before, after: after))
            }
        }
        return changes
    }
}

// MARK: - 重跑幂等语义

/// 重跑的幂等语义。**没有默认值**：必须显式选。
public enum RerunMode: String, CaseIterable, Codable, Sendable {
    /// 覆盖：先清掉目标范围内已有的数据，再写入本次结果。
    case overwrite
    /// 追加：直接写入，重复运行会产生重复数据（调用方必须知道这一点）。
    case append
    /// 断点续跑：从上次中断处继续，已完成的批次不重做。
    case resume

    public var label: String {
        switch self {
        case .overwrite: return "覆盖"
        case .append: return "追加"
        case .resume: return "断点续跑"
        }
    }

    public var semantics: String {
        switch self {
        case .overwrite: return "先删除目标范围内已有数据，再写入本次结果：重复运行结果一致，但会清掉别人写进去的行"
        case .append: return "直接写入：重复运行会**产生重复数据**（要么增量源本就只含新数据，要么接受重复）"
        case .resume: return "从上次中断处继续：已完成的批次不重做（需要目标表有可判断进度的标记列）"
        }
    }

    /// 这次重跑在**写入层面**用哪种模式。
    ///
    /// 为什么要映射而不是另写一套：`DataTaskDefinition.Target.WriteMode`
    /// （append / overwrite / upsert）已经存在，其类型注释就写着「对应 FR-AI-11 的重跑幂等语义」——
    /// 再建一个平行枚举就是两套写入语义，迟早互相矛盾（我第一版正是这么写的，写到一半发现）。
    /// 「断点续跑」在写入层面仍是追加，靠**进度标记**保证不重做，所以映射到 `.append`。
    public var writeMode: DataTaskDefinition.Target.WriteMode {
        switch self {
        case .overwrite: return .overwrite
        case .append, .resume: return .append
        }
    }
}

/// 重跑判定：把"选了哪种语义"与"这个任务能不能这么跑"分开说清楚。
public enum RerunPolicy {

    public struct Verdict: Equatable, Sendable {
        public var mode: RerunMode
        /// 阻止执行的问题（空 = 可以跑）。
        public var blockers: [String]
        /// 提醒（不阻止，但用户该知道）。
        public var warnings: [String]

        public var isAllowed: Bool { blockers.isEmpty }
    }

    public static func evaluate(mode: RerunMode, definition: DataTaskDefinition) -> Verdict {
        var blockers: [String] = []
        var warnings: [String] = []

        switch mode {
        case .overwrite:
            // 覆盖需要能定位"目标范围"：没有目标表就无从覆盖。
            if definition.target.table.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blockers.append("覆盖模式需要明确的目标表：没有目标范围就不知道要清掉哪些数据")
            }
        case .append:
            warnings.append("追加模式重复运行会产生重复数据（这是该语义的定义，不是缺陷）")
        case .resume:
            warnings.append("断点续跑要求目标能判断进度（例如带批次标记列）；否则会从头重跑")
        }

        // 与任务自带的写入模式对齐：两者不一致时**必须说出来** ——
        // "我选了覆盖、任务却按追加写"这种错配会让幂等承诺变成空话。
        let declared = definition.target.writeMode
        let mapped = mode.writeMode
        if declared == .upsert && mode == .append {
            warnings.append("任务声明的是 upsert（按唯一键更新）：实际行为不是纯追加，重复运行不会产生重复行")
        } else if declared != mapped {
            blockers.append(
                "选择的重跑语义是「\(mode.label)」（写入层面为 \(mapped.rawValue)），"
                    + "而任务声明的是 \(declared.rawValue)：两者不一致，请先改任务的目标写入模式"
            )
        }

        return Verdict(mode: mode, blockers: blockers, warnings: warnings)
    }

    /// 给用户看的一句话（界面 / CLI 共用同一份文案来源）。
    public static func describe(_ mode: RerunMode) -> String {
        "\(mode.label)：\(mode.semantics)"
    }
}
