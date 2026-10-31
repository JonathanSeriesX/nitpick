import Foundation

/// Connection life cycle. `.pairing` means the TV shows its Accept/Decline prompt: tell the user to press Accept.
public enum SSAPState: Sendable {
    case connecting
    case pairing
    case registered
    case disconnected((any Error)?)
}

/// The TV's `hello` reply (SPEC §3.3).
public struct SSAPHello: Sendable, Equatable {
    public var deviceUUID: String?
    /// e.g. `4.1.0`. Meaning differs from the release number; kept for diagnostics.
    public var deviceOSVersion: String?
    /// Platform release, e.g. `9.2.2` (webOS 24), `10.3.0` (webOS 25), `11.1.0` (webOS 26).
    public var deviceOSReleaseVersion: String?
    public var pairingTypes: [String]

    public init(payload: JSON) {
        deviceUUID = payload["deviceUUID"]?.stringValue
        deviceOSVersion = payload["deviceOSVersion"]?.stringValue
        deviceOSReleaseVersion = payload["deviceOSReleaseVersion"]?.stringValue
        pairingTypes = payload["pairingTypes"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    public var release: WebOSRelease? { deviceOSReleaseVersion.flatMap(WebOSRelease.init(version:)) }
}

/// Outcome of pairing.
public struct SSAPRegistrationResult: Sendable, Equatable {
    /// Stable TV id (SSDP UDN / hello `deviceUUID`, lowercase, without `uuid:`); the credential-store key.
    public var tvID: String
    public var clientKey: String
    public var manifest: SSAPManifestKind
    public var release: WebOSRelease?
    /// False with manifest B or on webOS 26: externalpq answers `401` there, so the app must not offer calibration.
    public var calibrationAPIAvailable: Bool
}

/// SSAP registration with the manifest strategy of SPEC §3.4:
/// release ≥ 11 → manifest B; otherwise manifest A, and on `403 … blacklisted certificate` one fresh socket with B.
/// At most two register attempts per call: it never loops on re-pairing (SPEC §0 consequence 2).
public enum SSAPRegistration {
    /// The `register` payload. `client-key` is null on first pairing.
    public static func payload(manifest: SSAPManifestKind, clientKey: String?) -> JSON {
        [
            "client-key": clientKey.map(JSON.string) ?? .null, "forcePairing": false,
            "manifest": SSAPManifests.manifest(manifest), "pairingType": "PROMPT",
        ]
    }

    /// Manifest to try first.
    public static func initialManifest(release: WebOSRelease?, stored: TVCredentials?) -> SSAPManifestKind {
        if release?.blocksThirdPartyCalibration == true { return .unsigned }
        if release == nil, stored?.manifest == .unsigned { return .unsigned }
        return .signedLegacy
    }

    static func isBlacklisted(_ error: any Error) -> Bool {
        guard case .server(403, let message, _) = error as? LGError else { return false }
        return message.localizedCaseInsensitiveContains("blacklisted")
    }

    /// `uuid:6DA6…` → `6da6…`.
    public static func normalizedID(_ id: String) -> String {
        (id.lowercased().hasPrefix("uuid:") ? String(id.dropFirst(5)) : id).lowercased()
    }

    /// Opens a connection with `open` (which must call `SSAPConnection.open()`), checks the pinned certificate, and
    /// registers. The client key, certificate fingerprint and manifest are stored before this returns.
    /// - Parameters:
    ///   - tvID: known id (from discovery) so the pinned certificate can be enforced inside the TLS handshake;
    ///     nil uses hello `deviceUUID` and checks the pin right after hello, before any key is sent.
    ///   - open: makes and opens a fresh connection; receives the pinned fingerprint, if known.
    /// - Throws: `LGError.pairingDenied`, `.pairingRejected`, `.timeout("pairing prompt")`, `.certificateChanged`.
    public static func pair(
        tvID: String?, store: any TVCredentialStore, promptTimeout: Duration = .seconds(60),
        open: @Sendable (_ pinnedFingerprint: String?) async throws -> SSAPConnection
    )
        async throws -> (SSAPConnection, SSAPRegistrationResult)
    {
        let known = tvID.map(normalizedID)
        var connection = try await open(known.flatMap(store.credentials)?.certificateFingerprint)
        do {
            let hello = await connection.hello
            let id = known ?? hello?.deviceUUID.map(normalizedID) ?? connection.host
            let stored = store.credentials(for: id)
            try CertificatePinning.check(pinned: stored?.certificateFingerprint, presented: await connection.certificateFingerprint)

            let release = hello?.release
            var kind = initialManifest(release: release, stored: stored)
            // aiowebostv: newer webOS wants system info before `register` (SPEC §3.3; on the B4: UNCONFIRMED, (b)4).
            func register(_ c: SSAPConnection, _ kind: SSAPManifestKind) async throws -> JSON {
                _ = try? await c.request("system/getSystemInfo")
                return try await c.register(
                    payload(manifest: kind, clientKey: stored?.manifest == kind ? stored?.clientKey : nil),
                    timeout: promptTimeout)
            }
            var reply: JSON
            do {
                reply = try await register(connection, kind)
            } catch  where kind == .signedLegacy && isBlacklisted(error) {
                await connection.close()
                connection = try await open(stored?.certificateFingerprint)
                kind = .unsigned
                reply = try await register(connection, kind)
            }
            guard let key = reply["client-key"]?.stringValue, !key.isEmpty else {
                throw LGError.malformedResponse("registered without client-key")
            }
            let fingerprint = await connection.certificateFingerprint ?? stored?.certificateFingerprint
            try store.save(TVCredentials(clientKey: key, certificateFingerprint: fingerprint, manifest: kind), for: id)
            let available = kind == .signedLegacy && release?.blocksThirdPartyCalibration != true
            return (
                connection,
                SSAPRegistrationResult(
                    tvID: id, clientKey: key, manifest: kind, release: release,
                    calibrationAPIAvailable: available)
            )
        } catch {
            await connection.close()
            if case .server(403, let message, _) = error as? LGError {
                throw message.localizedCaseInsensitiveContains("cancel") ? LGError.pairingDenied : LGError.pairingRejected(message)
            }
            if case .server(_, let message, _) = error as? LGError { throw LGError.pairingRejected(message) }
            throw error
        }
    }
}
