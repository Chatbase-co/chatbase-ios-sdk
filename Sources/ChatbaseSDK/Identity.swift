import Foundation
import os

private let identityLogger = Logger(subsystem: "com.chatbase.sdk", category: "Identity")

// MARK: - Device ID

/// Testable resolver for the device id with Keychain + legacy UserDefaults fallback.
enum DeviceIdResolver {
    static func resolve(
        defaults: UserDefaults = .standard,
        keychainAccount: String = "deviceId",
        legacyKey: String = "com.chatbase.sdk.deviceId"
    ) -> String {
        if let kc = Keychain.get(account: keychainAccount) { return kc }
        if let legacy = defaults.string(forKey: legacyKey) {
            Keychain.set(legacy, account: keychainAccount)
            return legacy
        }
        let fresh = UUID().uuidString
        Keychain.set(fresh, account: keychainAccount)
        return fresh
    }
}

/// Stable per-install device identifier, persisted to Keychain (migrating from legacy UserDefaults on first launch).
public enum DeviceId {
    // Swift guarantees static stored property initializers run exactly once,
    // atomically, across threads.
    private static let value: String = DeviceIdResolver.resolve()
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

/// Session auth state. Anonymous = device-id only; identified = verified JWT + userId.
public enum AuthState: Sendable, Equatable {
    case anonymous
    case identified(token: String, userId: String)
}

// MARK: - Identity persistence

/// Keychain-backed store for the identified session. Anonymous = nothing persisted.
enum Identity {
    private static let tokenAccount = "userToken"
    private static let userIdAccount = "userId"

    static func load() -> AuthState {
        guard
            let token = Keychain.get(account: tokenAccount),
            let userId = Keychain.get(account: userIdAccount)
        else { return .anonymous }
        return .identified(token: token, userId: userId)
    }

    static func save(_ state: AuthState) {
        switch state {
        case .anonymous:
            Keychain.delete(account: tokenAccount)
            Keychain.delete(account: userIdAccount)
        case .identified(let token, let userId):
            Keychain.set(token, account: tokenAccount)
            Keychain.set(userId, account: userIdAccount)
        }
    }
}
