import ColorScience
import Foundation
import Network
import Testing

@testable import PatternLink

private let ackDate = Date(timeIntervalSince1970: 1_700_000_000.25)

@Suite(.timeLimit(.minutes(1))) struct FramingTests {
  @Test func framerReassemblesSplitAndCoalescedFrames() async throws {
    let listener = try NWListener(using: .tcp, on: .any)
    let (acceptedStream, accepted) = AsyncStream<NWConnection>.makeStream()
    listener.newConnectionHandler = { connection in
      connection.start(queue: .global())
      accepted.yield(connection)
    }
    listener.start(queue: .global())
    defer { listener.cancel() }
    // The port reads as .any (0) until the listener is bound.
    let port = try await eventually { listener.port.flatMap { $0 == .any ? nil : $0 } }
    let framed = NWConnection(
      host: "127.0.0.1", port: port, using: NWParameters.tcp.addingLinkFramer())
    framed.start(queue: .global())
    defer { framed.cancel() }
    var acceptedIterator = acceptedStream.makeAsyncIterator()
    let raw = try #require(await acceptedIterator.next())

    let messages: [ClientMessage] = [
      .show(sequence: 7, pattern: .patch(.white, format: .hdr10, hdr10Metadata: .p3D65_1000)),
      .ping, .blank,
    ]
    let frames = try messages.map { message in
      let body = try LinkCodec.encode(message)
      return lengthPrefix(body.count) + body
    }
    // First message in 3 chunks (one cut inside the header, one inside the body), then two messages in one write.
    let first = frames[0]
    for chunk in [first.prefix(2), first[2..<first.count / 2], first[(first.count / 2)...]] {
      try await sendRaw(raw, Data(chunk))
      try await Task.sleep(for: .milliseconds(30))
    }
    try await sendRaw(raw, frames[1] + frames[2])
    for expected in messages {
      #expect(
        try LinkCodec.decode(ClientMessage.self, from: try await receiveFrame(framed)) == expected)
    }

    // Output side: the body goes out behind its big-endian length.
    let body = try LinkCodec.encode(ServerMessage.pong)
    framed.sendFrame(body)
    #expect(try await receiveRaw(raw, count: body.count + 4) == lengthPrefix(body.count) + body)

    // A length over 4 MiB fails the connection instead of buffering.
    try await sendRaw(
      raw, lengthPrefix(LinkFramer.maxMessageSize + 1) + Data(repeating: 0, count: 16))
    await #expect(throws: (any Error).self) { _ = try await receiveFrame(framed) }
  }

  @Test func codecRoundTripsEveryMessage() throws {
    let pattern = PatternSpec.patch(
      SignalRGB(r: 0.5, g: 0.25, b: 0.75), window: .fivePercent, background: .gray(0.1),
      format: .hdr10, hdr10Metadata: .p3D65_1000)
    let request = DisplayModeRequest(dynamicRange: .hdr10, refreshRate: 59.94)
    let state = DisplayModeState(
      requested: request, switching: true, matchingEnabled: true, currentEDRHeadroom: 4,
      potentialEDRHeadroom: 8, note: "x")
    let client: [ClientMessage] = [
      .hello(Hello(clientName: "Mac", clientID: UUID())),
      .pair(PairRequest(clientName: "Mac", clientID: UUID())),
      .show(sequence: .max, pattern: pattern),
      .show(
        sequence: 1,
        pattern: PatternSpec(
          content: .ramp(steps: 11, from: .black, to: .white, horizontal: true), format: .sdr)),
      .show(
        sequence: 2,
        pattern: PatternSpec(
          content: .bars([.white, .gray(0.9)], background: .black), format: .hlg)),
      .show(sequence: 3, pattern: .black(format: .sdr)), .setDisplayMode(request), .blank,
      .queryStatus, .ping,
    ]
    let server: [ServerMessage] = [
      .welcome(testCapabilities()),
      .paired(PairResponse(token: Data(repeating: 7, count: 32), deviceID: UUID())),
      .shown(ShowAck(sequence: 3, enqueuedAt: ackDate, centerCodes: [64, 512, 940])),
      .shown(ShowAck(sequence: 4, enqueuedAt: ackDate, centerCodes: nil)),
      .displayMode(state), .error(LinkError(code: "version", message: "nope")), .pong,
    ]
    for message in client {
      #expect(try LinkCodec.decode(ClientMessage.self, from: LinkCodec.encode(message)) == message)
    }
    for message in server {
      #expect(try LinkCodec.decode(ServerMessage.self, from: LinkCodec.encode(message)) == message)
    }
    let json = String(
      decoding: try LinkCodec.encode(ShowAck(sequence: 1, enqueuedAt: ackDate, centerCodes: nil)),
      as: UTF8.self)
    #expect(json == #"{"enqueuedAt":"2023-11-14T22:13:20.250Z","sequence":1}"#)
  }

  @Test func pinKeyIsDeterministicAndSalted() {
    let key = LinkSecurity.pinKey(pin: "123456", serviceName: "Living Room").withUnsafeBytes {
      Data($0)
    }
    #expect(key.count == 32)
    #expect(
      key
        == LinkSecurity.pinKey(pin: "123456", serviceName: "Living Room").withUnsafeBytes {
          Data($0)
        })
    #expect(
      key != LinkSecurity.pinKey(pin: "123456", serviceName: "Bedroom").withUnsafeBytes { Data($0) }
    )
  }
}

@Suite(.timeLimit(.minutes(1))) struct LoopbackTests {
  @Test func pinPairThenTokenReconnectAndShow() async throws {
    let (server, app, endpoint) = try await startServer()
    defer { Task { await server.stop() } }
    let credentials = InMemoryCredentialStore()
    let client = makeClient(credentials)

    let pin = await server.currentPIN
    let capabilities = try await client.connect(
      to: endpoint, serviceName: "Test TV", credential: .pin(pin), timeout: .seconds(3))
    #expect(capabilities == testCapabilities())
    #expect(await client.connectionState == .connected(testCapabilities()))
    #expect(await client.diagnostics.cipherSuite == 0xCCAC)  // ECDHE-PSK negotiated

    let response = try await client.pair()
    #expect(response.deviceID == server.deviceID)
    #expect(credentials.token(for: server.deviceID) == response.token)
    #expect(response.token.count == 32)
    #expect(await app.pairedClients() == [client.clientID])
    #expect(await server.currentPIN != pin)

    await client.disconnect()
    #expect(await client.connectionState == .idle)

    _ = try await client.connect(
      to: endpoint, serviceName: "Test TV", credential: .token(response.token), timeout: .seconds(3)
    )
    #expect(await client.diagnostics.identity == LinkSecurity.tokenIdentity(client.clientID))
    #expect(
      await app.identities() == [
        LinkSecurity.pinIdentity(client.clientID), LinkSecurity.tokenIdentity(client.clientID),
      ])

    let first = try await client.show(.patch(.white, format: .sdr), timeout: .seconds(2))
    let second = try await client.show(.black(format: .sdr), timeout: .seconds(2))
    #expect(second.sequence == first.sequence + 1)
    #expect(await client.diagnostics.acksReceived == 2)
    #expect(try await client.ping() < .seconds(1))

    // A token session may not mint tokens.
    let refusal = await #expect(throws: PatternLinkError.self) { _ = try await client.pair() }
    guard case .remote(let error)? = refusal else {
      Issue.record("expected remote error, got \(String(describing: refusal))")
      return
    }
    #expect(error.code == "pairing")
    await client.disconnect()

    // The listener was rebuilt with the new PIN after pairing; the old PIN no longer works.
    await #expect(throws: PatternLinkError.authenticationFailed) {
      _ = try await makeClient().connect(
        to: endpoint, serviceName: "Test TV", credential: .pin(pin), timeout: .seconds(3))
    }
  }

  @Test func wrongPINFailsAuthentication() async throws {
    let (server, _, endpoint) = try await startServer()
    defer { Task { await server.stop() } }
    let wrong = await server.currentPIN == "000000" ? "111111" : "000000"
    let client = makeClient()
    let start = ContinuousClock.now
    await #expect(throws: PatternLinkError.authenticationFailed) {
      _ = try await client.connect(
        to: endpoint, serviceName: "Test TV", credential: .pin(wrong), timeout: .seconds(3))
    }
    #expect(ContinuousClock.now - start < .seconds(2))
    guard case .failed = await client.connectionState else {
      Issue.record("expected failed state")
      return
    }

    // Brute-force throttle: right after a failed handshake the server resets new connections for about a second.
    let pin = await server.currentPIN
    let refused = await #expect(throws: PatternLinkError.self) {
      _ = try await client.connect(
        to: endpoint, serviceName: "Test TV", credential: .pin(pin), timeout: .seconds(3))
    }
    guard case .connectionFailed? = refused else {
      Issue.record("expected a refused connection, got \(String(describing: refused))")
      return
    }
    try await Task.sleep(for: .milliseconds(1100))
    _ = try await client.connect(
      to: endpoint, serviceName: "Test TV", credential: .pin(pin), timeout: .seconds(3))
    await client.disconnect()
  }

  @Test func showTimesOutWithoutAnAck() async throws {
    let (server, app, endpoint) = try await startServer()
    defer { Task { await server.stop() } }
    await app.configure(answerShows: false)
    let client = makeClient()
    _ = try await client.connect(
      to: endpoint, serviceName: "Test TV", credential: .pin(await server.currentPIN),
      timeout: .seconds(3))
    await #expect(throws: PatternLinkError.timeout) {
      _ = try await client.show(.black(format: .sdr), timeout: .milliseconds(300))
    }
    // The connection is still usable after a timeout.
    _ = try await client.ping()
    await client.disconnect()
  }

  @Test func setDisplayModeWaitsUntilSwitchingEnds() async throws {
    let (server, app, endpoint) = try await startServer()
    defer { Task { await server.stop() } }
    let client = makeClient()
    _ = try await client.connect(
      to: endpoint, serviceName: "Test TV", credential: .pin(await server.currentPIN),
      timeout: .seconds(3))

    let request = DisplayModeRequest(dynamicRange: .hdr10, refreshRate: 60)
    let start = ContinuousClock.now
    let done = try await client.setDisplayMode(request, timeout: .seconds(3))
    #expect(done.switching == false)
    #expect(done.requested == request)
    #expect(ContinuousClock.now - start >= .milliseconds(150))

    // Never finishes: the timeout returns the latest (still switching) state.
    await app.configure(switchDuration: nil)
    let latest = try await client.setDisplayMode(request, timeout: .milliseconds(300))
    #expect(latest.switching)
    await client.disconnect()
  }

  @Test func cancellationReturnsPromptly() async throws {
    let (server, app, endpoint) = try await startServer()
    defer { Task { await server.stop() } }
    await app.configure(answerShows: false)
    let client = makeClient()
    _ = try await client.connect(
      to: endpoint, serviceName: "Test TV", credential: .pin(await server.currentPIN),
      timeout: .seconds(3))

    let task = Task { try await client.show(.black(format: .sdr), timeout: .seconds(30)) }
    try await Task.sleep(for: .milliseconds(100))
    let start = ContinuousClock.now
    task.cancel()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(ContinuousClock.now - start < .milliseconds(500))
    await client.disconnect()

    // A TCP peer that never answers the TLS handshake: connect times out, and cancelling it returns at once.
    let blackHole = try NWListener(using: .tcp, on: .any)
    blackHole.newConnectionHandler = { $0.start(queue: .global()) }
    blackHole.start(queue: .global())
    defer { blackHole.cancel() }
    let silentPort = try await eventually {
      blackHole.port.flatMap { $0 == .any ? nil : $0.rawValue }
    }
    let silent = PatternLinkBrowser.endpoint(host: "127.0.0.1", port: silentPort)
    await #expect(throws: PatternLinkError.timeout) {
      _ = try await makeClient().connect(
        to: silent, serviceName: "x", credential: .pin("1"), timeout: .milliseconds(200))
    }
    let stuck = Task {
      try await makeClient().connect(
        to: silent, serviceName: "x", credential: .pin("1"), timeout: .seconds(30))
    }
    try await Task.sleep(for: .milliseconds(100))
    let cancelled = ContinuousClock.now
    stuck.cancel()
    await #expect(throws: CancellationError.self) { _ = try await stuck.value }
    #expect(ContinuousClock.now - cancelled < .milliseconds(500))
  }

  @Test func reconnectsAfterServerRestartOnSamePort() async throws {
    let (server, _, endpoint) = try await startServer()
    defer { Task { await server.stop() } }
    let client = makeClient()
    _ = try await client.connect(
      to: endpoint, serviceName: "Test TV", credential: .pin(await server.currentPIN),
      timeout: .seconds(3))
    let response = try await client.pair()
    await client.disconnect()
    _ = try await client.connect(
      to: endpoint, serviceName: "Test TV", credential: .token(response.token), timeout: .seconds(3)
    )
    let states = Task {
      var seen: [PatternLinkClient.ConnectionState] = []
      for await state in client.state {
        seen.append(state)
        if case .connected = state, seen.contains(.reconnecting(attempt: 1)) { break }
      }
      return seen
    }
    let port = try #require(await server.port)

    await server.stop()
    _ = try await eventually {
      await client.connectionState == .reconnecting(attempt: 1) ? true : nil
    }
    await #expect(throws: PatternLinkError.notConnected) { _ = try await client.ping() }
    try await server.start(port: NWEndpoint.Port(rawValue: port)!, advertise: false)

    _ = try await eventually(timeout: .seconds(5)) {
      if case .connected = await client.connectionState { true } else { nil }
    }
    _ = try await client.ping()
    #expect(await server.port == port)
    #expect(await client.diagnostics.identity == LinkSecurity.tokenIdentity(client.clientID))
    let seen = await states.value
    #expect(seen.suffix(2) == [.reconnecting(attempt: 1), .connected(testCapabilities())])
    await client.disconnect()
  }

  @Test func idleHandshakesAreCappedAndTimedOut() async throws {
    let (server, _, endpoint) = try await startServer()
    defer { Task { await server.stop() } }
    // Four TCP connections that never start TLS take every handshake slot.
    let idle = (0..<4).map { _ in NWConnection(to: endpoint, using: .tcp) }
    defer { for connection in idle { connection.cancel() } }
    for connection in idle { connection.start(queue: .global()) }
    try await Task.sleep(for: .milliseconds(200))
    let client = makeClient()
    let pin = await server.currentPIN
    await #expect(throws: PatternLinkError.self) {
      _ = try await client.connect(
        to: endpoint, serviceName: "Test TV", credential: .pin(pin), timeout: .seconds(2))
    }
    // The server drops them after its 5 s handshake timeout (then a 1 s lockout), and serves clients again.
    let start = ContinuousClock.now
    _ = try await eventually(timeout: .seconds(8)) {
      try? await client.connect(
        to: endpoint, serviceName: "Test TV", credential: .pin(pin), timeout: .seconds(2))
    }
    #expect(ContinuousClock.now - start > .seconds(4))
    await client.disconnect()
  }

  @Test func serverRejectsProtocolMismatch() async throws {
    let (server, _, endpoint) = try await startServer()
    defer { Task { await server.stop() } }
    let clientID = UUID()
    let psk = LinkSecurity.pinKey(pin: await server.currentPIN, serviceName: "Test TV")
      .withUnsafeBytes { Data($0) }
    let connection = NWConnection(
      to: endpoint,
      using: LinkSecurity.parameters(psk: psk, identity: LinkSecurity.pinIdentity(clientID)))
    connection.start(queue: .global())
    defer { connection.cancel() }
    connection.sendFrame(
      try LinkCodec.encode(
        ClientMessage.hello(Hello(clientName: "Old Mac", clientID: clientID, protocolVersion: 99))))
    let reply = try LinkCodec.decode(ServerMessage.self, from: try await receiveFrame(connection))
    guard case .error(let error) = reply else {
      Issue.record("expected error, got \(reply)")
      return
    }
    #expect(error.code == "version")
    // The server closes the session after the error.
    await #expect(throws: (any Error).self) { _ = try await receiveFrame(connection) }
  }
}

/// Real Bonjour advertise + browse. Opt-in (touches the machine's mDNS): `PATTERNLINK_BONJOUR=1 swift test ...`.
@Suite(
  .timeLimit(.minutes(1)),
  .enabled(if: ProcessInfo.processInfo.environment["PATTERNLINK_BONJOUR"] != nil))
struct BonjourTests {
  @Test func browserFindsAdvertisedServer() async throws {
    let name = "Nitpick Test \(UUID().uuidString.prefix(6))"
    let store = InMemoryPairingStore()
    let server = PatternLinkServer(
      deviceName: name, capabilitiesProvider: { testCapabilities() }, pairingStore: store)
    let app = FakeTVApp(server: server)
    await app.run()
    try await server.start(advertise: true)
    defer { Task { await server.stop() } }
    let browser = PatternLinkBrowser()
    await browser.start()
    defer { Task { await browser.stop() } }
    var found: PatternLinkBrowser.DiscoveredDevice?
    for await devices in browser.devices {
      if let device = devices.first(where: { $0.name == name }) {
        found = device
        break
      }
    }
    let device = try #require(found)
    #expect(device.deviceID == store.deviceID())
    let client = makeClient()
    _ = try await client.connect(
      to: device.endpoint, serviceName: device.id, credential: .pin(await server.currentPIN),
      timeout: .seconds(5))
    await client.disconnect()
  }
}
