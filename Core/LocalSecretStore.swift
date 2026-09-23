import Foundation

#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

/// 本地口令文件的**可逆混淆**（不是加密 —— 名字必须诚实）。
///
/// 为什么需要它：开发与验收要在**远程 / IM 遥控**下反复连库，而系统凭据存储（钥匙串）
/// 每次访问都要人工授权系统密码 —— 那等于把自动化堵死。所以开发形态改用
/// **项目目录下的一个文件**存口令：不弹系统框、也不碰工作区之外的路径。
///
/// **安全边界（写清楚，不含糊）**：
///   · 用 MD5 派生密钥做 XOR 流，**这是混淆不是加密**。它防的是「随手翻开文件看到明文」与
///     「误提交进仓库」；**不防**「拿到代码与文件的人」—— 密钥算法就在开源代码里，谁都能解。
///   · 因此它**只用于开发 / 验收形态**。发布形态应当切回系统凭据存储
///     （`Platform/macOS/KeychainSecretStore.swift` 仍在，切回只需改 `AppState` 里的一行注入）。
///   · 文件权限按 0600 写，且 `.secrets/` 已在 `.gitignore` 里。
///
/// 为什么 MD5 只用来派生密钥、不直接存散列：散列是单向的，**存了就没法拿去连库**。
/// 要可逆就必须有密钥流，而按需求提出者的要求，密钥流由 MD5 派生。
public enum LocalSecretsCipher {

    /// 混淆：`密文 = 明文 XOR keystream(盐, 条目键)`。
    public static func obfuscate(_ plaintext: String, key: String, salt: Data) -> Data {
        let bytes = Array(plaintext.utf8)
        let stream = keystream(count: bytes.count, key: key, salt: salt)
        return Data(zip(bytes, stream).map { $0 ^ $1 })
    }

    /// 还原。
    public static func deobfuscate(_ ciphertext: Data, key: String, salt: Data) -> String? {
        let bytes = Array(ciphertext)
        let stream = keystream(count: bytes.count, key: key, salt: salt)
        let plain = Data(zip(bytes, stream).map { $0 ^ $1 })
        return String(data: plain, encoding: .utf8)
    }

    /// `MD5(盐 ‖ 条目键 ‖ 计数器)` 逐块生成密钥流。
    ///
    /// 每次取 16 字节，计数器递增 —— 同一个口令在不同盐下密文不同（避免"两份文件一比对就知道
    /// 密码相同"），也避免长口令反复用同一段流。
    static func keystream(count: Int, key: String, salt: Data) -> [UInt8] {
        guard count > 0 else { return [] }
        var stream: [UInt8] = []
        var counter: UInt32 = 0
        let keyBytes = Array(key.utf8)
        while stream.count < count {
            var input = salt
            input.append(contentsOf: keyBytes)
            input.append(UInt8(counter & 0xFF))
            input.append(UInt8((counter >> 8) & 0xFF))
            input.append(UInt8((counter >> 16) & 0xFF))
            input.append(UInt8((counter >> 24) & 0xFF))
            stream.append(contentsOf: md5(input))
            counter += 1
        }
        return Array(stream.prefix(count))
    }

    static func md5(_ data: Data) -> [UInt8] {
        #if canImport(CryptoKit)
        return Array(Insecure.MD5.hash(data: data))
        #else
        return Array(Insecure.MD5.hash(data: data))
        #endif
    }

    public static func randomSalt(byteCount: Int = 16) -> Data {
        Data((0..<byteCount).map { _ in UInt8.random(in: 0...255) })
    }
}

/// 口令文件的位置：**优先项目内**（远程开发时工作区内即可读写，不需要任何授权框）。
///
/// 解析顺序：
///   1. 环境变量 `DOYAH_SECRETS_DIR`（显式指定，最高优先）；
///   2. 从应用包位置向上找到**工程根**（含 `Package.swift` 与 `Scripts/`）→ `<工程根>/.secrets`；
///   3. 都不成立时退回应用数据目录下的 `.secrets`（安装到别处时仍可用）。
public enum LocalSecretsLocation {
    public static let directoryName = ".secrets"
    public static let fileName = "credentials.json"

    public static func directory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL = Bundle.main.bundleURL,
        applicationSupport: URL? = nil
    ) -> URL {
        if let override = environment["DOYAH_SECRETS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let root = projectRoot(startingAt: bundleURL) {
            return root.appendingPathComponent(directoryName, isDirectory: true)
        }
        let base = applicationSupport ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent(DoyahIdentity.applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// 从应用包往上找工程根：为**开发形态**服务（包在 `dist/` 下，往上两层就是仓库根）。
    static func projectRoot(startingAt url: URL, maxDepth: Int = 6) -> URL? {
        var current = url
        for _ in 0..<maxDepth {
            current = current.deletingLastPathComponent()
            if current.path == "/" { return nil }
            let marker = current.appendingPathComponent("Package.swift")
            let scripts = current.appendingPathComponent("Scripts", isDirectory: true)
            if FileManager.default.fileExists(atPath: marker.path),
               FileManager.default.fileExists(atPath: scripts.path) {
                return current
            }
        }
        return nil
    }

    public static func fileURL(directory: URL) -> URL {
        directory.appendingPathComponent(fileName, isDirectory: false)
    }
}

/// 文件形态的口令存储（开发 / 验收用；见 `LocalSecretsCipher` 的安全边界）。
public final class FileSecretStore: SecretStore, @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? LocalSecretsLocation.fileURL(
            directory: LocalSecretsLocation.directory()
        )
    }

    public func location() -> URL { fileURL }

    public func setPassword(_ password: String, for connectionID: UUID) throws {
        try mutate { store in
            let salt = LocalSecretsCipher.randomSalt()
            store.entries[connectionID.uuidString] = .init(
                salt: salt.base64EncodedString(),
                data: LocalSecretsCipher
                    .obfuscate(password, key: connectionID.uuidString, salt: salt)
                    .base64EncodedString()
            )
        }
    }

    public func password(for connectionID: UUID) throws -> String? {
        try read { store in
            guard let entry = store.entries[connectionID.uuidString],
                  let salt = Data(base64Encoded: entry.salt),
                  let data = Data(base64Encoded: entry.data) else { return nil }
            return LocalSecretsCipher.deobfuscate(data, key: connectionID.uuidString, salt: salt)
        }
    }

    public func deletePassword(for connectionID: UUID) throws {
        try mutate { store in
            store.entries.removeValue(forKey: connectionID.uuidString)
        }
    }

    // MARK: 读写

    struct Entry: Codable { var salt: String; var data: String }
    struct Store: Codable {
        var version: Int = 1
        var entries: [String: Entry] = [:]
    }

    private func read<T>(_ body: (Store) -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return body(Store()) }
        do {
            let data = try Data(contentsOf: fileURL)
            guard !data.isEmpty else { return body(Store()) }
            return body(try JSONDecoder().decode(Store.self, from: data))
        } catch {
            // 损坏要**如实抛错**：静默返回 nil 会让"密码怎么没了"变成无解悬案。
            throw AppError.persistence("口令文件读取失败：\(error.localizedDescription)")
        }
    }

    private func mutate(_ body: (inout Store) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        var store = Store()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                if !data.isEmpty {
                    store = try JSONDecoder().decode(Store.self, from: data)
                }
            } catch {
                throw AppError.persistence("口令文件读取失败：\(error.localizedDescription)")
            }
        }
        body(&store)

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(store).write(to: fileURL, options: .atomic)
            // 权限 0600：同机其他用户读不到（尽力而为，失败不阻断）。
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            throw AppError.persistence("口令文件写入失败：\(error.localizedDescription)")
        }
    }
}

/// 智能体 API Key 的文件形态存储（同上，单条目）。
public final class FileAgentKeyStore: AgentKeyStore, @unchecked Sendable {
    private let entryKey = "agent.api-key"
    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? LocalSecretsLocation.fileURL(
            directory: LocalSecretsLocation.directory()
        )
    }

    public func setAPIKey(_ key: String) throws {
        try mutate { store in
            let salt = LocalSecretsCipher.randomSalt()
            store.entries[entryKey] = .init(
                salt: salt.base64EncodedString(),
                data: LocalSecretsCipher
                    .obfuscate(key, key: entryKey, salt: salt)
                    .base64EncodedString()
            )
        }
    }

    public func apiKey() throws -> String? {
        try read { store in
            guard let entry = store.entries[entryKey],
                  let salt = Data(base64Encoded: entry.salt),
                  let data = Data(base64Encoded: entry.data) else { return nil }
            return LocalSecretsCipher.deobfuscate(data, key: entryKey, salt: salt)
        }
    }

    public func deleteAPIKey() throws {
        try mutate { store in store.entries.removeValue(forKey: entryKey) }
    }

    private func read<T>(_ body: (FileSecretStore.Store) -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty,
              let store = try? JSONDecoder().decode(FileSecretStore.Store.self, from: data) else {
            return body(FileSecretStore.Store())
        }
        return body(store)
    }

    private func mutate(_ body: (inout FileSecretStore.Store) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        var store = FileSecretStore.Store()
        if let data = try? Data(contentsOf: fileURL), !data.isEmpty {
            store = (try? JSONDecoder().decode(FileSecretStore.Store.self, from: data)) ?? store
        }
        body(&store)
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(store).write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            throw AppError.persistence("口令文件写入失败：\(error.localizedDescription)")
        }
    }
}
