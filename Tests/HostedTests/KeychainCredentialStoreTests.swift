import Foundation
import Security
import Testing
import YuvomiCore

/// Läuft gegen den echten Keychain des Simulators. Jeder Test nutzt einen eigenen Dienstnamen,
/// damit sich Läufe nicht gegenseitig stören.
@Suite struct KeychainCredentialStoreTests {
    let store = KeychainCredentialStore(service: "cloud.yuvomi.tests.\(UUID().uuidString)", accessGroup: nil)
    let home = URL(string: "https://yuvomi.example.com")!
    let other = URL(string: "http://192.168.1.5:3000")!

    @Test func storesOneCredentialPerServer() throws {
        try store.save("ydc_home", for: home)

        #expect(try store.credential(for: home) == "ydc_home")
        #expect(try store.credential(for: other) == nil)
    }

    @Test func savingAgainReplacesTheCredential() throws {
        try store.save("ydc_old", for: home)
        try store.save("ydc_new", for: home)
        #expect(try store.credential(for: home) == "ydc_new")
    }

    @Test func deleteRemovesOnlyThatServer() throws {
        try store.save("ydc_home", for: home)
        try store.save("ydc_other", for: other)

        try store.delete(for: home)
        try store.delete(for: home) // zweites Löschen ist kein Fehler

        #expect(try store.credential(for: home) == nil)
        #expect(try store.credential(for: other) == "ydc_other")
    }

    /// Q13: nach dem ersten Entsperren lesbar, nie im iCloud-Schlüsselbund oder Backup.
    @Test func credentialStaysOnThisDeviceAndIsReadableAfterFirstUnlock() throws {
        try store.save("ydc_home", for: home)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: store.service,
            kSecAttrAccount as String: home.absoluteString,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
        let attributes = try #require(result as? [String: Any])
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    /// Das Entitlement aus `project.yml` greift: Der Eintrag landet in der Gruppe, die
    /// später auch Widgets lesen.
    @Test func sharedAccessGroupIsAvailableToTheApp() throws {
        let shared = KeychainCredentialStore(service: store.service, accessGroup: KeychainCredentialStore.sharedAccessGroup)
        try shared.save("ydc_home", for: home)
        defer { try? shared.delete(for: home) }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: store.service,
            kSecAttrAccount as String: home.absoluteString,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
        let attributes = try #require(result as? [String: Any])
        #expect(attributes[kSecAttrAccessGroup as String] as? String == KeychainCredentialStore.sharedAccessGroup)
    }
}
