import Calibration
import Foundation
import LGControl

/// The TV card's state: LG discovery, pairing, capabilities and picture settings, or the simulated TV.
@Observable
final class TVDevice {
    private(set) var kind: DeviceKind
    private(set) var phase = DevicePhase.idle
    private(set) var discovered: [DiscoveredTV] = []
    private(set) var isSearching = false
    var manualHost = ""
    private(set) var host: String?
    private(set) var capabilities: TVCapabilities?
    private(set) var settings: PictureSettings?
    private(set) var snapshotNote: String?
    private(set) var snapshotURL: URL?
    private(set) var history: [StateEntry] = []
    var error: ErrorText?
    private(set) var controller: (any TVController)?

    @ObservationIgnored private let panel: SimulatedPanel
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let snapshotDirectory: URL
    @ObservationIgnored private var stateTask: Task<Void, Never>?
    /// Where pairing keys live, and how to reach the TV (the DEBUG checks point both at `FakeWebOSServer`).
    @ObservationIgnored var credentials: any TVCredentialStore = KeychainTVCredentialStore()
    @ObservationIgnored var connectionOptions = LGTV.Options()

    init(panel: SimulatedPanel, defaults: UserDefaults, snapshotDirectory: URL) {
        self.panel = panel
        self.defaults = defaults
        self.snapshotDirectory = snapshotDirectory
        kind = DeviceKind(rawValue: defaults.string(forKey: "tv.kind") ?? "") ?? .real
        manualHost = defaults.string(forKey: "tv.lastHost") ?? ""
    }

    /// webOS platform release parsed from the capabilities ("11.1 (webOS 26)").
    var release: WebOSRelease? {
        capabilities?.webOSVersion.flatMap { $0.split(separator: " ").first.map(String.init) }.flatMap(WebOSRelease.init(version:))
    }

    var lastHost: String? { defaults.string(forKey: "tv.lastHost") }

    func setKind(_ kind: DeviceKind) async {
        guard kind != self.kind || controller == nil else { return }
        await disconnect()
        self.kind = kind
        defaults.set(kind.rawValue, forKey: "tv.kind")
        if kind == .simulated { await connectSimulated() } else { await discover() }
    }

    /// Real TVs: SSDP search, then reconnect to the last TV (its pairing key is in the Keychain).
    func start() async {
        if kind == .simulated { return await connectSimulated() }
        if let host = lastHost { await connect(host: host, id: defaults.string(forKey: "tv.lastID")) }
        await discover()
    }

    func discover() async {
        guard !isSearching else { return }
        isSearching = true
        defer { isSearching = false }
        for await list in LGDiscovery().discover(duration: .seconds(4)) { discovered = list }
    }

    func connect(host: String, id: String?) async {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        await disconnect()
        let tv = LGTVController(host: host, tvID: id, credentials: credentials, options: connectionOptions)
        controller = tv
        self.host = host
        phase = .connecting
        log("Connecting to \(host)")
        stateTask = Task { [weak self] in
            for await state in tv.state { self?.apply(state) }
        }
        do {
            try await tv.connect()
            guard controller === tv else { return }
            capabilities = await tv.capabilities
            phase = .connected
            log("Connected: \(capabilities?.modelName ?? "TV")")
            defaults.set(host, forKey: "tv.lastHost")
            defaults.set(id, forKey: "tv.lastID")
            await refreshSettings()
        } catch {
            guard controller === tv else { return }
            fail(error)
        }
    }

    func connectSimulated() async {
        await disconnect()
        let tv = SimulatedTVController(panel: panel)
        controller = tv
        host = "simulated"
        do {
            try await tv.connect()
            capabilities = await tv.capabilities
            phase = .connected
            log("Simulated TV connected")
            await refreshSettings()
        } catch { fail(error) }
    }

    func disconnect() async {
        stateTask?.cancel()
        stateTask = nil
        let old = controller
        controller = nil
        capabilities = nil
        settings = nil
        snapshotNote = nil
        snapshotURL = nil
        phase = .idle
        await old?.disconnect()
    }

    /// Removes the stored pairing key of the last TV so the next connect pairs from scratch.
    func forget() async {
        if let id = defaults.string(forKey: "tv.lastID") { try? credentials.remove(tvID: id) }
        defaults.removeObject(forKey: "tv.lastHost")
        defaults.removeObject(forKey: "tv.lastID")
        await disconnect()
        log("Forgot the stored pairing")
    }

    func refreshSettings() async {
        guard let controller else { return }
        do { settings = try await controller.readPictureSettings(pictureMode: nil) } catch { self.error = ErrorText(error) }
    }

    /// Reads the current picture settings and saves them as JSON. Calibration data (LUTs) cannot be read back.
    func takeSnapshot() async {
        guard let controller else { return }
        do {
            let settings = try await controller.readPictureSettings(pictureMode: nil)
            self.settings = settings
            let input = capabilities?.inputs.first(where: \.isConnected)?.id ?? "HDMI_1"
            let point = RestorePoint(inputID: input, settings: settings)
            try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
            let stamp = settings.capturedAt.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
                .replacingOccurrences(of: ":", with: "")
            let url = snapshotDirectory.appendingPathComponent("\(settings.pictureMode) \(stamp).json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(point).write(to: url, options: .atomic)
            snapshotURL = url
            snapshotNote =
                "\(settings.values.count) settings of \(PictureModes.name(settings.pictureMode)) saved \(Fmt.date(settings.capturedAt))"
        } catch { self.error = ErrorText(error) }
    }

    private func apply(_ state: SSAPState) {
        switch state {
        case .connecting:
            log("SSAP connecting")
        case .pairing:
            log("Pairing prompt shown on the TV")
            if phase != .connected { phase = .waitingForUser }
        case .registered:
            log("Registered")
        case .disconnected(let error):
            log("Disconnected\(error.map { ": \($0)" } ?? "")")
            if phase == .connected {
                phase = error == nil ? .idle : .failed
                capabilities = nil
                if let error { self.error = ErrorText(error) }
            }
        }
    }

    private func fail(_ error: any Error) {
        phase = .failed
        self.error = ErrorText(error)
        log("Error: \(error)")
    }

    private func log(_ text: String) {
        history.append(StateEntry(text: text))
        if history.count > 50 { history.removeFirst(history.count - 50) }
    }

    #if DEBUG
        /// Screenshot rendering only.
        func setPreviewState(kind: DeviceKind, phase: DevicePhase, error: ErrorText?) async {
            await disconnect()
            self.kind = kind
            self.phase = phase
            self.error = error
        }
    #endif
}
