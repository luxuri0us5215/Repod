import Foundation
import Security

/// This Keychain item contains Spotify OAuth tokens only. Configuration stays in UserDefaults.
enum TokenKeychain {
    private static let service = "com.qiuhaoyu.ipodplayer.spotify.tokens"
    private static let account = "oauth"

    static func read() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.unavailable
        }
        return data
    }

    static func save(_ tokenData: Data) throws {
        let attributes: [String: Any] = [kSecValueData as String: tokenData]
        var status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery
            item[kSecValueData as String] = tokenData
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.unavailable }
    }

    static func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unavailable
        }
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private enum KeychainError: LocalizedError {
        case unavailable
        var errorDescription: String? { "无法读取或保存 Spotify 登录凭据，请解锁设备后重试。" }
    }
}

/// The cookie and its server binding share one device-only Keychain item.
enum NetEaseCookieKeychain {
    private static let service = "com.qiuhaoyu.ipodplayer.netease.session"
    private static let account = "cookie"

    private struct StoredSession: Codable {
        let serverURL: String
        let cookie: String
    }

    /// The cookie belongs to the NetEase account, not to the proxy server, so
    /// it is returned regardless of which server address is configured.
    /// Switching between the VPS and the Mac server must not force a re-login.
    static func read() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.unavailable
        }
        guard let saved = try? JSONDecoder().decode(StoredSession.self, from: data),
              !saved.cookie.isEmpty else {
            return nil
        }
        return saved.cookie
    }

    static func save(_ cookie: String, baseURL: String) throws {
        let data = try JSONEncoder().encode(StoredSession(serverURL: baseURL, cookie: cookie))
        let attributes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.unavailable }
    }

    static func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unavailable
        }
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private enum KeychainError: LocalizedError {
        case unavailable
        var errorDescription: String? { "无法读取或保存网易云登录凭据，请解锁设备后重试。" }
    }
}
