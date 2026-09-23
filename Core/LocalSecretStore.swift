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

    /// 口令文件的**候选目录**，按优先级排列。
    ///
    /// 为什么是"候选"而不是"一个位置"：**沙箱构建的应用读不到工作区之外的路径** ——
    /// 只认工程目录时，沙箱版应用读不到口令，就会报「读取密码失败」（实测踩到）。
    /// 所以读的时候按顺序找、写的时候**每个可写的都写一份**：
    ///   · 非沙箱构建 / CLI：项目内 + 容器各一份，两边一致；
    ///   · 沙箱构建：项目内那份写不进去（会失败被跳过），容器那份成功 → 照样能用。
    /// 只要写入都经过本类，多份之间就不会漂移。
    public static func candidateDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL = Bundle.main.bundleURL,
        applicationSupport: URL? = nil
    ) -> [URL] {
        var candidates: [URL] = []
        if let override = environment["DOYAH_SECRETS_DIR"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        if let root = projectRoot(startingAt: bundleURL) {
            candidates.append(root.appendingPathComponent(directoryName, isDirectory: true))
        }
        let base = applicationSupport ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        candidates.append(
            base
                .appendingPathComponent(DoyahIdentity.applicationSupportDirectoryName, isDirectory: true)
                .appendingPathComponent(directoryName, isDirectory: true)
        )

        // 去重（同一路径只留一次），保持优先级顺序。
        var seen: Set<String> = []
        return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// 首选位置（用于展示与"写到哪儿"的提示）：候选里的第一个。
    public static func directory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL = Bundle.main.bundleURL,
        applicationSupport: URL? = nil
    ) -> URL {
        candidateDirectories(
            environment: environment,
            bundleURL: bundleURL,
            applicationSupport: applicationSupport
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
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
    /// 候选文件（按优先级）；读时先命中先用，写时每个可写的都写。
    private let fileURLs: [URL]
    private let lock = NSLock()

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURLs = [fileURL]
        } else {
            self.fileURLs = LocalSecretsLocation.candidateDirectories().map(
                LocalSecretsLocation.fileURL(directory:)
            )
        }
    }

    public init(fileURLs: [URL]) {
        self.fileURLs = fileURLs
    }

    /// 首选位置（展示用）。
    public func location() -> URL { fileURLs[0] }

    /// 实际会读/写的所有位置 —— 报错时把它说出来，省得下次又靠猜。
    public func searchedLocations() -> [URL] { fileURLs }

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
        // `mutate` 会把合并后的内容写回**所有**可写候选，因此这里删一次就够了 ——
        // 但如果某一份不可写（沙箱），那份可能残留；用 removeAll 语义补齐。
        try mutate { store in
            store.entries.removeValue(forKey: connectionID.uuidString)
        }
        for fileURL in fileURLs where FileManager.default.fileExists(atPath: fileURL.path) {
            guard let data = try? Data(contentsOf: fileURL), !data.isEmpty,
                  var store = try? JSONDecoder().decode(Store.self, from: data) else { continue }
            store.entries.removeValue(forKey: connectionID.uuidString)
            if let payload = try? JSONEncoder().encode(store) {
                try? payload.write(to: fileURL, options: .atomic)
            }
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
        for fileURL in fileURLs {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            do {
                let data = try Data(contentsOf: fileURL)
                guard !data.isEmpty else { continue }
                return body(try JSONDecoder().decode(Store.self, from: data))
            } catch {
                // 损坏要**如实抛错**：静默返回 nil 会让"密码怎么没了"变成无解悬案。
                // 同时把路径说出来 —— 多候选之后，不说路径就没法判断读的是哪一份。
                throw AppError.persistence(
                    "口令文件读取失败（\(fileURL.path)）：\(error.localizedDescription)"
                )
            }
        }
        return body(Store())
    }

    private func mutate(_ body: (inout Store) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }

        // 以第一份**可读**的为准（保证多份之间以它为基础合并），没有就从空开始。
        var store = Store()
        for fileURL in fileURLs where FileManager.default.fileExists(atPath: fileURL.path) {
            if let data = try? Data(contentsOf: fileURL), !data.isEmpty,
               let decoded = try? JSONDecoder().decode(Store.self, from: data) {
                store = decoded
                break
            }
        }
        body(&store)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload: Data
        do {
            payload = try encoder.encode(store)
        } catch {
            throw AppError.persistence("口令文件编码失败：\(error.localizedDescription)")
        }

        // 写到**每一个可写**的候选：沙箱构建只写得进容器那份，非沙箱与 CLI 两份都写。
        var written: [URL] = []
        var lastError: (any Error)?
        for fileURL in fileURLs {
            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try payload.write(to: fileURL, options: .atomic)
                // 权限 0600：同机其他用户读不到（尽力而为，失败不阻断）。
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: fileURL.path
                )
                written.append(fileURL)
            } catch {
                lastError = error
            }
        }

        guard !written.isEmpty else {
            throw AppError.persistence(
                "口令文件写入失败（已尝试：\(fileURLs.map(\.path).joined(separator: "、"))）："
                + "\(lastError?.localizedDescription ?? "未知原因")"
            )
        }
    }
}

/// 智能体 API Key 的文件形态存储（同上，单条目）。
public final class FileAgentKeyStore: AgentKeyStore, @unchecked Sendable {
    private let entryKey = "agent.api-key"
    private let fileURLs: [URL]
    private let lock = NSLock()

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURLs = [fileURL]
        } else {
            self.fileURLs = LocalSecretsLocation.candidateDirectories().map(
                LocalSecretsLocation.fileURL(directory:)
            )
        }
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
        for fileURL in fileURLs {
            guard let data = try? Data(contentsOf: fileURL), !data.isEmpty,
                  let store = try? JSONDecoder().decode(FileSecretStore.Store.self, from: data) else {
                continue
            }
            return body(store)
        }
        return body(FileSecretStore.Store())
    }

    private func mutate(_ body: (inout FileSecretStore.Store) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        var store = FileSecretStore.Store()
        for fileURL in fileURLs where FileManager.default.fileExists(atPath: fileURL.path) {
            if let data = try? Data(contentsOf: fileURL), !data.isEmpty,
               let decoded = try? JSONDecoder().decode(FileSecretStore.Store.self, from: data) {
                store = decoded
                break
            }
        }
        body(&store)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload: Data
        do {
            payload = try encoder.encode(store)
        } catch {
            throw AppError.persistence("口令文件编码失败：\(error.localizedDescription)")
        }
        var written = 0
        for fileURL in fileURLs {
            guard (try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )) != nil else { continue }
            guard (try? payload.write(to: fileURL, options: .atomic)) != nil else { continue }
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
            written += 1
        }
        guard written > 0 else {
            throw AppError.persistence("口令文件写入失败（所有候选都不可写）")
        }
    }
}
