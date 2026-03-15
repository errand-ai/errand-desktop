import Foundation
import Security

/// Manages secrets in the macOS Keychain.
enum KeychainManager {

    private static let service = "sh.errand.ErrandDesktop"
    /// Base query attributes shared by all operations.
    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Retrieves a value from the Keychain, or creates and stores a new random one.
    static func getOrCreate(account: String, bytesCount: Int = 32) throws -> String {
        if let existing = try get(account: account) {
            return existing
        }
        let key = generateRandomKey(bytesCount: bytesCount)
        try set(account: account, value: key)
        return key
    }

    /// Retrieves the LiteLLM master key, or creates one in `sk-<18 alphanumeric>` format.
    static func getOrCreateLiteLLMKey() throws -> String {
        if let existing = try get(account: "litellm-master-key") {
            return existing
        }
        let key = generateLiteLLMKey()
        try set(account: "litellm-master-key", value: key)
        return key
    }

    /// Retrieves a Keychain item by account name. Returns nil if not found.
    static func get(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.unhandledError(status: status)
        }
        return value
    }

    /// Stores a value in the Keychain. Overwrites if the account already exists.
    static func set(account: String, value: String) throws {
        guard let data = value.data(using: .utf8) else { return }

        let query = baseQuery(account: account)

        // Delete any existing item first to avoid errSecDuplicateItem from stale
        // items left by a previous code signature.
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)

        if addStatus == errSecDuplicateItem {
            // Item exists but belongs to a different code signature (delete couldn't remove it).
            // Update in place instead.
            let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unhandledError(status: updateStatus)
            }
        } else if addStatus != errSecSuccess {
            throw KeychainError.unhandledError(status: addStatus)
        }
    }

    /// Deletes a Keychain item by account name.
    static func delete(account: String) throws {
        let query = baseQuery(account: account)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledError(status: status)
        }
    }

    // MARK: - Private

    private static func generateRandomKey(bytesCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: bytesCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytesCount, &bytes)
        return Data(bytes).base64EncodedString()
    }

    /// Generates a LiteLLM-compatible API key in the format `sk-<18 alphanumeric chars>`.
    static func generateLiteLLMKey() -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var bytes = [UInt8](repeating: 0, count: 18)
        _ = SecRandomCopyBytes(kSecRandomDefault, 18, &bytes)
        let suffix = String(bytes.map { chars[Int($0) % chars.count] })
        return "sk-\(suffix)"
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
