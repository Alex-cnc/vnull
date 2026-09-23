import XCTest
@testable import DoyahCore

/// 项目内口令文件（开发 / 验收形态）的回归测试。
///
/// 这套存储是**为了远程开发**才引入的（钥匙串每次访问都要人工授权系统密码，等于堵死自动化），
/// 所以测试要同时守住两件事：**功能正确**，以及**安全边界被写清楚**：
///   · 文件里**不得出现明文**；
///   · 同一个口令两次写入密文**不同**（每个条目独立随机盐）；
///   · 权限 0600；
///   · 损坏要**如实报错**（静默返回 nil 会让"密码怎么没了"变成无解悬案）；
///   · 但"**读不到**"（沙箱里读项目内那份会被拒）只能算跳过，不能当损坏 —— 那是环境不匹配，
///     把它报成错误的结果就是：沙箱应用明明容器里有好数据，却因为项目那份而连不上库。
final class LocalSecretStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalSecretStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    private func store() -> FileSecretStore {
        FileSecretStore(fileURL: directory.appendingPathComponent("credentials.json"))
    }

    private func rawFile(_ store: FileSecretStore) throws -> String {
        try String(contentsOf: store.location(), encoding: .utf8)
    }

    // MARK: - 往返与隔离

    func testRoundTripAndPerConnectionIsolation() throws {
        let store = store()
        let a = UUID()
        let b = UUID()

        try store.setPassword("pw-A", for: a)
        try store.setPassword("pw-B", for: b)

        XCTAssertEqual(try store.password(for: a), "pw-A")
        XCTAssertEqual(try store.password(for: b), "pw-B")

        try store.deletePassword(for: a)
        XCTAssertNil(try store.password(for: a))
        XCTAssertEqual(try store.password(for: b), "pw-B", "删一个不该影响另一个")
    }

    func testMissingFileMeansNoPassword() throws {
        XCTAssertNil(try store().password(for: UUID()))
    }

    func testOverwrite() throws {
        let store = store()
        let id = UUID()
        try store.setPassword("first", for: id)
        try store.setPassword("second", for: id)
        XCTAssertEqual(try store.password(for: id), "second")
    }

    // MARK: - 安全边界

    /// 文件里不得出现明文 —— 这是这套存储"看起来像加密"的最低要求。
    func testFileNeverContainsPlaintext() throws {
        let store = store()
        let id = UUID()
        try store.setPassword("Sup3rSecret!", for: id)

        let raw = try rawFile(store)
        XCTAssertFalse(raw.contains("Sup3rSecret!"), "口令文件里出现了明文")
        XCTAssertTrue(raw.contains("salt"), "应当带每条目独立盐")
    }

    /// 同一口令两次写入密文不同（随机盐），避免"两份文件一比对就知道口令相同"。
    func testSamePasswordProducesDifferentCiphertext() throws {
        let store = store()
        let id = UUID()

        try store.setPassword("same", for: id)
        let first = try rawFile(store)
        try store.setPassword("same", for: id)
        let second = try rawFile(store)

        XCTAssertNotEqual(first, second, "两次写同样的口令，密文应当不同（盐不同）")
    }

    func testFilePermissionsAreOwnerOnly() throws {
        let store = store()
        try store.setPassword("x", for: UUID())

        let attributes = try FileManager.default.attributesOfItem(atPath: store.location().path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(permissions & 0o777, 0o600, "口令文件应当只有属主可读写")
    }

    /// 损坏要如实抛错，不能静默当空。
    func testCorruptFileThrowsReadableError() throws {
        let store = store()
        try Data("这不是 JSON".utf8).write(to: store.location())

        do {
            _ = try store.password(for: UUID())
            XCTFail("损坏文件应当抛错")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("口令文件损坏"), error.localizedDescription)
            // 报错要说清**是哪一份**，多候选之后不说路径就没法定位。
            XCTAssertTrue(error.localizedDescription.contains("credentials.json"))
        }
    }

    /// **回归**：沙箱应用读项目内那份会拿到权限错误（The file couldn't be opened because you
    /// don't have permission）。这不是"文件损坏"，不能因此挡住容器里那份好数据。
    ///
    /// 用"把候选路径做成目录"来制造一个确定性的不可读候选（Data(contentsOf:) 必失败），
    /// 不依赖权限位，测试在任何身份下都可复现。
    func testUnreadableFirstCandidateFallsBackInsteadOfThrowing() throws {
        let first = directory.appendingPathComponent("repo/credentials.json")
        let second = directory.appendingPathComponent("container/credentials.json")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        let id = UUID()
        try FileSecretStore(fileURL: second).setPassword("survives-sandbox", for: id)

        let store = FileSecretStore(fileURLs: [first, second])
        XCTAssertEqual(try store.password(for: id), "survives-sandbox")
    }

    /// 全都读不到 = 这个环境里没存过口令，应当安静地当"没有密码"，而不是弹一个用户看不懂的错误。
    func testAllCandidatesUnreadableMeansNoPassword() throws {
        let first = directory.appendingPathComponent("repo/credentials.json")
        let second = directory.appendingPathComponent("container/credentials.json")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

        let store = FileSecretStore(fileURLs: [first, second])
        XCTAssertNil(try store.password(for: UUID()), "读不到不该抛错，应视为未保存")
    }

    /// **回归（需求提出者实测场景）**：项目内那份被沙箱拒绝读取（`Permission denied`）时，
    /// 必须安静地换用容器那份 —— 旧代码在第一个候选上抛错，于是"容器里明明有口令却连不上库"。
    func testPermissionDeniedCandidateIsSkipped() throws {
        try XCTSkipIf(getuid() == 0, "root 无视权限位，此用例无意义")
        let first = directory.appendingPathComponent("repo/credentials.json")
        let second = directory.appendingPathComponent("container/credentials.json")
        try FileManager.default.createDirectory(
            at: first.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let id = UUID()
        try FileSecretStore(fileURL: second).setPassword("from-container", for: id)
        try FileSecretStore(fileURL: first).setPassword("shadowed", for: id)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: first.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: first.path) }

        let store = FileSecretStore(fileURLs: [first, second])
        XCTAssertEqual(try store.password(for: id), "from-container")
    }

    /// 某一份坏了、但另一份是好的：用好的那份（镜像写入会遇到"其中一份被截断"的情况）。
    func testCorruptCandidateFallsBackToHealthyOne() throws {
        let first = directory.appendingPathComponent("repo/credentials.json")
        let second = directory.appendingPathComponent("container/credentials.json")
        try FileManager.default.createDirectory(
            at: first.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("这不是 JSON".utf8).write(to: first)
        let id = UUID()
        try FileSecretStore(fileURL: second).setPassword("healthy", for: id)

        let store = FileSecretStore(fileURLs: [first, second])
        XCTAssertEqual(try store.password(for: id), "healthy")
    }

    // MARK: - 混淆算法本身

    func testCipherIsReversibleAndSaltDependent() {
        let salt = LocalSecretsCipher.randomSalt()
        let cipher = LocalSecretsCipher.obfuscate("hello", key: "k", salt: salt)
        XCTAssertEqual(LocalSecretsCipher.deobfuscate(cipher, key: "k", salt: salt), "hello")

        // 另一把盐 → 不同密文；换条目键 → 解不出来。
        let otherSalt = LocalSecretsCipher.randomSalt()
        XCTAssertNotEqual(cipher, LocalSecretsCipher.obfuscate("hello", key: "k", salt: otherSalt))
        XCTAssertNotEqual(LocalSecretsCipher.deobfuscate(cipher, key: "other", salt: salt), "hello")
    }

    func testCipherHandlesUnicodeAndLongSecrets() {
        let salt = LocalSecretsCipher.randomSalt()
        let secret = String(repeating: "中文🔐口令", count: 40)
        let cipher = LocalSecretsCipher.obfuscate(secret, key: "k", salt: salt)
        XCTAssertEqual(LocalSecretsCipher.deobfuscate(cipher, key: "k", salt: salt), secret)
    }

    // MARK: - 位置解析

    /// 工程根识别：包在 `dist/` 下时，从包往上应能找到含 `Package.swift` 与 `Scripts/` 的目录。
    func testProjectRootDetectionPrefersRepoCheckout() throws {
        let repo = directory.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try Data().write(to: repo.appendingPathComponent("Package.swift"))
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent("Scripts", isDirectory: true),
            withIntermediateDirectories: true
        )
        let bundle = repo.appendingPathComponent("dist/App.app")

        XCTAssertEqual(LocalSecretsLocation.projectRoot(startingAt: bundle)?.path, repo.path)

        let resolved = LocalSecretsLocation.directory(
            environment: [:],
            bundleURL: bundle,
            applicationSupport: directory
        )
        XCTAssertEqual(resolved.path, repo.appendingPathComponent(".secrets").path)
    }

    func testEnvironmentOverrideWins() {
        let override = directory.appendingPathComponent("custom-secrets").path
        let resolved = LocalSecretsLocation.directory(
            environment: ["DOYAH_SECRETS_DIR": override],
            bundleURL: URL(fileURLWithPath: "/nonexistent/App.app"),
            applicationSupport: directory
        )
        XCTAssertEqual(resolved.path, override)
    }

    // MARK: - 智能体 API Key 同款存储

    func testFileAgentKeyStoreRoundTrip() throws {
        let fileURL = directory.appendingPathComponent("credentials.json")
        let store = FileAgentKeyStore(fileURL: fileURL)

        XCTAssertNil(try store.apiKey())
        try store.setAPIKey("sk-test-123")
        XCTAssertEqual(try store.apiKey(), "sk-test-123")

        let raw = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(raw.contains("sk-test-123"), "API Key 也不该以明文落盘")

        try store.deleteAPIKey()
        XCTAssertNil(try store.apiKey())
    }

    // MARK: - 多候选（项目内 + 容器）：沙箱构建读的是容器那份

    /// 写入镜像到所有可写候选；任一候选都能独立解出同一个口令。
    func testWriteMirrorsAcrossAllCandidates() throws {
        let repo = directory.appendingPathComponent("repo/credentials.json")
        let container = directory.appendingPathComponent("container/credentials.json")
        let store = FileSecretStore(fileURLs: [repo, container])
        let id = UUID()

        try store.setPassword("mirrored", for: id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: container.path))
        XCTAssertEqual(try FileSecretStore(fileURL: repo).password(for: id), "mirrored")
        XCTAssertEqual(try FileSecretStore(fileURL: container).password(for: id), "mirrored")
    }

    /// 读时按候选顺序回退：第一份不存在/没有该条目，就用下一份 ——
    /// 这正是"沙箱应用读不到项目内那份"时的活路。
    func testReadFallsBackToLaterCandidate() throws {
        let first = directory.appendingPathComponent("repo/credentials.json")
        let second = directory.appendingPathComponent("container/credentials.json")
        let id = UUID()

        // 只写第二份（模拟：项目内那份在沙箱里不可读 / 不存在）
        try FileSecretStore(fileURL: second).setPassword("only-in-container", for: id)

        let store = FileSecretStore(fileURLs: [first, second])
        XCTAssertEqual(try store.password(for: id), "only-in-container")
    }

    /// 删除要把所有候选里的条目都清掉，不能只清第一份。
    func testDeleteClearsEveryCandidate() throws {
        let first = directory.appendingPathComponent("repo/credentials.json")
        let second = directory.appendingPathComponent("container/credentials.json")
        let store = FileSecretStore(fileURLs: [first, second])
        let id = UUID()
        try store.setPassword("x", for: id)

        try store.deletePassword(for: id)

        XCTAssertNil(try FileSecretStore(fileURL: first).password(for: id))
        XCTAssertNil(try FileSecretStore(fileURL: second).password(for: id))
    }

    /// 全部候选都不可写时，要抛出**说得出路径**的错误。
    func testWriteFailureListsAttemptedPaths() throws {
        let blocked = directory.appendingPathComponent("blocked-file")
        try Data("not a directory".utf8).write(to: blocked)
        let store = FileSecretStore(fileURLs: [blocked.appendingPathComponent("credentials.json")])

        do {
            try store.setPassword("x", for: UUID())
            XCTFail("不可写时应当抛错")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("已尝试"), error.localizedDescription)
        }
    }

    /// `searchedLocations()` 供界面把"找过哪些路径"显示出来（排障用）。
    func testSearchedLocationsExposed() {
        let first = directory.appendingPathComponent("a/credentials.json")
        let second = directory.appendingPathComponent("b/credentials.json")
        XCTAssertEqual(FileSecretStore(fileURLs: [first, second]).searchedLocations().count, 2)
    }
}
