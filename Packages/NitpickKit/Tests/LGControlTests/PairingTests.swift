import Foundation
import Synchronization
import Testing

@testable import LGControl

@Suite struct PairingTests {
    static let tvID = "6da62662-1369-a82d-95c7-353c235ed503"

    @Test func firstPairingPromptsThenStoresKey() async throws {
        let store = InMemoryTVCredentialStore()
        let (fake, tv) = try await makeTV(store: store)
        let states = Task { () -> [String] in
            var seen: [String] = []
            for await s in tv.state {
                switch s {
                case .connecting: seen.append("connecting")
                case .pairing: seen.append("pairing")
                case .registered:
                    seen.append("registered")
                    return seen
                case .disconnected:
                    seen.append("disconnected")
                    return seen
                }
            }
            return seen
        }
        let result = try await tv.connect(host: "127.0.0.1")
        #expect(await states.value == ["connecting", "pairing", "registered"])
        #expect(result.tvID == Self.tvID)
        #expect(result.manifest == .signedLegacy)
        #expect(result.calibrationAPIAvailable)
        #expect(result.release == WebOSRelease(major: 10, minor: 3))
        let stored = try #require(store.credentials(for: Self.tvID))
        #expect(stored.clientKey == result.clientKey && stored.clientKey?.count == 32)
        #expect(stored.manifest == .signedLegacy)
        #expect(await fake.issuedKeys[result.clientKey] == .signedLegacy)

        // The register frame is the SPEC §3.4 payload with manifest A, verbatim.
        let register = try #require(await fake.requests.first { $0["type"] == "register" })
        #expect(register["payload"] == SSAPRegistration.payload(manifest: .signedLegacy, clientKey: nil))
        #expect(register["payload"]?["manifest"]?["signed"]?["appId"] == "com.lge.test")
        #expect(register["payload"]?["client-key"] == .null && register["payload"]?["pairingType"] == "PROMPT")

        // Reconnecting with the stored key registers without a prompt.
        await tv.disconnect()
        let again = try await tv.connect(host: "127.0.0.1", id: "uuid:" + Self.tvID.uppercased())
        #expect(again.clientKey == result.clientKey)
        let registers = await fake.requests.filter { $0["type"] == "register" }
        #expect(registers.count == 2 && registers[1]["payload"]?["client-key"] == .string(result.clientKey))
        await fake.stop()
    }

    @Test func declinedPromptIsPairingDenied() async throws {
        let store = InMemoryTVCredentialStore()
        let (fake, tv) = try await makeTV(.init(pairing: .deny(after: .milliseconds(20))), store: store)
        await #expect(throws: LGError.pairingDenied) { try await tv.connect(host: "127.0.0.1") }
        #expect(store.credentials(for: Self.tvID) == nil)
        #expect(await fake.requests.filter { $0["type"] == "register" }.count == 1)
        await fake.stop()
    }

    @Test func unansweredPromptTimesOut() async throws {
        let (fake, tv) = try await makeTV(.init(pairing: .ignore), promptTimeout: .milliseconds(300))
        await #expect(throws: LGError.timeout("pairing prompt")) { try await tv.connect(host: "127.0.0.1") }
        await fake.stop()
    }

    @Test func webOS26FallsBackToUnsignedManifestOnce() async throws {
        let store = InMemoryTVCredentialStore()
        let (fake, tv) = try await makeTV(.init(platform: .webOS26), store: store)
        // hello says 11.1.0, so manifest B goes first; no blacklisted round trip.
        let result = try await tv.connect(host: "127.0.0.1")
        #expect(result.manifest == .unsigned && !result.calibrationAPIAvailable)
        #expect(store.credentials(for: Self.tvID)?.manifest == .unsigned)
        await #expect(throws: LGError.calibrationUnavailable(reason: "webOS 26 blocks third-party calibration (LG removed it in webOS 26)"))
        {
            _ = try await tv.calibration()
        }
        let sw = await lgError { _ = try await tv.softwareInfo() }
        #expect(sw?.serverCode == 401)
        #expect(try await tv.systemInfo().software == nil)
        await fake.stop()
    }

    /// Pairs against a webOS 26 fake whose hello omits the release, so manifest A is tried first.
    private func pairWithoutRelease(_ pairing: FakeWebOSServer.Pairing) async throws -> (
        FakeWebOSServer, Int, Result<SSAPRegistrationResult, any Error>
    ) {
        let fake = FakeWebOSServer(configuration: .init(platform: .webOS26, pairing: pairing, reportsReleaseInHello: false))
        let port = try await fake.start()
        let opened = Counter()
        let result: Result<SSAPRegistrationResult, any Error>
        do {
            let (connection, r) = try await SSAPRegistration.pair(
                tvID: Self.tvID, store: InMemoryTVCredentialStore(), promptTimeout: .seconds(3)
            ) { pinned in
                opened.increment()
                let c = SSAPConnection(host: "127.0.0.1", options: .init(port: port, allowInsecure: true, pinnedFingerprint: pinned))
                try await c.open()
                return c
            }
            result = .success(r)
            // externalpq on the B pairing answers 401 → calibrationUnavailable.
            let cal = LGCalibration(connection: connection, profile: LGModelProfile(modelName: "W24H"), settleDelay: .zero)
            await #expect(throws: LGError.calibrationUnavailable(reason: "401 insufficient permissions")) { try await cal.start(.expert2) }
            await connection.close()
        } catch {
            result = .failure(error)
        }
        return (fake, opened.value, result)
    }

    @Test func blacklistedSignedManifestRetriesWithBOnFreshSocket() async throws {
        let (fake, sockets, result) = try await pairWithoutRelease(.accept(after: .milliseconds(20)))
        let registers = await fake.requests.filter { $0["type"] == "register" }
        #expect(registers.count == 2 && sockets == 2)
        #expect(registers[0]["payload"]?["manifest"] == SSAPManifests.signedLegacy)
        #expect(registers[1]["payload"]?["manifest"] == SSAPManifests.unsigned)
        let r = try result.get()
        #expect(r.manifest == .unsigned && !r.calibrationAPIAvailable)
        await fake.stop()
    }

    @Test func fallbackNeverLoops() async throws {
        let (fake, sockets, result) = try await pairWithoutRelease(.deny(after: .milliseconds(20)))
        #expect(throws: LGError.pairingDenied) { try result.get() }
        #expect(await fake.requests.filter { $0["type"] == "register" }.count == 2 && sockets == 2)
        await fake.stop()
    }

    @Test func manifestStrategy() {
        #expect(SSAPRegistration.initialManifest(release: nil, stored: nil) == .signedLegacy)
        #expect(SSAPRegistration.initialManifest(release: WebOSRelease(major: 10, minor: 3), stored: nil) == .signedLegacy)
        #expect(SSAPRegistration.initialManifest(release: WebOSRelease(major: 11), stored: nil) == .unsigned)
        #expect(SSAPRegistration.initialManifest(release: nil, stored: TVCredentials(manifest: .unsigned)) == .unsigned)
        #expect(
            SSAPRegistration.isBlacklisted(
                LGError.server(code: 403, message: "403 Pairing rejected: blacklisted certificate detected", payload: [:])))
        #expect(!SSAPRegistration.isBlacklisted(LGError.server(code: 403, message: "403 cancelled", payload: [:])))
        #expect(SSAPManifests.signedLegacy["signatures"]?[0]?["signature"]?.stringValue?.hasSuffix("NQnAtw==") == true)
        #expect(SSAPManifests.signedLegacy["permissions"]?.arrayValue?.count == 28)
        #expect(SSAPManifests.unsigned["permissions"]?.arrayValue?.count == 37)
    }

    @Test func pinnedCertificateMismatchIsRejectedBeforeRegister() async throws {
        let store = InMemoryTVCredentialStore([
            Self.tvID: TVCredentials(clientKey: "k", certificateFingerprint: String(repeating: "a", count: 64), manifest: .signedLegacy)
        ])
        let (fake, tv) = try await makeTV(store: store)
        let e = await lgError { try await tv.connect(host: "127.0.0.1") }
        guard case .certificateChanged(let pinned, _) = e else {
            Issue.record("expected certificateChanged, got \(String(describing: e))")
            return
        }
        #expect(pinned == String(repeating: "a", count: 64))
        #expect(await fake.requests.contains { $0["type"] == "register" } == false)
        await fake.stop()
    }

    @Test func tofuRules() throws {
        try CertificatePinning.check(pinned: nil, presented: "ab")
        try CertificatePinning.check(pinned: nil, presented: nil)
        try CertificatePinning.check(pinned: "ab", presented: "ab")
        #expect(throws: LGError.certificateChanged(pinned: "ab", presented: "cd")) {
            try CertificatePinning.check(pinned: "ab", presented: "cd")
        }
        #expect(throws: LGError.self) { try CertificatePinning.check(pinned: "ab", presented: nil) }
        // Fingerprint format: lowercase hex SHA-256 of the DER bytes.
        #expect(CertificatePinning.fingerprint(der: Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

final class Counter: Sendable {
    private let n = Mutex(0)
    func increment() { n.withLock { $0 += 1 } }
    var value: Int { n.withLock { $0 } }
}
