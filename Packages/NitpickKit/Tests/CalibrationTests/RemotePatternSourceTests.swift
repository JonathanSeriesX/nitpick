import ColorScience
import Foundation
import Network
import PatternLink
import Synchronization
import Testing

@testable import Calibration

/// `RemotePatternSource` against a real `PatternLinkServer` on 127.0.0.1 (TLS-PSK with the PIN, not advertised).
@Suite(.timeLimit(.minutes(1))) struct RemotePatternSourceTests {
    /// Plays the tvOS app: acks shows (unless told not to), finishes mode switches at once, logs what it got.
    final class FakeTV: Sendable {
        let server: PatternLinkServer
        let answerShows = Mutex(true)
        let received = Mutex<[ClientMessage]>([])
        let disconnects = Mutex(0)

        init() async throws {
            let capabilities = DeviceCapabilities(
                deviceName: "Test TV", model: "AppleTV14,1", systemVersion: "18.0", frameWidth: 3840, frameHeight: 2160,
                supportsDisplayCriteria: true, displayMode: DisplayModeState(matchingEnabled: true))
            server = PatternLinkServer(deviceName: "Test TV", capabilitiesProvider: { capabilities }, pairingStore: InMemoryPairingStore())
            Task { [self, server] in
                for await event in server.events {
                    if case .clientDisconnected = event { self.disconnects.withLock { $0 += 1 } }
                    guard case .message(let id, let message) = event else { continue }
                    self.received.withLock { $0.append(message) }
                    switch message {
                    case .show(let sequence, let pattern) where self.answerShows.withLock({ $0 }):
                        let codes = pattern.content.centerColor.map { c in [c.codes(in: pattern.format)].flatMap { [$0.r, $0.g, $0.b] } }
                        await server.send(.shown(ShowAck(sequence: sequence, enqueuedAt: Date(), centerCodes: codes)), to: id)
                    case .setDisplayMode(let request):
                        await server.send(.displayMode(DisplayModeState(requested: request, matchingEnabled: true)), to: id)
                    default:
                        break
                    }
                }
            }
            try await server.start(port: .any, advertise: false)
        }

        func source(showTimeout: Duration = .seconds(5)) async throws -> RemotePatternSource {
            let deadline = ContinuousClock.now + .seconds(3)
            var port = await server.port
            while port == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
                port = await server.port
            }
            let client = PatternLinkClient(clientName: "Test Mac", clientID: UUID(), credentialStore: InMemoryCredentialStore())
            return RemotePatternSource(
                client: client, endpoint: PatternLinkBrowser.endpoint(host: "127.0.0.1", port: try #require(port)),
                serviceName: "Test TV", credential: .pin(await server.currentPIN), connectTimeout: .seconds(3),
                showTimeout: showTimeout)
        }
    }

    @Test func drivesTheAppleTVEndToEnd() async throws {
        let tv = try await FakeTV()
        defer { Task { await tv.server.stop() } }
        let source: any PatternSource = try await tv.source()

        try await source.connect()
        #expect(await source.capabilities?.deviceName == "Test TV")
        let first = try await source.show(.patch(.white, format: .sdr))
        let second = try await source.show(.patch(.gray(0.5), format: .hdr10, hdr10Metadata: .p3D65_1000))
        #expect(second.sequence == first.sequence + 1)
        #expect(first.centerCodes == [940, 940, 940])
        let state = try await source.setDisplayMode(DisplayModeRequest(dynamicRange: .hdr10))
        #expect(state.matchingEnabled && state.requested?.dynamicRange == .hdr10)
        #expect(await source.capabilities?.displayMode == state, "capabilities follow the reported mode")
        try await source.blank()

        // `blank` has no ack: wait until the TV saw it, then check the whole conversation.
        var seen: [ClientMessage] = []
        for _ in 0..<300 where !seen.contains(.blank) {
            try await Task.sleep(for: .milliseconds(10))
            seen = tv.received.withLock { $0 }
        }
        #expect(seen.count == 4)
        guard seen.count == 4, case .show(_, let pattern) = seen[1] else { return }
        #expect(pattern.hdr10Metadata == .p3D65_1000)
        #expect(seen[2] == .setDisplayMode(DisplayModeRequest(dynamicRange: .hdr10)) && seen[3] == .blank)

        await source.disconnect()
        #expect(await source.capabilities == nil)
        await #expect(throws: CalibrationError.notConnected("Pattern generator")) { _ = try await source.show(.black(format: .sdr)) }
        for _ in 0..<300 where tv.disconnects.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(tv.disconnects.withLock { $0 } == 1)
    }

    @Test func showTimeoutIsAnEngineTimeoutAndTheLinkSurvives() async throws {
        let tv = try await FakeTV()
        defer { Task { await tv.server.stop() } }
        let source = try await tv.source(showTimeout: .milliseconds(300))
        try await source.connect()
        tv.answerShows.withLock { $0 = false }
        await #expect(throws: CalibrationError.timeout("Pattern generator")) { _ = try await source.show(.black(format: .sdr)) }
        tv.answerShows.withLock { $0 = true }
        _ = try await source.show(.patch(.white, format: .sdr))
        await source.disconnect()
    }

    @Test func unreachableAppleTVIsNotConnected() async throws {
        // A port that was just free: nothing listens there, so the connection is refused.
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: .global())
        var port: UInt16?
        for _ in 0..<300 where port == nil {
            try await Task.sleep(for: .milliseconds(10))
            port = listener.port.flatMap { $0 == .any ? nil : $0.rawValue }
        }
        listener.cancel()
        try await Task.sleep(for: .milliseconds(100))
        let client = PatternLinkClient(clientName: "Test Mac", clientID: UUID(), credentialStore: InMemoryCredentialStore())
        let source = RemotePatternSource(
            client: client, endpoint: PatternLinkBrowser.endpoint(host: "127.0.0.1", port: try #require(port)), serviceName: "Test TV",
            credential: .pin("123456"), connectTimeout: .seconds(3))
        let error = await #expect(throws: CalibrationError.self) { try await source.connect() }
        guard case .notConnected? = error else {
            Issue.record("expected notConnected, got \(String(describing: error))")
            return
        }
        #expect(await source.capabilities == nil)
    }
}
