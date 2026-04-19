import Testing
@testable import ChatbaseSDK
import Foundation

@Suite("DeviceId migration")
struct DeviceIdMigrationTests {

    private func withIsolation(_ body: (_ defaults: UserDefaults, _ keychainKey: String, _ legacyKey: String) -> Void) {
        let suite = "ChatbaseSDKTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let legacyKey = "com.chatbase.sdk.deviceId"
        let keychainKey = "deviceId-\(UUID().uuidString)"
        defer {
            defaults.removePersistentDomain(forName: suite)
            Keychain.delete(account: keychainKey)
        }
        body(defaults, keychainKey, legacyKey)
    }

    @Test("keychain hit wins over legacy userdefaults")
    func keychainHitWins() {
        withIsolation { defaults, keychainKey, legacyKey in
            Keychain.set("kc-value", account: keychainKey)
            defaults.set("ud-value", forKey: legacyKey)
            let resolved = DeviceIdResolver.resolve(
                defaults: defaults,
                keychainAccount: keychainKey,
                legacyKey: legacyKey
            )
            #expect(resolved == "kc-value")
        }
    }

    @Test("keychain miss + userdefaults hit migrates value into keychain")
    func migrateFromUserDefaults() {
        withIsolation { defaults, keychainKey, legacyKey in
            defaults.set("legacy-value", forKey: legacyKey)
            let resolved = DeviceIdResolver.resolve(
                defaults: defaults,
                keychainAccount: keychainKey,
                legacyKey: legacyKey
            )
            #expect(resolved == "legacy-value")
            #expect(Keychain.get(account: keychainKey) == "legacy-value")
        }
    }

    @Test("both miss generates a new UUID and writes it to keychain")
    func generatesFresh() {
        withIsolation { defaults, keychainKey, legacyKey in
            let resolved = DeviceIdResolver.resolve(
                defaults: defaults,
                keychainAccount: keychainKey,
                legacyKey: legacyKey
            )
            #expect(UUID(uuidString: resolved) != nil)
            #expect(Keychain.get(account: keychainKey) == resolved)
        }
    }
}

@Suite("ChatbaseClient currentUserId")
struct CurrentUserIdTests {

    @Test("currentUserId is nil when anonymous, populated when identified")
    func currentUserIdReflectsAuthState() async throws {
        let mock = MockAPIClient()
        let svc = ChatService(
            client: mock,
            agentId: "a",
            baseURL: "https://x",
            deviceId: "d"
        )
        let client = ChatbaseClient(service: svc)

        #expect(client.currentUserId == nil)
        #expect(client.isIdentified == false)

        mock.respondWithRawJSON("""
        {"data": {"userId": "u-1"}}
        """)
        try await client.identify(token: "jwt")

        #expect(client.currentUserId == "u-1")
        #expect(client.isIdentified == true)
    }
}
