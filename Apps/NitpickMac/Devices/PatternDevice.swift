import Calibration
import ColorScience
import Foundation
import Network
import PatternLink

/// The pattern-generator card's state: Bonjour discovery, PIN pairing and token reconnects to the Apple TV, or the
/// simulated Apple TV; diagnostics, display mode and a manual test pattern.
@Observable
final class PatternDevice {
    /// Where to connect: a Bonjour result or a manually entered host and port.
    struct Target: Equatable {
        var name: String
        var endpoint: NWEndpoint
        /// The Bonjour service name; it salts the PIN key, so it must match what the Apple TV shows.
        var serviceName: String
        var deviceID: UUID?
        var manual: String?
    }

    private(set) var kind: DeviceKind
    private(set) var phase = DevicePhase.idle
    private(set) var discovered: [PatternLinkBrowser.DiscoveredDevice] = []
    /// Waiting for the PIN of this device.
    private(set) var pinTarget: Target?
    private(set) var connectedName: String?
    var pin = ""
    var manualHost = ""
    var manualPort = ""
    var manualName = ""
    private(set) var capabilities: DeviceCapabilities?
    private(set) var diagnostics = LinkDiagnostics()
    private(set) var reconnectAttempts = 0
    private(set) var history: [StateEntry] = []
    var error: ErrorText?
    // Test pattern
    var testLevel = 50.0
    var testWindow = 0.10
    var testHDR = false

    @ObservationIgnored private let panel: SimulatedPanel
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let credentials = KeychainCredentialStore()
    @ObservationIgnored private let client: PatternLinkClient
    @ObservationIgnored private var browser: PatternLinkBrowser?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    private(set) var source: (any PatternSource)?
    private(set) var simulated: SimulatedPatternSource?

    init(panel: SimulatedPanel, defaults: UserDefaults) {
        self.panel = panel
        self.defaults = defaults
        kind = DeviceKind(rawValue: defaults.string(forKey: "pattern.kind") ?? "") ?? .real
        let clientID: UUID
        if let stored = defaults.string(forKey: "pattern.clientID").flatMap(UUID.init(uuidString:)) {
            clientID = stored
        } else {
            clientID = UUID()
            defaults.set(clientID.uuidString, forKey: "pattern.clientID")
        }
        client = PatternLinkClient(
            clientName: Host.current().localizedName ?? "Mac", clientID: clientID, credentialStore: KeychainCredentialStore())
        manualHost = defaults.string(forKey: "pattern.manualHost") ?? ""
        manualPort = defaults.string(forKey: "pattern.manualPort") ?? ""
        manualName = defaults.string(forKey: "pattern.serviceName") ?? ""
    }

    func setKind(_ kind: DeviceKind) async {
        guard kind != self.kind || source == nil else { return }
        await disconnect()
        self.kind = kind
        defaults.set(kind.rawValue, forKey: "pattern.kind")
        await start()
    }

    func start() async {
        if kind == .simulated { return await connectSimulated() }
        startBrowsing()
        // A manually added Apple TV with a stored token reconnects at once; Bonjour ones when they appear.
        if let host = defaults.string(forKey: "pattern.lastManual"), let target = manualTarget(host: host), let id = target.deviceID,
            let token = credentials.token(for: id)
        {
            await connect(target, token: token)
        }
    }

    private func startBrowsing() {
        guard browser == nil else { return }
        let browser = PatternLinkBrowser()
        self.browser = browser
        tasks.append(
            Task { [weak self] in
                await browser.start()
                for await list in browser.devices {
                    guard let self else { return }
                    discovered = list
                    autoReconnect()
                }
            })
        tasks.append(
            Task { [weak self, client] in
                for await state in client.state { self?.apply(state) }
            })
    }

    func hasToken(_ device: PatternLinkBrowser.DiscoveredDevice) -> Bool {
        device.deviceID.flatMap(credentials.token(for:)) != nil
    }

    /// Picks a discovered Apple TV: reconnects with its stored token, otherwise asks for the PIN.
    func select(_ device: PatternLinkBrowser.DiscoveredDevice) async {
        let target = Target(name: device.name, endpoint: device.endpoint, serviceName: device.id, deviceID: device.deviceID)
        if let id = device.deviceID, let token = credentials.token(for: id) { await connect(target, token: token) } else { askPIN(target) }
    }

    func selectManual() async {
        let host = manualHost.trimmingCharacters(in: .whitespaces)
        defaults.set(host, forKey: "pattern.manualHost")
        defaults.set(manualPort, forKey: "pattern.manualPort")
        defaults.set(manualName, forKey: "pattern.serviceName")
        guard let target = manualTarget(host: host) else {
            error = ErrorText(
                title: "Incomplete address", message: "Enter the host, the port and the name shown on the Apple TV.",
                nextStep: "Nitpick on the Apple TV shows them under the pairing code, for example “Living Room” · 192.168.1.30:52103.")
            return
        }
        if let id = target.deviceID, let token = credentials.token(for: id) { await connect(target, token: token) } else { askPIN(target) }
    }

    private func manualTarget(host: String) -> Target? {
        let name = manualName.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !name.isEmpty, let port = UInt16(manualPort) else { return nil }
        let key = "\(host):\(port)"
        let id = defaults.string(forKey: "pattern.deviceID.\(key)").flatMap(UUID.init(uuidString:))
        return Target(
            name: name, endpoint: PatternLinkBrowser.endpoint(host: host, port: port), serviceName: name, deviceID: id, manual: key)
    }

    private func askPIN(_ target: Target) {
        pin = ""
        pinTarget = target
        phase = .waitingForUser
        error = nil
    }

    func cancelPIN() {
        pinTarget = nil
        pin = ""
        if phase == .waitingForUser { phase = .idle }
    }

    /// PIN session → pair (the token lands in the Keychain) → reconnect with the token.
    func submitPIN() async {
        guard var target = pinTarget, pin.count == 6 else { return }
        phase = .connecting
        error = nil
        do {
            _ = try await client.connect(to: target.endpoint, serviceName: target.serviceName, credential: .pin(pin))
            let response = try await client.pair()
            target.deviceID = response.deviceID
            pinTarget = nil
            pin = ""
            await connect(target, token: response.token)
        } catch {
            phase = .waitingForUser
            pin = ""
            self.error = ErrorText(error)
        }
    }

    private func connect(_ target: Target, token: Data) async {
        phase = .connecting
        error = nil
        let remote = RemotePatternSource(
            client: client, endpoint: target.endpoint, serviceName: target.serviceName, credential: .token(token))
        do {
            try await remote.connect()
            source = remote
            capabilities = await remote.capabilities
            connectedName = target.name
            phase = .connected
            reconnectAttempts = 0
            remember(target)
            startPolling()
        } catch PatternLinkError.authenticationFailed {
            askPIN(target)
            error = ErrorText(
                title: "Pair again", message: "\(target.name) no longer accepts the saved pairing.",
                nextStep: "Enter the 6-digit code shown in Nitpick on the Apple TV.")
        } catch {
            phase = .failed
            self.error = ErrorText(error)
        }
    }

    private func remember(_ target: Target) {
        defaults.set(target.serviceName, forKey: "pattern.lastService")
        if let key = target.manual {
            defaults.set(key, forKey: "pattern.lastManual")
            if let id = target.deviceID { defaults.set(id.uuidString, forKey: "pattern.deviceID.\(key)") }
        } else {
            defaults.removeObject(forKey: "pattern.lastManual")
        }
    }

    /// The last Apple TV reconnects with its token when Bonjour finds it again.
    private func autoReconnect() {
        guard phase == .idle, source == nil, let last = defaults.string(forKey: "pattern.lastService"),
            let device = discovered.first(where: { $0.id == last }), hasToken(device)
        else { return }
        phase = .connecting  // further Bonjour updates must not start a second connect
        Task { await select(device) }
    }

    func connectSimulated() async {
        await disconnect()
        let sim = SimulatedPatternSource(panel: panel)
        do {
            try await sim.connect()
            simulated = sim
            source = sim
            capabilities = await sim.capabilities
            connectedName = capabilities?.deviceName
            phase = .connected
        } catch {
            phase = .failed
            self.error = ErrorText(error)
        }
    }

    func disconnect() async {
        pollTask?.cancel()
        pollTask = nil
        let old = source
        source = nil
        simulated = nil
        capabilities = nil
        connectedName = nil
        pinTarget = nil
        phase = .idle
        await old?.disconnect()
    }

    /// Refreshes diagnostics every 2 s while connected to a real Apple TV.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self, client] in
            while !Task.isCancelled {
                let diagnostics = await client.diagnostics
                self?.diagnostics = diagnostics
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func ping() async {
        do {
            _ = try await client.ping()
            diagnostics = await client.diagnostics
        } catch { self.error = ErrorText(error) }
    }

    /// Asks the Apple TV for its current output state.
    func refreshDisplayMode() async {
        if let simulated {
            capabilities = await simulated.capabilities
            return
        }
        do { capabilities?.displayMode = try await client.queryStatus() } catch { self.error = ErrorText(error) }
    }

    func showTestPattern() async {
        guard let source else { return }
        let format: SignalFormat = testHDR ? .hdr10 : .sdr
        let pattern = PatternSpec.patch(
            .gray(testLevel / 100), window: WindowSpec(areaFraction: testWindow), format: format,
            hdr10Metadata: testHDR ? .p3D65_1000 : nil)
        do { _ = try await source.show(pattern) } catch { self.error = ErrorText(error) }
    }

    func blank() async {
        do { try await source?.blank() } catch { self.error = ErrorText(error) }
    }

    private func apply(_ state: PatternLinkClient.ConnectionState) {
        switch state {
        case .idle: log("Idle")
        case .connecting: log("Connecting")
        case .authenticating: log("Authenticating")
        case .connected(let caps):
            log("Connected to \(caps.deviceName)")
            if case .reconnecting = phase, source != nil {
                capabilities = caps
                phase = .connected
            }
        case .reconnecting(let attempt):
            log("Reconnecting, attempt \(attempt)")
            reconnectAttempts += 1
            if source != nil { phase = .reconnecting(attempt) }
        case .failed(let message):
            log("Failed: \(message)")
            if source != nil, phase != .connecting {
                phase = .failed
                error = ErrorText(
                    title: "Connection to the Apple TV lost", message: message, nextStep: "Select the Apple TV again to reconnect.")
            }
        }
    }

    private func log(_ text: String) {
        history.append(StateEntry(text: text))
        if history.count > 50 { history.removeFirst(history.count - 50) }
    }

    #if DEBUG
        func setPreviewState(kind: DeviceKind, phase: DevicePhase, pinFor name: String?, error: ErrorText?) async {
            await disconnect()
            self.kind = kind
            self.phase = phase
            self.error = error
            pinTarget = name.map {
                Target(name: $0, endpoint: PatternLinkBrowser.endpoint(host: "192.168.1.30", port: 7878), serviceName: $0, deviceID: nil)
            }
        }
    #endif
}
