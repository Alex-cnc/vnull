import Foundation

/// 归档的**编辑**能力（FR-AI-15 的「可删除 / 可整层清空」）。
///
/// 为什么删除必须落在**归档文件**上：记忆层的事实源就是归档（`QueryMemory` 的索引用它派生）。
/// 若只删索引或加一条"忽略名单"，用户会说"我删了它怎么还在补全里" —— 治理必须作用在事实上。
///
/// 两条纪律：
/// 1. **原子替换**：先写同目录下的临时文件再 `replaceItemAt`。归档是用户的真实资产，
///    中途失败（磁盘满 / 断电）绝不能留下半截文件把归档写坏。
/// 2. **保格式**：重写用 `SQLArchive.render`，它和 `SQLArchive.parse` 构成往返 ——
///    删掉 A 之后，B 仍要能被原样读回（有单测钉住）。
public enum SQLArchiveEditor {

    /// 一次编辑的结果（数量 + 被改动的文件），供 CLI / 界面如实汇报。
    public struct Report: Equatable, Sendable {
        public var removedEntryCount: Int
        public var changedFiles: [String]
        public var remainingEntryCount: Int

        public init(removedEntryCount: Int, changedFiles: [String], remainingEntryCount: Int) {
            self.removedEntryCount = removedEntryCount
            self.changedFiles = changedFiles
            self.remainingEntryCount = remainingEntryCount
        }

        public var didChangeAnything: Bool { !changedFiles.isEmpty }
    }

    public enum EditorError: Error, LocalizedError {
        case notADirectory(path: String)
        case writeFailed(path: String, reason: String)

        public var errorDescription: String? {
            switch self {
            case .notADirectory(let path):
                return "不是目录：\(path)"
            case .writeFailed(let path, let reason):
                return "写入失败：\(path)（\(reason)）"
            }
        }
    }

    /// 按**粗指纹**删除条目 —— 与记忆层的聚类口径一致（`QueryMemory.coarseFingerprint`），
    /// 因此"删掉那一条记忆"删的就是它名下的所有取值变体，不会只删掉其中一版。
    public static func removeEntries(
        matchingFingerprint fingerprint: String,
        in directory: URL,
        fileManager: FileManager = .default
    ) throws -> Report {
        try edit(directory: directory, fileManager: fileManager) { entries in
            entries.filter { QueryMemory.coarseFingerprint($0.sql) != fingerprint }
        }
    }

    /// 整层清空：**删掉归档文件本身**（而不是把它们重写成只剩文件头）。
    ///
    /// 为什么要区分：清空是"我不想要这些东西了"，留一堆只有文件头的空文件会让用户以为没清干净；
    /// 而单条删除仍保留当天的文件（那天还可能有别的记录）。
    public static func removeAll(
        in directory: URL,
        fileManager: FileManager = .default
    ) throws -> Report {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw EditorError.notADirectory(path: directory.path)
        }

        var removed = 0
        var changed: [String] = []
        for file in try archiveFiles(in: directory, fileManager: fileManager) {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            removed += SQLArchive.parse(text).count
            do {
                try fileManager.removeItem(at: file)
                changed.append(file.lastPathComponent)
            } catch {
                throw EditorError.writeFailed(path: file.path, reason: error.localizedDescription)
            }
        }
        return Report(removedEntryCount: removed, changedFiles: changed.sorted(), remainingEntryCount: 0)
    }

    // MARK: - 内部

    private static func archiveFiles(in directory: URL, fileManager: FileManager) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw EditorError.notADirectory(path: directory.path)
        }
        let contents = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        // 只认 `yyyy-MM-dd.sql` 这种归档文件：别把用户的其它 .sql（比如手写的脚本）删了。
        return contents
            .filter { $0.pathExtension == "sql" && isArchiveFileName($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func isArchiveFileName(_ name: String) -> Bool {
        let stem = name.replacingOccurrences(of: ".sql", with: "")
        let parts = stem.split(separator: "-")
        guard parts.count == 3 else { return false }
        return parts[0].count == 4 && parts[1].count == 2 && parts[2].count == 2
            && parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    private static func edit(
        directory: URL,
        fileManager: FileManager,
        transform: ([SQLArchiveEntry]) -> [SQLArchiveEntry]
    ) throws -> Report {
        var removed = 0
        var changed: [String] = []
        var remaining = 0

        for file in try archiveFiles(in: directory, fileManager: fileManager) {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            let entries = SQLArchive.parse(text)
            let kept = transform(entries)
            removed += entries.count - kept.count
            remaining += kept.count
            guard kept.count != entries.count else { continue }

            let day = dayDate(from: file.lastPathComponent) ?? Date()
            let rendered = SQLArchive.render(kept, day: day)
            try replaceAtomically(file: file, contents: rendered, fileManager: fileManager)
            changed.append(file.lastPathComponent)
        }

        return Report(
            removedEntryCount: removed,
            changedFiles: changed.sorted(),
            remainingEntryCount: remaining
        )
    }

    /// 原子替换：临时文件与目标**同目录**（跨卷 rename 会退化，同目录才能保证原子）。
    private static func replaceAtomically(
        file: URL,
        contents: String,
        fileManager: FileManager
    ) throws {
        let temporary = file.deletingLastPathComponent()
            .appendingPathComponent(".\(file.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try contents.write(to: temporary, atomically: true, encoding: .utf8)
            _ = try fileManager.replaceItemAt(file, withItemAt: temporary)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw EditorError.writeFailed(path: file.path, reason: error.localizedDescription)
        }
    }

    private static func dayDate(from fileName: String) -> Date? {
        let stem = fileName.replacingOccurrences(of: ".sql", with: "")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: stem)
    }
}
