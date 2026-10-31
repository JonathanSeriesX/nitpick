import Foundation
import Security

// MARK: - Apple TV side

/// Pairing tokens the TV has issued, keyed by client (Mac) id, plus the TV's own stable device id.
public protocol PairingStore: Sendable {
    func token(for clientID: UUID) -> Data?
    func setToken(_ token: Data?, for clientID: UUID)
    func allClientIDs() -> [UUID]
    /// The TV's stable id, created on first use. Sent to clients in `PairResponse.deviceID`.
    func deviceID() -> UUID
}

/// Pairing store for tests and previews.
public final class InMemoryPairingStore: PairingStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [UUID: Data] = [:]
    private let id: UUID

    public init(deviceID: UUID = UUID()) { id = deviceID }
    public func token(for clientID: UUID) -> Data? { lock.withLock { tokens[clientID] } }
    public func setToken(_ token: Data?, for clientID: UUID) {
        lock.withLock { tokens[clientID] = token }
    }
    public func allClientIDs() -> [UUID] { lock.withLock { Array(tokens.keys) } }
    public func deviceID() -> UUID { id }
}

/// Pairing store in `UserDefaults`: tokens as base64 strings in one dictionary under one key.
///
/// Acceptable for the TV: a token only lets a Mac draw test patterns, and tvOS app containers are not user-browsable.
/// A Keychain store would be the upgrade if tokens ever grant more.
public final class UserDefaultsPairingStore: PairingStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()
    private let tokensKey = "PatternLink.pairingTokens"
    private let deviceIDKey = "PatternLink.deviceID"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private var tokens: [String: String] {
        defaults.dictionary(forKey: tokensKey) as? [String: String] ?? [:]
    }

    public func token(for clientID: UUID) -> Data? {
        lock.withLock { tokens[clientID.uuidString].flatMap { Data(base64Encoded: $0) } }
    }

    public func setToken(_ token: Data?, for clientID: UUID) {
        lock.withLock {
            var all = tokens
            all[clientID.uuidString] = token?.base64EncodedString()
            defaults.set(all, forKey: tokensKey)
        }
    }

    public func allClientIDs() -> [UUID] {
        lock.withLock { tokens.keys.compactMap(UUID.init(uuidString:)) }
    }

    public func deviceID() -> UUID {
        lock.withLock {
            if let id = defaults.string(forKey: deviceIDKey).flatMap(UUID.init(uuidString:)) { return id }
            let id = UUID()
            defaults.set(id.uuidString, forKey: deviceIDKey)
            return id
        }
    }
}

// MARK: - Mac side

/// Pairing tokens the Mac received, keyed by the TV's `PairResponse.deviceID`.
public protocol ClientCredentialStore: Sendable {
    func token(for deviceID: UUID) -> Data?
    /// Stores (or with `nil`, removes) the token for a TV.
    func setToken(_ token: Data?, for deviceID: UUID) throws
}

/// Credential store for tests.
public final class InMemoryCredentialStore: ClientCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [UUID: Data] = [:]

    public init() {}
    public func token(for deviceID: UUID) -> Data? { lock.withLock { tokens[deviceID] } }
    public func setToken(_ token: Data?, for deviceID: UUID) {
        lock.withLock { tokens[deviceID] = token }
    }
}

/// Keychain credential store: one generic password per TV (service `com.jonathanseriesx.nitpick.patternlink`,
/// account = TV device id).
public final class KeychainCredentialStore: ClientCredentialStore {
    public static let service = "com.jonathanseriesx.nitpick.patternlink"

    public init() {}

    private func query(_ deviceID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: deviceID.uuidString,
        ]
    }

    public func token(for deviceID: UUID) -> Data? {
        var query = query(deviceID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    public func setToken(_ token: Data?, for deviceID: UUID) throws {
        let query = query(deviceID)
        let deleted = SecItemDelete(query as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else {
            throw Self.error(deleted)
        }
        guard let token else { return }
        var item = query
        item[kSecValueData as String] = token
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw Self.error(added) }
    }

    private static func error(_ status: OSStatus) -> NSError {
        NSError(
            domain: NSOSStatusErrorDomain, code: Int(status),
            userInfo: [
                NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String?
                    ?? "Keychain error \(status)"
            ])
    }
}
