import Foundation
import Security

/// Secret bytes live only in this boundary. Normal persistence stores an opaque reference.
public protocol CredentialStore: Sendable {
    func read(reference: MailCredentialReference) async throws -> Data?
    func write(_ data: Data, reference: MailCredentialReference) async throws
    func delete(reference: MailCredentialReference) async throws
}

public enum CredentialError: Error, LocalizedError, Sendable {
    case unavailable, invalidReference, missing
    public var errorDescription: String? {
        switch self {
        case .unavailable: "Keychain is unavailable. Unlock your login Keychain and try again."
        case .invalidReference: "The account credential reference is invalid."
        case .missing: "Credentials are unavailable. Reconnect this account."
        }
    }
}

public actor KeychainCredentialStore: CredentialStore {
    private let service: String
    public init(service: String = "com.flora.mail.credentials") { self.service = service }
    private func query(_ reference: MailCredentialReference) throws -> [String: Any] {
        guard !reference.id.isEmpty, reference.id.count <= 200 else { throw CredentialError.invalidReference }
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: reference.id, kSecAttrSynchronizable as String: false]
    }
    public func read(reference: MailCredentialReference) throws -> Data? {
        var query = try query(reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CredentialError.unavailable }
        return data
    }
    public func write(_ data: Data, reference: MailCredentialReference) throws {
        let query = try query(reference)
        let attributes = [kSecValueData as String: data]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            var new = query
            new[kSecValueData as String] = data
            new[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(new as CFDictionary, nil) == errSecSuccess else { throw CredentialError.unavailable }
        } else if update != errSecSuccess { throw CredentialError.unavailable }
    }
    public func delete(reference: MailCredentialReference) throws {
        let status = SecItemDelete(try query(reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError.unavailable }
    }
}

/// Explicit test seam; the application composition root uses KeychainCredentialStore.
public actor MemoryCredentialStore: CredentialStore {
    private var items: [String: Data] = [:]
    public init() {}
    public func read(reference: MailCredentialReference) -> Data? { items[reference.id] }
    public func write(_ data: Data, reference: MailCredentialReference) { items[reference.id] = data }
    public func delete(reference: MailCredentialReference) { items[reference.id] = nil }
}
