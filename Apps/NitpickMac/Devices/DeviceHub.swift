import Calibration
import ColorScience
import Foundation

/// The three devices a session needs. Simulated devices share one `SimulatedPanel`, so a simulated TV, Apple TV and
/// meter behave like one real setup; real and simulated devices can be mixed.
@Observable
final class DeviceHub {
    /// Demo time: 40× faster than real time.
    static let demoSpeedup = 40.0

    let clock: DemoClock
    let panel: SimulatedPanel
    let tv: TVDevice
    let meter: MeterDevice
    let pattern: PatternDevice
    let network = LocalNetworkMonitor()

    init(defaults: UserDefaults, snapshotDirectory: URL) {
        clock = DemoClock(speedup: Self.demoSpeedup)
        panel = SimulatedPanel(clock: clock)
        tv = TVDevice(panel: panel, defaults: defaults, snapshotDirectory: snapshotDirectory)
        meter = MeterDevice(panel: panel, defaults: defaults)
        pattern = PatternDevice(panel: panel, defaults: defaults)
    }

    /// All three devices simulated.
    var demoMode: Bool { tv.kind == .simulated && meter.kind == .simulated && pattern.kind == .simulated }

    func setDemoMode(_ on: Bool) async {
        if !on { network.start() }
        async let a: Void = tv.setKind(on ? .simulated : .real)
        async let b: Void = meter.setKind(on ? .simulated : .usb)
        async let c: Void = pattern.setKind(on ? .simulated : .real)
        _ = await (a, b, c)
    }

    /// Discovery and automatic reconnects. Call once at launch.
    func start() async {
        // Demo mode never touches the network, so it never triggers the local network prompt.
        if tv.kind == .real || pattern.kind == .real { network.start() }
        async let a: Void = tv.start()
        async let b: Void = meter.start()
        async let c: Void = pattern.start()
        _ = await (a, b, c)
    }

    var allConnected: Bool { tv.phase == .connected && meter.phase == .connected && pattern.phase == .connected }

    /// What is missing before a session can run, or nil.
    var missingDevice: String? {
        if tv.phase != .connected { return "Connect the TV on the Devices screen." }
        if meter.phase != .connected { return "Connect the meter on the Devices screen." }
        if pattern.phase != .connected { return "Connect the pattern generator on the Devices screen." }
        return nil
    }

    func workflowDevices() throws -> WorkflowRunner.Devices {
        guard let m = meter.meter else { throw CalibrationError.notConnected("Meter") }
        guard let p = pattern.source else { throw CalibrationError.notConnected("Pattern generator") }
        guard let t = tv.controller else { throw CalibrationError.notConnected("TV") }
        return (m, p, t)
    }

    /// Patterns on the simulated panel settle on its clock; real patterns need real time.
    var sleeper: any Sleeper { pattern.kind == .simulated ? clock : RealSleeper() }
}
