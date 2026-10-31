import CryptoKit
import Foundation
import Security
import Synchronization

/// Which registration manifest produced a client key. Keys from different manifests carry different rights (SPEC §3.4).
public enum SSAPManifestKind: String, Codable, Sendable {
    /// Manifest A, the signed `com.lge.test` manifest: full rights on webOS ≤ 25, blacklisted on webOS 26.
    case signedLegacy
    /// Manifest B, unsigned: pairs on webOS 26 but gets no calibration or settings-write rights.
    case unsigned
}

/// What the app remembers per TV: the pairing key and the pinned TLS certificate.
public struct TVCredentials: Codable, Sendable, Hashable {
    /// The TV's `client-key` (32 hex chars).
    public var clientKey: String?
    /// SHA-256 of the TV's TLS leaf certificate (DER), lowercase hex without separators. Pinned on first use.
    public var certificateFingerprint: String?
    public var manifest: SSAPManifestKind?

    public init(clientKey: String? = nil, certificateFingerprint: String? = nil, manifest: SSAPManifestKind? = nil) {
        self.clientKey = clientKey
        self.certificateFingerprint = certificateFingerprint
        self.manifest = manifest
    }
}

/// Per-TV credential storage, keyed by the TV's stable id (SSDP UDN / hello `deviceUUID` without `uuid:`), never by IP.
public protocol TVCredentialStore: Sendable {
    /// Nil only when nothing is stored. A store that cannot read must throw: treating that as "not paired" would skip
    /// the pinned-certificate check and re-pair on trust-on-first-use.
    func credentials(for tvID: String) throws -> TVCredentials?
    func save(_ credentials: TVCredentials, for tvID: String) throws
    func remove(tvID: String) throws
}

/// Trust-on-first-use certificate pinning.
public enum CertificatePinning {
    /// Lowercase hex SHA-256 of DER bytes.
    public static func fingerprint(der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// Accepts any certificate when nothing is pinned (first pairing); otherwise the presented one must match.
    /// A plain `ws://` connection presents nothing (`nil`) and is refused once a certificate is pinned.
    public static func check(pinned: String?, presented: String?) throws {
        guard let pinned else { return }
        guard presented == pinned else { throw LGError.certificateChanged(pinned: pinned, presented: presented ?? "none (plain ws)") }
    }
}

/// Test and preview store.
public final class InMemoryTVCredentialStore: TVCredentialStore {
    private let entries = Mutex<[String: TVCredentials]>([:])

    public init(_ initial: [String: TVCredentials] = [:]) { entries.withLock { $0 = initial } }

    public func credentials(for tvID: String) -> TVCredentials? { entries.withLock { $0[tvID] } }
    public func save(_ credentials: TVCredentials, for tvID: String) { entries.withLock { $0[tvID] = credentials } }
    public func remove(tvID: String) { entries.withLock { $0[tvID] = nil } }
}

/// Keychain store: one generic-password item per TV (service `com.jonathanseriesx.nitpick.lgtv`, account = TV id),
/// holding `TVCredentials` as JSON.
public struct KeychainTVCredentialStore: TVCredentialStore {
    public let service: String

    public init(service: String = "com.jonathanseriesx.nitpick.lgtv") { self.service = service }

    private func query(_ tvID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: tvID]
    }

    public func credentials(for tvID: String) throws -> TVCredentials? {
        var q = query(tvID)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw LGError.unsupported("Keychain read failed (OSStatus \(status))")
        }
        return try JSONDecoder().decode(TVCredentials.self, from: data)
    }

    public func save(_ credentials: TVCredentials, for tvID: String) throws {
        let data = try JSONEncoder().encode(credentials)
        var status = SecItemUpdate(query(tvID) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(tvID)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw LGError.unsupported("Keychain write failed (OSStatus \(status))") }
    }

    public func remove(tvID: String) throws {
        let status = SecItemDelete(query(tvID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LGError.unsupported("Keychain delete failed (OSStatus \(status))")
        }
    }
}
