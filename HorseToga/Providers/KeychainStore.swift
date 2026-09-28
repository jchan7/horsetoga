//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import Foundation
import Security
import Synchronization

/// API keys live in the macOS Keychain, one generic-password item per provider —
/// never in UserDefaults, never on disk.
nonisolated enum KeychainStore {
    private static let service = "com.jasonchan.horsetoga.keys"

    /// One keychain hit per account per launch. Under ad-hoc dev signing every
    /// rebuild is a "new app" to the keychain, and each SecItemCopyMatching for
    /// data can re-raise the authorization dialog — so views polling get() must
    /// not touch the keychain repeatedly.
    private static let cache = Mutex<[String: String?]>([:])

    static func set(_ value: String, account: String) {
        deleteItem(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(query as CFDictionary, nil)
        cache.withLock { $0.updateValue(value, forKey: account) }
    }

    static func get(account: String) -> String? {
        let cached: String?? = cache.withLock { $0[account] }
        if let cached { return cached }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        var value: String?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data {
            value = String(data: data, encoding: .utf8)
        }
        cache.withLock { $0.updateValue(value, forKey: account) }
        return value
    }

    static func delete(account: String) {
        deleteItem(account: account)
        cache.withLock { $0.updateValue(nil, forKey: account) }
    }

    private static func deleteItem(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Attributes-only existence probe for ANOTHER app's keychain item (e.g. the
    /// claude CLI's "Claude Code-credentials") — never reads the secret itself.
    static func externalItemExists(service: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }
}
