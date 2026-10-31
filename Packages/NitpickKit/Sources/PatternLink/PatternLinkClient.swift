import Foundation
import Network
import Security

/// What the Mac UI shows about the link.
public struct LinkDiagnostics: Hashable, Sendable {
    public var endpoint: String?
    public var connectedSince: Date?
    public var lastRoundTrip: Duration?
    public var lastError: String?
    /// Framed bytes (body + 4-byte header), excluding TLS overhead.
    public var bytesIn = 0
    public var bytesOut = 0
    public var acksReceived = 0
    /// PSK identity of the current session (`pin:<uuid>` or `tok:<uuid>`).
    public var identity: String?
    /// Negotiated TLS ciphersuite (IANA value); 0xCCAC = TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256.
    public var cipherSuite: UInt16?
    public init() {}
}

/// The Mac end of the link. Connects with a PIN or pairing token, pairs, drives patterns, and reconnects with
/// exponential backoff (1, 2, 4 … 30 s) when an established session drops before `disconnect()`.
///
/// Every wait honours task cancellation (throws `CancellationError`) and its timeout.
public actor PatternLinkClient {
    public enum Credential: Hashable, Sendable {
        /// The 6-digit PIN shown on the TV (first contact).
        case pin(String)
        /// The token from `pair()` (reconnects).
        case token(Data)
    }

    public enum ConnectionState: Sendable, Equatable {
        case idle
        /// Opening the TLS-PSK connection.
        case connecting
        /// The secure channel is up; exchanging `hello`.
        case authenticating
        case connected(DeviceCapabilities)
        case reconnecting(attempt: Int)
        case failed(String)
    }

    public nonisolated let clientName: String
    public nonisolated let clientID: UUID
    /// State changes. Single consumer; keeps the newest 16.
    public nonisolated let state: AsyncStream<ConnectionState>
    public private(set) var connectionState: ConnectionState = .idle
    public private(set) var diagnostics = LinkDiagnostics()

    private let credentialStore: ClientCredentialStore
    private let stateSink: AsyncStream<ConnectionState>.Continuation
    private let queue = DispatchSerialQueue(label: "PatternLinkClient")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private struct Target {
        var endpoint: NWEndpoint
        var serviceName: String
        var credential: Credential
    }

    private enum Verdict { case ignore, progress, done }

    private struct Waiter {
        let match: (ServerMessage) -> Verdict
        let continuation: CheckedContinuation<ServerMessage, Error>
        let timer: Task<Void, Never>
        /// Last `.progress` message; returned instead of `.timeout` when the wait expires.
        var latest: ServerMessage?
    }

    /// Where to (re)connect; nil once the caller disconnects.
    private var target: Target?
    /// Bumped by `connect`/`disconnect` so stale reconnect loops and handshakes stand down.
    private var session = 0
    private var connection: NWConnection?
    private var established = false
    /// Whether the last connection failure was ECONNREFUSED (see `connect`).
    private var lastRefused = false
    private var waiters: [Int: Waiter] = [:]
    private var nextWaiter = 0
    private var sequence: UInt32 = 0
    private var reconnectTask: Task<Void, Never>?

    public init(clientName: String, clientID: UUID, credentialStore: ClientCredentialStore) {
        self.clientName = clientName
        self.clientID = clientID
        self.credentialStore = credentialStore
        (state, stateSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
    }

    deinit {
        reconnectTask?.cancel()
        connection?.cancel()
        stateSink.finish()
    }

    // MARK: - Public API

    /// Connects (dropping any current session), authenticates with `credential` and exchanges `hello`.
    /// - Parameter serviceName: the TV's Bonjour service name (`DiscoveredDevice.id`); salts the PIN key.
    /// - Throws: `PatternLinkError.timeout`, `.authenticationFailed`, `.versionMismatch`, `.connectionFailed`,
    ///   `.disconnected`, or `CancellationError`.
    public func connect(
        to endpoint: NWEndpoint, serviceName: String, credential: Credential,
        timeout: Duration = .seconds(10)
    ) async throws -> DeviceCapabilities {
        tearDown()
        session += 1
        let session = session
        let target = Target(endpoint: endpoint, serviceName: serviceName, credential: credential)
        self.target = target
        diagnostics = LinkDiagnostics()
        setState(.connecting)
        let deadline = ContinuousClock.now + timeout
        do {
            // "Connection refused" is retried briefly: the TV rebuilds its listener after each pairing (a few ms
            // with nothing listening), and an app that is just starting refuses for a moment too.
            var attempt = 0
            while true {
                attempt += 1
                do {
                    return try await establish(target, timeout: deadline - .now)
                } catch PatternLinkError.connectionFailed
                    where lastRefused && attempt < 5 && self.session == session
                {
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
        } catch {
            if self.session == session {
                self.target = nil
                setState(error is CancellationError ? .idle : .failed("\(error)"))
            }
            throw error
        }
    }

    /// Pairs over a PIN session. Stores the token under the TV's device id and uses it for automatic reconnects.
    public func pair() async throws -> PairResponse {
        try requireConnected()
        let reply = try await request(
            .pair(PairRequest(clientName: clientName, clientID: clientID)), timeout: .seconds(10)
        ) {
            if case .paired = $0 { .done } else { .ignore }
        }
        guard case .paired(let response) = reply else { throw PatternLinkError.disconnected }
        try credentialStore.setToken(response.token, for: response.deviceID)
        target?.credential = .token(response.token)
        return response
    }

    /// Shows a pattern and waits for the TV's acknowledgement of this call's sequence number.
    /// Acks for earlier sequences (for example after their call timed out) are ignored.
    public func show(_ pattern: PatternSpec, timeout: Duration = .seconds(5)) async throws -> ShowAck {
        try requireConnected()
        sequence &+= 1
        let sequence = sequence
        let reply = try await request(.show(sequence: sequence, pattern: pattern), timeout: timeout) {
            if case .shown(let ack) = $0, ack.sequence == sequence { .done } else { .ignore }
        }
        guard case .shown(let ack) = reply else { throw PatternLinkError.disconnected }
        return ack
    }

    /// Requests an output mode and waits until the TV reports `switching == false`. On timeout it returns the latest
    /// state it received, and throws `.timeout` only if none arrived.
    public func setDisplayMode(_ request: DisplayModeRequest, timeout: Duration = .seconds(25))
        async throws -> DisplayModeState
    {
        try requireConnected()
        let reply = try await self.request(.setDisplayMode(request), timeout: timeout) {
            if case .displayMode(let state) = $0 { state.switching ? .progress : .done } else { .ignore }
        }
        guard case .displayMode(let state) = reply else { throw PatternLinkError.disconnected }
        return state
    }

    /// Asks for the TV's current output state.
    public func queryStatus(timeout: Duration = .seconds(5)) async throws -> DisplayModeState {
        try requireConnected()
        let reply = try await request(.queryStatus, timeout: timeout) {
            if case .displayMode = $0 { .done } else { .ignore }
        }
        guard case .displayMode(let state) = reply else { throw PatternLinkError.disconnected }
        return state
    }

    /// Blanks the screen. The protocol has no ack for this; returns once the message is sent.
    public func blank() async throws {
        try requireConnected()
        guard let connection else { throw PatternLinkError.notConnected }
        let body = try LinkCodec.encode(ClientMessage.blank)
        diagnostics.bytesOut += body.count + 4
        let error: NWError? = await withCheckedContinuation { continuation in
            connection.sendFrame(body) { continuation.resume(returning: $0) }
        }
        if error != nil { throw PatternLinkError.disconnected }
    }

    /// Measures one ping/pong round trip.
    public func ping() async throws -> Duration {
        try requireConnected()
        let start = ContinuousClock.now
        _ = try await request(.ping, timeout: .seconds(5)) { $0 == .pong ? .done : .ignore }
        let roundTrip = ContinuousClock.now - start
        diagnostics.lastRoundTrip = roundTrip
        return roundTrip
    }

    /// Closes the session and stops reconnecting. Pending calls throw `.disconnected`.
    public func disconnect() {
        session += 1
        target = nil
        tearDown()
        setState(.idle)
    }

    // MARK: - Connection

    private func establish(_ target: Target, timeout: Duration) async throws -> DeviceCapabilities {
        let psk: Data
        let identity: String
        switch target.credential {
        case .pin(let pin):
            psk = LinkSecurity.pinKey(pin: pin, serviceName: target.serviceName).withUnsafeBytes {
                Data($0)
            }
            identity = LinkSecurity.pinIdentity(clientID)
        case .token(let token):
            psk = token
            identity = LinkSecurity.tokenIdentity(clientID)
        }
        let connection = NWConnection(
            to: target.endpoint, using: LinkSecurity.parameters(psk: psk, identity: identity))
        self.connection = connection
        established = false
        diagnostics.endpoint = "\(target.endpoint)"
        diagnostics.identity = identity
        connection.stateUpdateHandler = { [weak self] state in
            self?.assumeIsolated { $0.connectionChanged(connection, state) }
        }
        connection.start(queue: queue)
        receive(on: connection)
        do {
            // Sent now, delivered after the handshake; a TLS failure fails this wait with `.authenticationFailed`.
            let reply = try await request(
                .hello(Hello(clientName: clientName, clientID: clientID)), timeout: timeout
            ) {
                if case .welcome = $0 { .done } else { .ignore }
            }
            guard case .welcome(let capabilities) = reply, connection === self.connection else {
                throw PatternLinkError.disconnected
            }
            guard capabilities.protocolVersion == patternLinkProtocolVersion else {
                throw PatternLinkError.versionMismatch
            }
            established = true
            diagnostics.connectedSince = Date()
            setState(.connected(capabilities))
            return capabilities
        } catch {
            if connection === self.connection { self.connection = nil }
            connection.cancel()
            diagnostics.lastError = "\(error)"
            throw error
        }
    }

    private func connectionChanged(_ connection: NWConnection, _ state: NWConnection.State) {
        guard connection === self.connection else { return }
        switch state {
        case .ready:
            if let tls = connection.metadata(definition: NWProtocolTLS.definition)
                as? NWProtocolTLS.Metadata
            {
                diagnostics.cipherSuite =
                    sec_protocol_metadata_get_negotiated_tls_ciphersuite(tls.securityProtocolMetadata)
                    .rawValue
            }
            if connectionState == .connecting { setState(.authenticating) }
        case .waiting(let error), .failed(let error):
            lost(error)
        default:
            break
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, _, _, error in
            self?.assumeIsolated { client in
                guard connection === client.connection else { return }
                guard let content, error == nil else { return client.lost(error) }
                client.diagnostics.bytesIn += content.count + 4
                if let message = try? LinkCodec.decode(ServerMessage.self, from: content) {
                    client.dispatch(message)
                } else {
                    client.diagnostics.lastError = "Unreadable message from the Apple TV"
                }
                client.receive(on: connection)
            }
        }
    }

    /// The current connection failed or closed. Fails pending calls and, after an established session, reconnects.
    private func lost(_ error: NWError?) {
        guard let connection else { return }
        connection.cancel()
        self.connection = nil
        let wasEstablished = established
        established = false
        lastRefused = error == .posix(.ECONNREFUSED)
        let reason: PatternLinkError =
            switch error {
            case .tls?: .authenticationFailed
            case let error?: wasEstablished ? .disconnected : .connectionFailed("\(error)")
            case nil: .disconnected
            }
        diagnostics.lastError = "\(reason)"
        diagnostics.connectedSince = nil
        failAll(wasEstablished ? PatternLinkError.disconnected : reason)
        if wasEstablished, target != nil { startReconnecting() }
    }

    private func startReconnecting() {
        guard reconnectTask == nil else { return }
        let session = session
        reconnectTask = Task { [weak self] in await self?.reconnect(session) }
    }

    private func reconnect(_ session: Int) async {
        var attempt = 0
        while session == self.session, let target, !Task.isCancelled {
            attempt += 1
            setState(.reconnecting(attempt: attempt))
            try? await Task.sleep(for: .seconds(min(30, 1 << min(attempt - 1, 5))))
            guard session == self.session, !Task.isCancelled else { return }
            do {
                _ = try await establish(target, timeout: .seconds(10))
                reconnectTask = nil
                return
            } catch PatternLinkError.authenticationFailed, PatternLinkError.versionMismatch {
                // Retrying cannot fix a rejected credential or protocol; the caller must act.
                guard session == self.session else { return }
                self.target = nil
                reconnectTask = nil
                setState(.failed(diagnostics.lastError ?? "Authentication failed"))
                return
            } catch {
                continue
            }
        }
    }

    /// Drops the connection and any reconnect loop; pending calls throw `.disconnected`.
    private func tearDown() {
        reconnectTask?.cancel()
        reconnectTask = nil
        connection?.cancel()
        connection = nil
        established = false
        diagnostics.connectedSince = nil
        failAll(PatternLinkError.disconnected)
    }

    private func setState(_ new: ConnectionState) {
        guard new != connectionState else { return }
        connectionState = new
        stateSink.yield(new)
    }

    private func requireConnected() throws {
        guard established, connection != nil else { throw PatternLinkError.notConnected }
    }

    // MARK: - Requests

    /// Sends `message` and waits for the first reply `match` accepts (`.done`), the timeout, or cancellation.
    private func request(
        _ message: ClientMessage, timeout: Duration,
        match: @escaping (ServerMessage) -> Verdict
    ) async throws -> ServerMessage {
        guard let connection else { throw PatternLinkError.notConnected }
        let body = try LinkCodec.encode(message)
        nextWaiter += 1
        let id = nextWaiter
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { return continuation.resume(throwing: CancellationError()) }
                let timer = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    if !Task.isCancelled { await self?.expire(id) }
                }
                waiters[id] = Waiter(match: match, continuation: continuation, timer: timer)
                diagnostics.bytesOut += body.count + 4
                connection.sendFrame(body)
            }
        } onCancel: {
            Task { [weak self] in await self?.finish(id, .failure(CancellationError())) }
        }
    }

    private func dispatch(_ message: ServerMessage) {
        switch message {
        case .error(let error):
            // The protocol has no request ids, so a remote error fails every pending call.
            return failAll(
                error.code == "version" ? PatternLinkError.versionMismatch : PatternLinkError.remote(error))
        case .shown:
            diagnostics.acksReceived += 1
        default:
            break
        }
        for id in waiters.keys.sorted() {
            guard let waiter = waiters[id] else { continue }
            switch waiter.match(message) {
            case .ignore: continue
            case .progress: waiters[id]?.latest = message
            case .done: return finish(id, .success(message))
            }
        }
    }

    private func expire(_ id: Int) {
        guard let waiter = waiters[id] else { return }
        finish(id, waiter.latest.map { .success($0) } ?? .failure(PatternLinkError.timeout))
    }

    private func finish(_ id: Int, _ result: Result<ServerMessage, Error>) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.timer.cancel()
        waiter.continuation.resume(with: result)
    }

    private func failAll(_ error: Error) {
        for id in waiters.keys { finish(id, .failure(error)) }
    }
}
