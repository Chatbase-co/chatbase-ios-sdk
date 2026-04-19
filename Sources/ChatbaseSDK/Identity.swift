import Foundation
import os

private let identityLogger = Logger(subsystem: "com.chatbase.sdk", category: "Identity")

// MARK: - Device ID

/// Stable per-install device identifier persisted to UserDefaults.
public enum DeviceId {
    private static let storageKey = "com.chatbase.sdk.deviceId"

    // Swift guarantees static stored property initializers run exactly once,
    // atomically, across threads. This removes the read-then-write TOCTOU
    // on cold start without introducing a lock.
    private static let value: String = {
        let defaults = UserDefaults.standard
        if let cached = defaults.string(forKey: storageKey) { return cached }
        let id = UUID().uuidString
        defaults.set(id, forKey: storageKey)
        return id
    }()

    public static func get() -> String { value }
}

// MARK: - Keychain

enum Keychain {
    static let service = "com.chatbase.sdk"

    static func set(_ value: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            identityLogger.error("Keychain write failed (status \(status)) for account \(account)")
        }
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Auth State

/// Session auth state. Anonymous = device-id only; identified = verified JWT.
public enum AuthState: Sendable, Equatable {
    case anonymous
    case identified(token: String)
}

// MARK: - Identity persistence

/// Keychain-backed store for the identified session. Anonymous = nothing persisted.
enum Identity {
    private static let tokenAccount = "userToken"

    static func load() -> AuthState {
        guard let token = Keychain.get(account: tokenAccount) else { return .anonymous }
        return .identified(token: token)
    }

    static func save(_ state: AuthState) {
        switch state {
        case .anonymous:
            Keychain.delete(account: tokenAccount)
        case .identified(let token):
            Keychain.set(token, account: tokenAccount)
        }
    }
}
