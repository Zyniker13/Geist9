/// The Keychain backend (DESIGN 4, "Credentials and 1Password").
///
/// Generic-password items, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`,
/// shared with the login item through a Keychain access group. The Security
/// calls sit behind `KeychainClient` so the wrapper's logic (key scheme,
/// error mapping, rotate semantics) is testable with a fake client on every
/// platform (TESTING, "Unit": "Keychain wrapper (mocked)").
import Foundation

/// One Keychain item, addressed the way the app addresses every secret:
/// a service plus the store key (for example `account:<id>:password`).
public struct KeychainItem: Sendable, Equatable {
    public let service: String
    public let account: String
    public let secret: Data

    public init(service: String, account: String, secret: Data) {
        self.service = service
        self.account = account
        self.secret = secret
    }
}

/// The narrow surface of the Keychain the store needs. `SecurityKeychainClient`
/// (Darwin) implements it against the Security framework; tests use
/// `FakeKeychainClient`.
public protocol KeychainClient: Sendable {
    func read(service: String, account: String) throws -> Data
    func write(service: String, account: String, secret: Data) throws
    func remove(service: String, account: String) throws
}

/// The store every Keychain-backed account uses.
///
/// `service` is the app's fixed service name; `accessGroup` (when the app is
/// signed with a Keychain access group) lets the login item read the same
/// items. The client is injectable so the wrapper is testable without the
/// real Keychain.
public struct KeychainCredentialStore: CredentialStore {
    public let service: String
    public let accessGroup: String?
    private let client: KeychainClient

    public init(
        service: String,
        accessGroup: String? = nil,
        client: KeychainClient
    ) {
        self.service = service
        self.accessGroup = accessGroup
        self.client = client
    }

    public func get(_ key: String) async throws -> Data {
        try client.read(service: service, account: key)
    }

    public func put(_ key: String, secret: Data) async throws {
        try client.write(service: service, account: key, secret: secret)
    }

    public func delete(_ key: String) async throws {
        try client.remove(service: service, account: key)
    }

    public func rotate(_ key: String, to newSecret: Data) async throws {
        // A rotate that would create a new item is a bug in the caller:
        // refresh tokens only rotate for accounts that already have one.
        do {
            _ = try client.read(service: service, account: key)
        } catch let error as CredentialError where error == .notFound {
            throw CredentialError.notFound
        }
        try client.write(service: service, account: key, secret: newSecret)
    }
}

#if canImport(Security)
import Security

/// The real Keychain client. Every item is a generic password with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so it never
/// auto-unlocks and never leaves this device (DESIGN 4).
public struct SecurityKeychainClient: KeychainClient {
    public let accessGroup: String?

    public init(accessGroup: String? = nil) {
        self.accessGroup = accessGroup
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    public func read(service: String, account: String) throws -> Data {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw CredentialError.unavailable("Keychain item has no data")
            }
            return data
        case errSecItemNotFound:
            throw CredentialError.notFound
        default:
            throw CredentialError.unavailable("Keychain read failed: \(status)")
        }
    }

    public func write(service: String, account: String, secret: Data) throws {
        let attributes: [String: Any] = [
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: secret,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var query = baseQuery(service: service, account: account)
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = attributes
            if let accessGroup {
                add[kSecAttrAccessGroup as String] = accessGroup
            }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw CredentialError.unavailable("Keychain add failed: \(addStatus)")
            }
        default:
            throw CredentialError.unavailable("Keychain write failed: \(status)")
        }
    }

    public func remove(service: String, account: String) throws {
        let query = baseQuery(service: service, account: account)
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return // removing an absent item is not an error
        default:
            throw CredentialError.unavailable("Keychain delete failed: \(status)")
        }
    }
}
#endif
