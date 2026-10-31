import CryptoKit
import Foundation
import Network

/// The Apple TV end of the link: a TLS-PSK listener (optionally advertised over Bonjour) that authenticates Macs by PIN
/// or pairing token, answers `hello`, `pair` and `ping` itself, and forwards rendering requests to the app as events.
///
/// Callbacks run on the actor's own serial queue, so connection events and messages keep their order.
public actor PatternLinkServer {
    /// Identifies one accepted connection for the lifetime of the server.
    public struct ConnectionID: Hashable, Sendable, CustomStringConvertible {
        public let rawValue: Int
        public var description: String { "#\(rawValue)" }
    }

    public enum ServerEvent: Sendable {
        case listening(port: UInt16)
        /// A Mac completed the TLS handshake. `identity` is `pin:<uuid>` or `tok:<uuid>` (`unknown` if it could not be tied).
        case clientConnected(ConnectionID, identity: String)
        case clientDisconnected(ConnectionID)
        /// `.show`, `.setDisplayMode`, `.blank` or `.queryStatus` for the app to perform and answer with `send(_:to:)`.
        case message(ConnectionID, ClientMessage)
        case pinChanged(String)
        case paired(clientName: String, clientID: UUID)
        case failed(String)
    }

    private struct Peer {
        let connection: NWConnection
        var identity: String?
    }

    /// Events for the app. Single consumer; unbounded buffer, so the app must keep reading.
    public nonisolated let events: AsyncStream<ServerEvent>
    /// This TV's stable id from the pairing store; Macs key their stored tokens by it.
    public nonisolated let deviceID: UUID
    public nonisolated let deviceName: String
    /// The 6-digit PIN to show on screen. Regenerated on `start` and after each successful pairing.
    public private(set) var currentPIN = ""
    /// The bound port while listening.
    public private(set) var port: UInt16?

    private let eventSink: AsyncStream<ServerEvent>.Continuation
    private let capabilitiesProvider: @Sendable () -> DeviceCapabilities
    private let pairingStore: PairingStore
    private let serviceName: String
    private let queue = DispatchSerialQueue(label: "PatternLinkServer")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private var listener: NWListener?
    private var running = false
    private var advertise = false
    private var bindRetries = 0
    /// Port to listen on again once the listener being replaced by `rekey()` reports `.cancelled`.
    private var rekeyPort: NWEndpoint.Port?
    private var peers: [ConnectionID: Peer] = [:]
    private var nextConnection = 0
    /// Online PIN guessing limit: after a failed handshake, refuse new connections for a second, and allow only a few
    /// handshakes at once, each for at most 5 s. Bounds an attacker to a few guesses per second (≈ days for a 6-digit PIN).
    private var lockedUntil = ContinuousClock.now
    private static let maxConcurrentHandshakes = 4
    private static let handshakeTimeout = 5
    /// Client PSK identity per TLS handshake, keyed by the handshake's metadata object (see `LinkSecurity`).
    private var handshakeIdentities: [ObjectIdentifier: String] = [:]

    /// - Parameters:
    ///   - capabilitiesProvider: called on the server's queue for every `hello`; must be thread-safe (return a snapshot,
    ///     do not touch main-actor-only UIKit state from it).
    ///   - serviceName: Bonjour service name, also the salt of the PIN key. Defaults to `deviceName`.
    public init(
        deviceName: String, capabilitiesProvider: @escaping @Sendable () -> DeviceCapabilities,
        pairingStore: PairingStore, serviceName: String? = nil
    ) {
        self.deviceName = deviceName
        self.capabilitiesProvider = capabilitiesProvider
        self.pairingStore = pairingStore
        self.serviceName = serviceName ?? deviceName
        deviceID = pairingStore.deviceID()
        (events, eventSink) = AsyncStream.makeStream()
    }

    deinit {
        listener?.cancel()
        for peer in peers.values { peer.connection.cancel() }
        eventSink.finish()
    }

    /// Starts listening with a fresh PIN. `.any` picks a free port (reported by `.listening`). With `advertise`, the
    /// listener registers a Bonjour service named after the device, with the device id in its TXT record (`id`).
    public func start(port: NWEndpoint.Port = .any, advertise: Bool = true) throws {
        stop()
        running = true
        self.advertise = advertise
        bindRetries = 0
        rotatePIN()
        do { try startListener(port: port) } catch {
            running = false
            throw error
        }
    }

    /// Stops listening and closes every connection.
    public func stop() {
        running = false
        rekeyPort = nil
        listener?.cancel()
        listener = nil
        port = nil
        for (id, peer) in peers {
            peer.connection.cancel()
            if peer.identity != nil { eventSink.yield(.clientDisconnected(id)) }
        }
        peers.removeAll()
        handshakeIdentities.removeAll()
    }

    /// Sends a message to one client; returns once it has been handed to the network stack.
    public func send(_ message: ServerMessage, to id: ConnectionID) async {
        guard let connection = peers[id]?.connection, let body = try? LinkCodec.encode(message) else {
            return
        }
        await withCheckedContinuation { continuation in
            connection.sendFrame(body) { _ in continuation.resume() }
        }
    }

    /// Sends a message to every authenticated client.
    public func broadcast(_ message: ServerMessage) {
        for (id, peer) in peers where peer.identity != nil { post(message, to: id) }
    }

    // MARK: - Listener

    private func startListener(port: NWEndpoint.Port) throws {
        var keys = [
            LinkSecurity.pinKeyIdentity: LinkSecurity.pinKey(pin: currentPIN, serviceName: serviceName)
                .withUnsafeBytes { Data($0) }
        ]
        for clientID in pairingStore.allClientIDs() {
            keys[LinkSecurity.tokenIdentity(clientID)] = pairingStore.token(for: clientID)
        }
        let parameters = LinkSecurity.serverParameters(keys: keys, queue: queue) {
            [weak self] identity, metadata in
            let handshake = ObjectIdentifier(metadata)
            self?.assumeIsolated { server in
                // ponytail: bounded instead of pruned per failed handshake; a flood only costs concurrent PIN clients their pairing right.
                if server.handshakeIdentities.count > 64 { server.handshakeIdentities.removeAll() }
                server.handshakeIdentities[handshake] = identity
            }
        }
        let listener = try NWListener(using: parameters, on: port)
        if advertise {
            listener.service = NWListener.Service(
                name: serviceName, type: patternLinkServiceType, domain: nil,
                txtRecord: NWTXTRecord(["id": deviceID.uuidString]))
        }
        listener.stateUpdateHandler = { [weak self] state in
            self?.assumeIsolated { $0.listenerChanged(listener, state, port: port) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.assumeIsolated { $0.accept(connection) }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    private func listenerChanged(
        _ listener: NWListener, _ state: NWListener.State, port requested: NWEndpoint.Port
    ) {
        switch state {
        case .ready where listener === self.listener:
            bindRetries = 0
            port = listener.port?.rawValue
            if let port { eventSink.yield(.listening(port: port)) }
        case .failed(let error) where listener === self.listener:
            self.listener = nil
            // A just-cancelled listener can hold the port for a few ms (restart on the same port).
            if case .posix(.EADDRINUSE) = error, bindRetries < 40 {
                bindRetries += 1
                queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
                    self?.assumeIsolated { server in
                        guard server.running, server.listener == nil else { return }
                        do { try server.startListener(port: requested) } catch {
                            server.eventSink.yield(.failed("\(error)"))
                        }
                    }
                }
            } else {
                eventSink.yield(.failed("Listener failed: \(error)"))
            }
        case .cancelled:
            // Rekey: the old listener released its port; listen again with the new key set.
            guard let port = rekeyPort, running, self.listener == nil else { return }
            rekeyPort = nil
            do { try startListener(port: port) } catch { eventSink.yield(.failed("\(error)")) }
        default:
            break
        }
    }

    /// Network.framework copies PSKs when the listener starts, so a new PIN or token needs a new listener.
    private func rekey() {
        guard running, let listener, let port = listener.port else { return }
        self.listener = nil
        rekeyPort = port
        listener.cancel()
    }

    private func rotatePIN() {
        currentPIN = String(format: "%06d", Int.random(in: 0..<1_000_000))
        eventSink.yield(.pinChanged(currentPIN))
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        guard ContinuousClock.now >= lockedUntil,
            peers.values.count(where: { $0.identity == nil }) < Self.maxConcurrentHandshakes
        else {
            return connection.cancel()
        }
        nextConnection += 1
        let id = ConnectionID(rawValue: nextConnection)
        peers[id] = Peer(connection: connection)
        connection.stateUpdateHandler = { [weak self] state in
            self?.assumeIsolated { $0.connectionChanged(id, state) }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + .seconds(Self.handshakeTimeout)) { [weak self] in
            self?.assumeIsolated { server in
                if server.peers[id]?.identity == nil { server.handshakeFailed(id) }
            }
        }
    }

    private func handshakeFailed(_ id: ConnectionID) {
        lockedUntil = .now + .seconds(1)
        close(id)
    }

    private func connectionChanged(_ id: ConnectionID, _ state: NWConnection.State) {
        guard let peer = peers[id] else { return }
        switch state {
        case .ready:
            let metadata =
                peer.connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
            let identity =
                metadata.flatMap {
                    handshakeIdentities.removeValue(forKey: ObjectIdentifier($0.securityProtocolMetadata))
                } ?? "unknown"
            peers[id]?.identity = identity
            eventSink.yield(.clientConnected(id, identity: identity))
            receive(id, on: peer.connection)
        case .failed, .waiting:
            if peer.identity == nil { handshakeFailed(id) } else { close(id) }
        case .cancelled:
            close(id)
        default:
            break
        }
    }

    private func close(_ id: ConnectionID) {
        guard let peer = peers.removeValue(forKey: id) else { return }
        peer.connection.cancel()
        if peer.identity != nil { eventSink.yield(.clientDisconnected(id)) }
    }

    private func receive(_ id: ConnectionID, on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, _, _, error in
            self?.assumeIsolated { server in
                guard let content, error == nil else { return server.close(id) }
                server.handle(content, from: id)
                if server.peers[id] != nil { server.receive(id, on: connection) }
            }
        }
    }

    private func post(_ message: ServerMessage, to id: ConnectionID, thenClose: Bool = false) {
        guard let connection = peers[id]?.connection, let body = try? LinkCodec.encode(message) else {
            return
        }
        connection.sendFrame(body) { [weak self] _ in
            guard thenClose else { return }
            self?.assumeIsolated { $0.close(id) }
        }
    }

    private func handle(_ body: Data, from id: ConnectionID) {
        guard let message = try? LinkCodec.decode(ClientMessage.self, from: body) else {
            return post(.error(LinkError(code: "decode", message: "Unreadable message")), to: id)
        }
        switch message {
        case .hello(let hello):
            guard hello.protocolVersion == patternLinkProtocolVersion else {
                return post(
                    .error(
                        LinkError(
                            code: "version",
                            message:
                                "Apple TV speaks protocol \(patternLinkProtocolVersion), Mac sent \(hello.protocolVersion)"
                        )),
                    to: id, thenClose: true)
            }
            post(.welcome(capabilitiesProvider()), to: id)
        case .pair(let request):
            pair(request, from: id)
        case .ping:
            post(.pong, to: id)
        case .show, .setDisplayMode, .blank, .queryStatus:
            eventSink.yield(.message(id, message))
        }
    }

    private func pair(_ request: PairRequest, from id: ConnectionID) {
        // Only a PIN-authenticated session may mint a token, and only for the client id it authenticated as.
        guard let identity = peers[id]?.identity, identity.hasPrefix("pin:"),
            let clientID = UUID(uuidString: String(identity.dropFirst(4))), clientID == request.clientID
        else {
            return post(
                .error(
                    LinkError(code: "pairing", message: "Pairing needs a PIN session for the same client id")),
                to: id)
        }
        let token = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        pairingStore.setToken(token, for: clientID)
        post(.paired(PairResponse(token: token, deviceID: deviceID)), to: id)
        eventSink.yield(.paired(clientName: request.clientName, clientID: clientID))
        rotatePIN()
        rekey()
    }
}
