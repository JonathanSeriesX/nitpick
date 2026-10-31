import Calibration
import ColorScience
import Foundation
import MeterKit

/// Time for demo mode: every wait advances the simulated panel's virtual clock in full but only sleeps
/// `1/speedup` of it for real, so a demo session plays out in about a minute and the UI still shows progress.
nonisolated final class DemoClock: Sleeper {
    let speedup: Double
    private let virtual = VirtualClock(start: Date())

    init(speedup: Double) { self.speedup = speedup }

    var now: Date { virtual.now }

    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration / speedup)
        virtual.advance(by: duration)
    }
}

/// The real i1d3 driver on the virtual USB device (`FakeI1D3Transport`), pointed at the simulated panel: before each
/// reading the transport's light is set to what the panel shows. Exercises EEPROM reading and corrections without hardware.
nonisolated final class VirtualMeter: Meter {
    let driver: I1D3Meter
    private let transport: FakeI1D3Transport
    private let panel: SimulatedPanel

    init(panel: SimulatedPanel) {
        transport = FakeI1D3Transport()
        driver = I1D3Meter(transport: transport)
        self.panel = panel
    }

    var info: MeterInfo { get async { await driver.info } }
    func connect() async throws { try await driver.connect() }
    func disconnect() async { await driver.disconnect() }
    func setCorrection(_ correction: ColorimeterCorrection?) async throws { try await driver.setCorrection(correction) }

    func measure(expectedLuminance: Double?) async throws -> MeterReading {
        await transport.setStimulus(.xyz(panel.displayedXYZ()))
        return try await driver.measure(expectedLuminance: expectedLuminance)
    }
}
