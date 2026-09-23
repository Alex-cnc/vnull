import XCTest
@testable import DoyahCore

/// 项目内口令文件（开发 / 验收形态）的回归测试。
///
/// 这套存储是**为了远程开发**才引入的（钥匙串每次访问都要人工授权系统密码，等于堵死自动化），
/// 所以测试要同时守住两件事：**功能正确**，以及**安全边界被写清楚**：
///   · 文件里**不得出现明文**；
///   · 同一个口令两次写入密文**不同**（每个条目独立随机盐）；
///   · 权限 0600；
///   · 损坏要**如实报错**（静默返回 nil 会让"密码怎么没了"变成无解悬案）。
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
            XCTAssertTrue(error.localizedDescription.contains("口令文件读取失败"))
        }
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
}
