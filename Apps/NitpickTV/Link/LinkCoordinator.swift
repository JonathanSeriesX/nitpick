import Foundation
import PatternLink
import SwiftUI
import UIKit
import os

/// Runs the package's `PatternLinkServer` while the app is active and performs what the Mac asks for on the renderer.
@MainActor @Observable final class LinkCoordinator {
    struct Client {
        var clientID: UUID?
        var name: String
    }

    let deviceName = UIDevice.current.name
    /// Bonjour service name; also the PIN key salt, so it must match what the Mac browses.
    let serviceName: String
    private(set) var pin = ""
    private(set) var port: UInt16?
    private(set) var address: String?
    private(set) var status = "Starting…"
    private(set) var clients: [PatternLinkServer.ConnectionID: Client] = [:]
    private(set) var toast: String?
    private(set) var lastSequence: UInt32?
    var isConnected: Bool { !clients.isEmpty }

    private let renderer: PatternRenderer
    @ObservationIgnored private let server: PatternLinkServer
    /// What `hello` answers with. The server reads it on its own queue, so it is a locked snapshot.
    @ObservationIgnored private let capabilities: OSAllocatedUnfairLock<DeviceCapabilities>
    @ObservationIgnored private var lifecycle: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(
        subsystem: "com.jonathanseriesx.nitpick", category: "link")
    private static let clientNamesKey = "NitpickTV.clientNames"

    init(renderer: PatternRenderer) {
        self.renderer = renderer
        serviceName = deviceName
        let capabilities = OSAllocatedUnfairLock(
            initialState: DeviceCapabilities(
                deviceName: deviceName, model: Self.modelIdentifier,
                systemVersion: UIDevice.current.systemVersion,
                frameWidth: 1920, frameHeight: 1080, supportsDisplayCriteria: true,
                displayMode: DisplayModeState()))
        self.capabilities = capabilities
        server = PatternLinkServer(
            deviceName: deviceName, capabilitiesProvider: { capabilities.withLock { $0 } },
            pairingStore: UserDefaultsPairingStore(), serviceName: serviceName)
        let events = server.events
        Task { [weak self] in
            for await event in events { await self?.handle(event) }
        }
    }

    /// Starts listening (with a fresh PIN). Call when the scene becomes active.
    func start() {
        refreshCapabilities()
        status = "Starting…"
        enqueueLifecycle { server in try await server.start() }
    }

    /// Stops listening and drops every client. Call when the scene goes to the background.
    func stop() {
        status = "Paused"
        enqueueLifecycle { server in await server.stop() }
    }

    /// Runs start/stop strictly in call order.
    private func enqueueLifecycle(
        _ work: @escaping @Sendable (PatternLinkServer) async throws -> Void
    ) {
        let previous = lifecycle
        let server = server
        lifecycle = Task { [weak self] in
            await previous?.value
            do { try await work(server) } catch {
                self?.status = "Network error: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Events

    private func handle(_ event: PatternLinkServer.ServerEvent) async {
        switch event {
        case .listening(let port):
            self.port = port
            address = Self.ipv4Address()
            status = "Listening"
            #if DEBUG
                print("NITPICK_LISTENING port=\(port) name=\(serviceName)")  // simulator link tests read this
            #endif
        case .pinChanged(let pin):
            self.pin = pin
            #if DEBUG
                print("NITPICK_PIN=\(pin)")  // simulator link tests read the PIN from the console
            #endif
        case .clientConnected(let id, let identity):
            let clientID = UUID(uuidString: String(identity.dropFirst(4)))
            let name = clientID.flatMap { Self.clientNames[$0.uuidString] } ?? "Mac"
            clients[id] = Client(clientID: clientID, name: name)
            refreshCapabilities()
            showToast("Connected to \(name)")
            log.info(
                "Client \(id.description, privacy: .public) connected as \(identity, privacy: .public)")
        case .clientDisconnected(let id):
            clients[id] = nil
            if clients.isEmpty { status = "Mac disconnected" }
        case .paired(let clientName, let clientID):
            Self.clientNames[clientID.uuidString] = clientName
            for (id, client) in clients where client.clientID == clientID {
                clients[id]?.name = clientName
            }
            showToast("Paired with \(clientName)")
        case .failed(let reason):
            status = "Network error: \(reason)"
            log.error("Server: \(reason, privacy: .public)")
        case .message(let id, let message):
            await perform(message, for: id)
        }
    }

    private func perform(_ message: ClientMessage, for id: PatternLinkServer.ConnectionID) async {
        switch message {
        case .show(let sequence, let pattern):
            do {
                let shown = try renderer.show(pattern)
                lastSequence = sequence
                await server.send(
                    .shown(
                        ShowAck(
                            sequence: sequence, enqueuedAt: shown.enqueuedAt, centerCodes: shown.centerCodes)),
                    to: id)
            } catch {
                await server.send(
                    .error(LinkError(code: "render", message: error.localizedDescription)), to: id)
            }
        case .setDisplayMode(let request):
            let state = await renderer.requestDisplayMode(request)
            refreshCapabilities()
            await server.send(.displayMode(state), to: id)
        case .blank:
            // The protocol has no ack for blank; report only failures.
            do { _ = try renderer.show(.black(format: renderer.currentFormat)) } catch {
                await server.send(
                    .error(LinkError(code: "render", message: error.localizedDescription)), to: id)
            }
        case .queryStatus:
            await server.send(.displayMode(renderer.currentDisplayState()), to: id)
        case .hello, .pair, .ping:
            break  // answered by the server itself
        }
    }

    private func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { toast = nil }
        }
    }

    private func refreshCapabilities() {
        let size = renderer.frameSize
        let snapshot = DeviceCapabilities(
            deviceName: deviceName, model: Self.modelIdentifier,
            systemVersion: UIDevice.current.systemVersion,
            frameWidth: size.width, frameHeight: size.height,
            // Every tvOS window has an avDisplayManager (tvOS 11.2+); criteria from a format description need 17.0.
            supportsDisplayCriteria: true, displayMode: renderer.currentDisplayState())
        capabilities.withLock { $0 = snapshot }
    }

    // MARK: - Helpers

    /// Mac names learned at pairing, by client id, so reconnects with a token can be greeted by name.
    private static var clientNames: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: clientNamesKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: clientNamesKey) }
    }

    /// Hardware model, for example "AppleTV6,2" for the Apple TV 4K (1st generation).
    private static var modelIdentifier: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: info.machine) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// First IPv4 address of an up, non-loopback interface, preferring en* (Ethernet / Wi-Fi).
    static func ipv4Address() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var fallback: String?
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                flags & (IFF_UP | IFF_RUNNING) == (IFF_UP | IFF_RUNNING), flags & IFF_LOOPBACK == 0
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard
                getnameinfo(
                    address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
                    NI_NUMERICHOST)
                    == 0
            else { continue }
            let ip = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            if String(cString: entry.pointee.ifa_name).hasPrefix("en") { return ip }
            fallback = fallback ?? ip
        }
        return fallback
    }
}
