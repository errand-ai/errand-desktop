import Foundation
import Security

/// Manages secrets in the macOS Keychain with a file-based fallback.
///
/// Ad-hoc signed development builds get a new code identity on every build,
/// making keychain items inaccessible across rebuilds. To avoid regenerating
/// keys (which would invalidate LiteLLM's encrypted database), secrets are
/// also cached in a local file. The file is the primary store; the keychain
/// provides additional OS-level protection for production (Developer ID) builds.
enum KeychainManager {

    private static let service = "sh.errand.ErrandDesktop"

    /// Directory for the file-based secret cache.
    private static var secretsDir: String {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ErrandDesktop")
            .path
        return base + "/secrets"
    }

    /// Base query attributes shared by all keychain operations.
    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    // MARK: - Public API

    /// Retrieves a value, or creates and stores a new random one.
    static func getOrCreate(account: String, bytesCount: Int = 32) throws -> String {
        if let existing = try get(account: account) {
            return existing
        }
        let key = try generateRandomKey(bytesCount: bytesCount)
        try set(account: account, value: key)
        return key
    }

    /// Retrieves the LiteLLM master key, or creates one in `sk-<18 alphanumeric>` format.
    static func getOrCreateLiteLLMKey() throws -> String {
        if let existing = try get(account: "litellm-master-key") {
            return existing
        }
        let key = try generateLiteLLMKey()
        try set(account: "litellm-master-key", value: key)
        return key
    }

    /// Retrieves the LiteLLM salt key, or creates a stable 32-byte hex value
    /// (equivalent to `openssl rand -hex 32`). Without a stable `LITELLM_SALT_KEY`,
    /// LiteLLM generates a random salt on every startup and previously-encrypted
    /// values stored in the database (model api_keys, api_bases, SMTP creds, etc.)
    /// fail to decrypt with `nacl.exceptions.CryptoError`.
    static func getOrCreateLiteLLMSaltKey() throws -> String {
        if let existing = try get(account: "litellm-salt-key") {
            return existing
        }
        let key = try generateHexKey(bytesCount: 32)
        try set(account: "litellm-salt-key", value: key)
        return key
    }

    /// Retrieves a secret by account name. Returns nil if not found.
    /// Throws on a locked keychain rather than reporting "not found", so that
    /// `getOrCreate*` helpers do not silently mint a replacement key when the
    /// existing one is merely temporarily inaccessible.
    static func get(account: String) throws -> String? {
        // Try the file cache first (immune to code signature changes).
        if let value = readFromFile(account: account) {
            return value
        }

        // Fall back to keychain (works for production builds with stable signatures).
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        if status == errSecInteractionNotAllowed {
            // Keychain is locked. Surface this as an error so callers retry
            // (loadKeychainSecrets has built-in retry) instead of treating
            // it as "no entry exists" and rotating the key.
            throw KeychainError.unhandledError(status: status)
        }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.unhandledError(status: status)
        }

        // Backfill the file cache so future reads survive signature changes.
        writeToFile(account: account, value: value)
        return value
    }

    /// Stores a secret. Writes to both the file cache and the keychain.
    static func set(account: String, value: String) throws {
        // Always write to the file cache.
        writeToFile(account: account, value: value)

        // Best-effort write to the keychain.
        guard let data = value.data(using: .utf8) else { return }
        let query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)

        if addStatus == errSecDuplicateItem || addStatus == errSecInteractionNotAllowed {
            // Old item from a different signature blocks us. Delete via CLI and retry.
            shellDeleteKeychainItem(service: service, account: account)
            SecItemAdd(addQuery as CFDictionary, nil)
            // Ignore errors — the file cache is the authoritative store.
        }
    }

    /// Deletes a secret from both stores.
    static func delete(account: String) throws {
        deleteFile(account: account)
        let query = baseQuery(account: account)
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound
            && status != errSecInteractionNotAllowed {
            throw KeychainError.unhandledError(status: status)
        }
    }

    // MARK: - Key Generation

    private static func generateRandomKey(bytesCount: Int) throws -> String {
        return Data(try secureRandomBytes(count: bytesCount)).base64EncodedString()
    }

    /// Generates a hex-encoded random key (equivalent to `openssl rand -hex <bytesCount>`).
    private static func generateHexKey(bytesCount: Int) throws -> String {
        return try secureRandomBytes(count: bytesCount).map { String(format: "%02x", $0) }.joined()
    }

    /// Wraps `SecRandomCopyBytes` and propagates RNG failure rather than
    /// silently returning a zeroed buffer.
    private static func secureRandomBytes(count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            throw KeychainError.unhandledError(status: status)
        }
        return bytes
    }

    /// Generates a LiteLLM-compatible API key in the format `sk-<18 alphanumeric chars>`.
    /// Throws on RNG failure rather than minting a deterministic key from a zeroed buffer.
    static func generateLiteLLMKey() throws -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let bytes = try secureRandomBytes(count: 18)
        let suffix = String(bytes.map { chars[Int($0) % chars.count] })
        return "sk-\(suffix)"
    }

    // MARK: - File Cache

    private static func filePath(account: String) -> String {
        secretsDir + "/" + account
    }

    private static func readFromFile(account: String) -> String? {
        guard let data = FileManager.default.contents(atPath: filePath(account: account)),
              let value = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func writeToFile(account: String, value: String) {
        let dir = secretsDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Restrict permissions: owner read/write only.
        try? value.write(toFile: filePath(account: account), atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: filePath(account: account)
        )
    }

    private static func deleteFile(account: String) {
        try? FileManager.default.removeItem(atPath: filePath(account: account))
    }

    // MARK: - Shell Helpers

    /// Deletes all keychain items matching the service+account using the `security` CLI tool.
    private static func shellDeleteKeychainItem(service: String, account: String) {
        for _ in 0..<10 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = [
                "delete-generic-password",
                "-s", service,
                "-a", account,
                "login.keychain-db"
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 { break }
        }
    }
}

enum KeychainError: Error, LocalizedError {
    case unhandledError(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .unhandledError(let status):
            let msg = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown"
            return "Keychain error (\(status)): \(msg)"
        }
    }
}
