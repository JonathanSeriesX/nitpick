import Foundation
import Network
import Security

/// One SSAP WebSocket to a TV: framing `{id, type, uri, payload}`, request/response matching by id, subscriptions,
/// hello, registration frames, per-request timeouts, WebSocket ping keepalive and TLS trust-on-first-use.
///
/// Transport: `wss://host:3001` with LG's static self-signed certificate (hostname and chain are not checkable, so the
/// leaf is pinned by SHA-256 instead). Plain `ws://host:3000` is tried only when 3001 refuses the TCP connection and no
/// certificate is pinned yet (pre-2018 TVs; SPEC §3.1). `allowInsecure` forces plain `ws://` on `port` (tests, fake TV).
/// Callbacks run on the actor's own serial queue.
public actor SSAPConnection {
    public struct Options: Sendable {
        public var port: UInt16
        public var allowInsecure: Bool
        /// SHA-256 (lowercase hex) of the TV's TLS leaf certificate. A different certificate fails the handshake.
        public var pinnedFingerprint: String?
        public var connectTimeout: Duration
        public var requestTimeout: Duration
        /// WebSocket ping period; the connection fails when no pong arrived for two periods plus 5 s.
        public var pingInterval: Duration

        public init(
            port: UInt16 = 3001, allowInsecure: Bool = false, pinnedFingerprint: String? = nil,
            connectTimeout: Duration = .seconds(5), requestTimeout: Duration = .seconds(10),
            pingInterval: Duration = .seconds(10)
        ) {
            self.port = port
            self.allowInsecure = allowInsecure
            self.pinnedFingerprint = pinnedFingerprint
            self.connectTimeout = connectTimeout
            self.requestTimeout = requestTimeout
            self.pingInterval = pingInterval
        }
    }

    private struct Pending {
        var continuation: CheckedContinuation<JSON, any Error>?
        var stream: AsyncStream<JSON>.Continuation?
        var isRegister = false
        var timeout: Task<Void, Never>?
    }

    public nonisolated let host: String
    /// Connection state. Single consumer; finishes after `close()` or a failure.
    public nonisolated let state: AsyncStream<SSAPState>
    public private(set) var hello: SSAPHello?
    /// SHA-256 of the presented TLS leaf certificate; nil on plain `ws://`.
    public private(set) var certificateFingerprint: String?
    /// True when the connection fell back to plain `ws://:3000`.
    public private(set) var isInsecure = false

    public let options: Options
    private let stateSink: AsyncStream<SSAPState>.Continuation
    private let queue = DispatchSerialQueue(label: "SSAPConnection")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private var connection: NWConnection?
    private var connectWaiter: CheckedContinuation<Void, any Error>?
    private var rejectedFingerprint: String?
    private var pending: [String: Pending] = [:]
    private var lastID = 0
    private var registerCount = 0
    private var closed = false
    private var keepalive: Task<Void, Never>?
    private var lastPong = ContinuousClock.now

    public init(host: String, options: Options = .init()) {
        self.host = host
        self.options = options
        (state, stateSink) = AsyncStream.makeStream()
    }

    deinit {
        connection?.cancel()
        keepalive?.cancel()
        stateSink.finish()
    }

    // MARK: - Public API

    /// Opens the socket and sends `hello`. A TV that does not answer `hello` leaves `hello` nil.
    /// One-shot: after `close()` or a failure, make a new `SSAPConnection`.
    @discardableResult
    public func open() async throws -> SSAPHello? {
        guard connection == nil, !closed else { throw LGError.connectionFailed("open() on a used connection") }
        stateSink.yield(.connecting)
        do {
            do {
                try await connect(secure: !options.allowInsecure, port: options.port)
            } catch NWError.posix(.ECONNREFUSED) where !options.allowInsecure && options.port == 3001 && options.pinnedFingerprint == nil {
                try await connect(secure: false, port: 3000)
                isInsecure = true
            }
        } catch {
            let mapped = map(error)
            teardown(mapped)
            throw mapped
        }
        lastPong = .now
        startKeepalive()
        if let reply = try? await exchange(
            id: "hello", frame: ["id": "hello", "type": "hello", "payload": [:]],
            timeout: options.connectTimeout, what: "hello")
        {
            hello = SSAPHello(payload: reply["payload"] ?? [:])
        }
        return hello
    }

    /// Sends `ssap://<uri>` (pass it with or without the `ssap://` prefix) and returns the reply payload.
    /// Throws `LGError.server` for `type:"error"` or `returnValue:false`, `LGError.timeout` after `timeout`.
    @discardableResult
    public func request(_ uri: String, payload: JSON = [:], timeout: Duration? = nil) async throws -> JSON {
        let full = uri.hasPrefix("ssap://") ? uri : "ssap://" + uri
        let id = nextID()
        let reply = try await exchange(
            id: String(id), frame: ["id": .number(Double(id)), "type": "request", "uri": .string(full), "payload": payload],
            timeout: timeout ?? options.requestTimeout, what: full)
        return try Self.successPayload(reply)
    }

    /// Fire-and-forget request (for `system/turnOff`, whose reply is often lost while the TV shuts down).
    public func send(_ uri: String, payload: JSON = [:]) async throws {
        let full = uri.hasPrefix("ssap://") ? uri : "ssap://" + uri
        try await write(["id": .number(Double(nextID())), "type": "request", "uri": .string(full), "payload": payload])
    }

    /// Subscribes; the stream yields the first reply payload and every later push. Ending iteration unsubscribes.
    public func subscribe(_ uri: String, payload: JSON = [:]) async throws -> AsyncStream<JSON> {
        let full = uri.hasPrefix("ssap://") ? uri : "ssap://" + uri
        let id = nextID()
        let key = String(id)
        let (stream, sink) = AsyncStream<JSON>.makeStream()
        sink.onTermination = { [weak self] _ in Task { await self?.unsubscribe(key) } }
        let first = try await exchange(
            id: key, frame: ["id": .number(Double(id)), "type": "subscribe", "uri": .string(full), "payload": payload],
            timeout: options.requestTimeout, what: full, stream: sink)
        _ = try Self.successPayload(first)
        return stream
    }

    /// Sends a `register` frame and waits for `registered`. A `PROMPT` notice yields `.pairing` and keeps waiting.
    /// Returns the `registered` payload (holds `client-key`).
    public func register(_ payload: JSON, timeout: Duration = .seconds(60)) async throws -> JSON {
        let id = "register_\(registerCount)"
        registerCount += 1
        let reply = try await exchange(
            id: id, frame: ["type": "register", "id": .string(id), "payload": payload],
            timeout: timeout, what: "pairing prompt", isRegister: true)
        stateSink.yield(.registered)
        return reply["payload"] ?? [:]
    }

    /// Closes the socket; pending requests fail with `LGError.notConnected`.
    public func close() { teardown(nil) }

    public var isOpen: Bool { connection != nil && !closed }

    // MARK: - Frames

    private func nextID() -> Int {
        lastID += 1
        return lastID
    }

    /// bscpylgtv's success rule: `type:"error"` fails; otherwise `payload.returnValue ?? payload.subscribed` must be true.
    static func successPayload(_ frame: JSON) throws -> JSON {
        if frame["type"]?.stringValue == "error" { throw LGError.fromErrorFrame(frame) }
        let payload = frame["payload"] ?? [:]
        guard (payload["returnValue"] ?? payload["subscribed"])?.boolValue == true else {
            let message = payload["errorText"]?.stringValue ?? payload["errorMessage"]?.stringValue ?? "returnValue false"
            throw LGError.server(code: payload["errorCode"]?.intValue, message: message, payload: payload)
        }
        return payload
    }

    private func exchange(
        id: String, frame: JSON, timeout: Duration, what: String,
        isRegister: Bool = false, stream: AsyncStream<JSON>.Continuation? = nil
    ) async throws -> JSON {
        guard isOpen else { throw LGError.notConnected }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    if !Task.isCancelled { await self?.finish(id, .failure(LGError.timeout(what))) }
                }
                pending[id] = Pending(continuation: continuation, stream: stream, isRegister: isRegister, timeout: timer)
                if Task.isCancelled {
                    finish(id, .failure(CancellationError()))
                    return
                }
                Task { [weak self] in
                    do { try await self?.write(frame) } catch { await self?.finish(id, .failure(error)) }
                }
            }
        } onCancel: {
            Task { [weak self] in await self?.finish(id, .failure(CancellationError())) }
        }
    }

    /// Resolves the waiting call for `id`. Subscriptions stay registered after a successful first reply.
    private func finish(_ id: String, _ result: Result<JSON, any Error>) {
        guard var entry = pending[id] else { return }
        entry.timeout?.cancel()
        entry.timeout = nil
        entry.continuation?.resume(with: result)
        entry.continuation = nil
        if case .success = result, entry.stream != nil {
            pending[id] = entry  // subscriptions stay registered for pushes
        } else {
            entry.stream?.finish()
            pending[id] = nil
        }
    }

    private func unsubscribe(_ key: String) async {
        guard pending.removeValue(forKey: key) != nil, isOpen else { return }
        try? await write(["id": Double(key).map(JSON.number) ?? .string(key), "type": "unsubscribe"])
    }

    /// The pending-request key of a frame `id`; nil for ids no request uses (a non-integral or huge number would
    /// otherwise trap in `Int(_:)`).
    static func key(_ id: JSON?) -> String? {
        switch id {
        case .number(let n)?: Int(exactly: n).map(String.init)
        case .string(let s)?: s
        default: nil
        }
    }

    private func handle(_ data: Data) {
        guard let frame = try? JSON.decode(data), let id = Self.key(frame["id"]), let entry = pending[id] else { return }
        let type = frame["type"]?.stringValue
        if entry.isRegister {
            if type == "registered" { return finish(id, .success(frame)) }
            if type == "error" { return finish(id, .failure(LGError.fromErrorFrame(frame))) }
            if frame["payload"]?["pairingType"] != nil { stateSink.yield(.pairing) }
            return
        }
        if type == "error" { return finish(id, .failure(LGError.fromErrorFrame(frame))) }
        entry.stream?.yield(frame["payload"] ?? [:])
        if entry.continuation != nil { finish(id, .success(frame)) }
    }

    private func write(_ frame: JSON) async throws {
        guard let connection, !closed else { throw LGError.notConnected }
        let data = try frame.encoded()
        let context = NWConnection.ContentContext(identifier: "ssap", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(
                content: data, contentContext: context, isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: LGError.connectionFailed("send: \(error)"))
                    } else {
                        continuation.resume()
                    }
                })
        }
    }

    // MARK: - Socket

    private func connect(secure: Bool, port: UInt16) async throws {
        let parameters: NWParameters
        if secure {
            let tls = NWProtocolTLS.Options()
            let pinned = options.pinnedFingerprint
            sec_protocol_options_set_verify_block(
                tls.securityProtocolOptions,
                { [weak self] _, trust, complete in
                    let presented = Self.leafFingerprint(trust)
                    complete(self?.assumeIsolated { $0.verify(presented, pinned: pinned) } ?? false)
                }, queue)
            parameters = NWParameters(tls: tls)
        } else {
            parameters = .tcp
        }
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 16 << 20  // a 33³ LUT request is ~288 KB of base64
        parameters.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        let hostPart = host.contains(":") ? "[\(host)]" : host
        guard let url = URL(string: "\(secure ? "wss" : "ws")://\(hostPart):\(port)") else {
            throw LGError.connectionFailed("bad host \(host)")
        }
        let connection = NWConnection(to: .url(url), using: parameters)
        self.connection = connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connectWaiter = continuation
            connection.stateUpdateHandler = { [weak self] state in
                self?.assumeIsolated { $0.connectionChanged(connection, state) }
            }
            connection.start(queue: queue)
            let limit = options.connectTimeout
            Task { [weak self] in
                try? await Task.sleep(for: limit)
                await self?.connectFailed(connection, LGError.timeout("connect to \(url)"))
            }
        }
        receiveNext(connection)
    }

    private static func leafFingerprint(_ trust: sec_trust_t) -> String? {
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
        guard let leaf = (SecTrustCopyCertificateChain(secTrust) as? [SecCertificate])?.first else { return nil }
        return CertificatePinning.fingerprint(der: SecCertificateCopyData(leaf) as Data)
    }

    /// TLS verify block body: trust on first use, then pin the leaf certificate's SHA-256.
    private func verify(_ presented: String?, pinned: String?) -> Bool {
        guard let presented else { return false }
        certificateFingerprint = presented
        do {
            try CertificatePinning.check(pinned: pinned, presented: presented)
            return true
        } catch {
            rejectedFingerprint = presented
            return false
        }
    }

    private func connectionChanged(_ connection: NWConnection, _ state: NWConnection.State) {
        guard connection === self.connection else { return }
        switch state {
        case .ready:
            connectWaiter?.resume()
            connectWaiter = nil
        case .waiting(let error), .failed(let error):
            if connectWaiter != nil { connectFailed(connection, error) } else { teardown(LGError.connectionFailed("\(error)")) }
        case .cancelled:
            if connectWaiter == nil, !closed { teardown(nil) }
        default:
            break
        }
    }

    private func connectFailed(_ connection: NWConnection, _ error: any Error) {
        guard connection === self.connection, let waiter = connectWaiter else { return }
        connectWaiter = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        self.connection = nil
        waiter.resume(throwing: error)
    }

    private func map(_ error: any Error) -> any Error {
        if let presented = rejectedFingerprint, let pinned = options.pinnedFingerprint {
            return LGError.certificateChanged(pinned: pinned, presented: presented)
        }
        if error is LGError { return error }
        return LGError.connectionFailed("\(host): \(error)")
    }

    private func receiveNext(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            self?.assumeIsolated { me in
                guard connection === me.connection, !me.closed else { return }
                if let error { return me.teardown(LGError.connectionFailed("receive: \(error)")) }
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                if metadata?.opcode == .close { return me.teardown(LGError.connectionFailed("TV closed the socket")) }
                if let data, !data.isEmpty { me.handle(data) }
                me.receiveNext(connection)
            }
        }
    }

    private func startKeepalive() {
        let interval = options.pingInterval
        keepalive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, await self.ping(interval: interval) else { return }
            }
        }
    }

    private func ping(interval: Duration) -> Bool {
        guard let connection, !closed else { return false }
        if ContinuousClock.now - lastPong > interval * 2 + .seconds(5) {
            teardown(LGError.timeout("keepalive pong"))
            return false
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
        metadata.setPongHandler(queue) { [weak self] error in
            if error == nil { self?.assumeIsolated { $0.lastPong = .now } }
        }
        connection.send(
            content: Data(), contentContext: .init(identifier: "ping", metadata: [metadata]),
            isComplete: true, completion: .idempotent)
        return true
    }

    private func teardown(_ error: (any Error)?) {
        guard !closed else { return }
        closed = true
        keepalive?.cancel()
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        for (_, entry) in pending {
            entry.timeout?.cancel()
            entry.continuation?.resume(throwing: error ?? LGError.notConnected)
            entry.stream?.finish()
        }
        pending.removeAll()
        stateSink.yield(.disconnected(error))
        stateSink.finish()
    }
}
