import Calibration
import ColorScience
import Foundation
import MeterKit

/// The meter card's state: USB discovery, the i1d3 driver (real or on the virtual device), or the simulated meter.
@Observable
final class MeterDevice {
    private(set) var kind: MeterKind
    private(set) var phase = DevicePhase.idle
    /// EEPROM read progress 0…1 while connecting an i1d3.
    private(set) var progress: Double?
    private(set) var hidDevices: [HIDDeviceIdentity] = []
    private(set) var info: MeterInfo?
    private(set) var diagnostics: [String: String] = [:]
    private(set) var correction: ColorimeterCorrection?
    var error: ErrorText?
    private(set) var meter: (any Meter)?

    @ObservationIgnored private let panel: SimulatedPanel
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var discoveryTask: Task<Void, Never>?
    @ObservationIgnored private let discovery = MeterDiscovery()

    init(panel: SimulatedPanel, defaults: UserDefaults) {
        self.panel = panel
        self.defaults = defaults
        kind = MeterKind(rawValue: defaults.string(forKey: "meter.kind") ?? "") ?? .usb
    }

    func setKind(_ kind: MeterKind) async {
        guard kind != self.kind || meter == nil else { return }
        await disconnect()
        self.kind = kind
        defaults.set(kind.rawValue, forKey: "meter.kind")
        await start()
    }

    func start() async {
        switch kind {
        case .usb: startDiscovery()
        case .virtual: await connectVirtual()
        case .simulated: await connectSimulated()
        }
    }

    /// Follows plug and unplug events; connects automatically when exactly one meter is present.
    func startDiscovery() {
        guard discoveryTask == nil else { return }
        discoveryTask = Task { [weak self, discovery] in
            for await list in await discovery.devices {
                guard let self else { return }
                hidDevices = list
                if kind == .usb, meter == nil, phase == .idle, list.count == 1 { await connect(list[0]) }
                if let current = info, kind == .usb, meter != nil, !list.contains(where: { $0.serialNumber == current.serialNumber }) {
                    await disconnect()
                    error = ErrorText(MeterError.disconnected)
                }
            }
        }
    }

    func connect(_ identity: HIDDeviceIdentity) async {
        await connectI1D3(I1D3Meter(transport: CoreHIDTransport(identity: identity)), wrapper: nil)
    }

    func connectVirtual() async {
        let virtual = VirtualMeter(panel: panel)
        await connectI1D3(virtual.driver, wrapper: virtual)
    }

    func connectSimulated() async {
        await disconnect()
        let meter = SimulatedMeter(panel: panel)
        do {
            try await meter.connect()
            try await meter.setCorrection(correction)
            self.meter = meter
            info = await meter.info
            phase = .connected
        } catch { fail(error) }
    }

    private func connectI1D3(_ driver: I1D3Meter, wrapper: (any Meter)?) async {
        await disconnect()
        phase = .connecting
        progress = 0
        error = nil
        do {
            try await driver.connect { value in
                Task { @MainActor [weak self] in if self?.phase == .connecting { self?.progress = value } }
            }
            try await driver.setCorrection(correction)
            meter = wrapper ?? driver
            info = await driver.info
            diagnostics = await driver.diagnostics
            phase = .connected
        } catch { fail(error) }
        progress = nil
    }

    func disconnect() async {
        let old = meter
        meter = nil
        info = nil
        diagnostics = [:]
        phase = .idle
        await old?.disconnect()
    }

    /// Parses an Argyll .ccss or .ccmx and applies it (now, and on every later connect).
    func importCorrection(from url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            var parsed =
                url.pathExtension.lowercased() == "ccss"
                ? try ColorimeterCorrection(ccssText: text) : try ColorimeterCorrection(ccmxText: text)
            parsed.source = url.lastPathComponent
            try await meter?.setCorrection(parsed)
            correction = parsed
            error = nil
        } catch { self.error = ErrorText(error) }
    }

    func clearCorrection() async {
        do {
            try await meter?.setCorrection(nil)
            correction = nil
        } catch { self.error = ErrorText(error) }
    }

    private func fail(_ error: any Error) {
        phase = .failed
        self.error = ErrorText(error)
    }

    #if DEBUG
        func setPreviewState(kind: MeterKind, phase: DevicePhase, error: ErrorText?) async {
            await disconnect()
            self.kind = kind
            self.phase = phase
            self.error = error
        }
    #endif
}
