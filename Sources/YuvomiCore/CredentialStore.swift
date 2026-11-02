import Foundation
import Security

/// Ablage des Device Credentials, ein Eintrag pro Serveradresse.
///
/// Pro Adresse statt eines einzigen Eintrags, damit mehrere Konten später ohne Migration
/// gehen (Q16). Die Adresse kommt normalisiert aus `ServerCheck`.
public protocol CredentialStore: Sendable {
    func credential(for server: URL) throws -> String?
    func save(_ credential: String, for server: URL) throws
    func delete(for server: URL) throws
}

public struct KeychainError: Error, Hashable, Sendable {
    public let status: OSStatus
}

/// `CredentialStore` im Keychain.
///
/// Lesbar ab dem ersten Entsperren nach einem Neustart, damit Hintergrund-Abrufe und
/// spätere Widgets das Credential bekommen; nur auf diesem Gerät, also weder im
/// iCloud-Schlüsselbund noch in einem Backup (Q13).
public struct KeychainCredentialStore: CredentialStore {
    public let service: String
    let accessGroup: String?

    /// - Parameter accessGroup: Geteilte Gruppe für App und Erweiterungen. `nil` in Tests,
    ///   weil eine Gruppe ein signiertes Target mit Entitlement braucht.
    public init(service: String = "cloud.yuvomi.device-credential", accessGroup: String?) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func credential(for server: URL) throws -> String? {
        var query = baseQuery(for: server)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    public func save(_ credential: String, for server: URL) throws {
        let values: [String: Any] = [
            kSecValueData as String: Data(credential.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery(for: server) as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            let item = baseQuery(for: server).merging(values) { _, new in new }
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    public func delete(for server: URL) throws {
        let status = SecItemDelete(baseQuery(for: server) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private func baseQuery(for server: URL) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: server.absoluteString,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
