import Foundation
import Testing
import ColorScience
import PatternLink
@testable import Calibration

@Suite struct SimulationTests {
    @Test func expertDarkHasItsDocumentedErrors() async throws {
        let rig = Rig()
        try await rig.connect()
        #expect(rig.panel.pictureMode == "expert1")
        let white = rig.truth(.white)
        #expect(white.chromaticity.distance(to: Chromaticity(x: 0.3155, y: 0.3290)) < 0.0005)
        // OLED light 30 → 420·(0.05 + 0.95·0.3^1.2)
        #expect(abs(white.Y - 420 * (0.05 + 0.95 * pow(0.3, 1.2))) < 0.5)
        // Gamma ≈ 2.3 (BT.1886 setting 2.4 − 0.1); S-curve is zero at 50 %.
        let black = SimulatedPanel.blackLevel
        let gamma = log((rig.truth(.gray(0.5)).Y - black) / (white.Y - black)) / log(0.5)
        #expect(abs(gamma - 2.3) < 0.06, "gamma \(gamma)")
        // S-shape: brighter than the power law at 25 %, darker at 75 %.
        func relative(_ s: Double) -> Double { (rig.truth(.gray(s)).Y - black) / (white.Y - black) / pow(s, 2.3) }
        #expect(relative(0.25) > 1.02)
        #expect(relative(0.75) < 0.99)
        // Blue low-end tint: near-black is bluer (lower x and y) than white.
        let nearBlack = rig.truth(.gray(0.05)).chromaticity
        #expect(nearBlack.x < white.chromaticity.x - 0.002 && nearBlack.y < white.chromaticity.y - 0.002)
    }

    @Test func gameModeDiffersFromExpertDark() async throws {
        let rig = Rig()
        try await rig.connect()
        func profile() -> (white: Chromaticity, ratios: [Double]) {
            let white = rig.truth(.white)
            return (white.chromaticity, (1...19).map { rig.truth(.gray(Double($0) / 20)).Y / white.Y })
        }
        let expert = profile()
        try await rig.tv.setPictureMode("game")
        let game = profile()
        #expect(game.white.distance(to: Chromaticity(x: 0.3085, y: 0.3300)) < 0.0005)
        #expect(expert.white.distance(to: game.white) > 0.005)
        let largest = zip(expert.ratios, game.ratios).map { abs($0 / $1 - 1) }.max()!
        #expect(largest > 0.03, "grayscale shapes should differ, got \(largest)")
    }

    @Test func ablLimitsFullFieldAndSettles() async throws {
        let rig = Rig()
        try await rig.connect()
        try await rig.tv.writePictureSettings([PictureKey.backlight: .number(100)])
        _ = try await rig.source.show(.patch(.white, format: .sdr))
        try await rig.clock.sleep(for: .seconds(5))
        let window = rig.panel.displayedXYZ().Y
        #expect(abs(window - 420) < 2)

        _ = try await rig.source.show(PatternSpec(content: .fullField(.white), format: .sdr))
        try await rig.clock.sleep(for: .milliseconds(100))
        let early = rig.panel.displayedXYZ().Y
        try await rig.clock.sleep(for: .seconds(5))
        let settled = rig.panel.displayedXYZ().Y
        #expect(abs(settled - 160) < 1, "full field \(settled)")
        #expect(early > 300, "ABL engages over ~0.8 s, got \(early) after 0.1 s")

        // Settling after a big step: τ = 0.15 s.
        _ = try await rig.source.show(.patch(.white, format: .sdr))
        try await rig.clock.sleep(for: .seconds(5))
        _ = try await rig.source.show(.patch(.gray(0.5), format: .sdr))
        let target = rig.truth(.gray(0.5)).Y
        try await rig.clock.sleep(for: .milliseconds(150))
        let afterTau = rig.panel.displayedXYZ().Y
        #expect(abs((afterTau - target) / (420 - target) - exp(-1)) < 0.01)
        try await rig.clock.sleep(for: .milliseconds(1350))
        #expect(abs(rig.panel.displayedXYZ().Y / target - 1) < 0.001)
    }

    @Test func meterNoiseFloorAndIntegration() async throws {
        let rig = Rig()
        try await rig.connect()
        _ = try await rig.source.show(.black(format: .sdr))
        try await rig.clock.sleep(for: .seconds(2))
        let start = rig.clock.now
        let dark = try await rig.meter.measure(expectedLuminance: nil)
        #expect(dark.flags.contains("belowFloor"))
        #expect(dark.integrationTime == 4)
        #expect(rig.clock.now.timeIntervalSince(start) >= 4)
        _ = try await rig.source.show(.patch(.white, format: .sdr))
        try await rig.clock.sleep(for: .seconds(1))
        let bright = try await rig.meter.measure(expectedLuminance: nil)
        #expect(bright.flags.isEmpty && bright.integrationTime == 0.2)
        #expect(abs(bright.luminance / rig.truth(.white).Y - 1) < 0.02)
        #expect(await rig.meter.info.maximumLuminance == 10_000)
    }

    @Test func controllerValidatesSettingsAndUploads() async throws {
        let rig = Rig()
        try await rig.connect()
        await #expect(throws: CalibrationError.self) { try await rig.tv.writePictureSettings([PictureKey.contrast: .number(101)]) }
        await #expect(throws: CalibrationError.self) { try await rig.tv.writePictureSettings(["whiteBalanceRedGain": .number(51)]) }
        await #expect(throws: CalibrationError.self) { try await rig.tv.writePictureSettings([PictureKey.gamma: .string("2.4")]) }
        await #expect(throws: CalibrationError.self) { try await rig.tv.writePictureSettings(["sharpnessX": .number(1)]) }
        try await rig.tv.writePictureSettings([PictureKey.gamma: .string("high2"), PictureKey.colorTemperature: .string("cool10")])
        // Uploads need CAL_START; Game Optimizer refuses them; HDR modes need the HDR10 signal path.
        let lut = LUT1D.identity()
        await #expect(throws: CalibrationError.self) { try await rig.tv.sendCalibration(.upload1DLUT(lut, pictureMode: "expert1")) }
        try await rig.tv.sendCalibration(.start(pictureMode: "game"))
        await #expect(throws: CalibrationError.refused("game (Game Optimizer) refuses calibration uploads")) {
            try await rig.tv.sendCalibration(.upload1DLUT(lut, pictureMode: "game"))
        }
        try await rig.tv.sendCalibration(.end(pictureMode: "game"))
        await #expect(throws: CalibrationError.self) { try await rig.tv.setPictureMode("hdr_cinema") }
        // Faults.
        rig.tv.failNextCommand(CalibrationError.deviceFailure("boom"))
        await #expect(throws: CalibrationError.deviceFailure("boom")) { try await rig.tv.setPictureMode("expert2") }
        rig.tv.disconnectAfter(2)
        try await rig.tv.setPictureMode("expert2")
        await #expect(throws: CalibrationError.notConnected("TV")) { try await rig.tv.setPictureMode("expert1") }
        await #expect(throws: CalibrationError.notConnected("TV")) { try await rig.tv.setPictureMode("expert1") }
        try await rig.tv.connect()
        try await rig.tv.setPictureMode("expert1")
    }

    @Test func patternSourceModeSwitching() async throws {
        let rig = Rig()
        try await rig.connect()
        let start = rig.clock.now
        let state = try await rig.source.setDisplayMode(DisplayModeRequest(dynamicRange: .hdr10))
        #expect(state.matchingEnabled && rig.panel.signalPath == .hdr10 && rig.panel.pictureMode == "hdr_cinema")
        #expect(rig.clock.now.timeIntervalSince(start) == 2)
        rig.source.matchingEnabled = false
        let refused = try await rig.source.setDisplayMode(DisplayModeRequest(dynamicRange: .sdr))
        #expect(!refused.matchingEnabled && rig.panel.signalPath == .hdr10)
        let ack = try await rig.source.show(.patch(.gray(0.5), format: .hdr10))
        #expect(ack.centerCodes == [502, 502, 502])
    }
}
