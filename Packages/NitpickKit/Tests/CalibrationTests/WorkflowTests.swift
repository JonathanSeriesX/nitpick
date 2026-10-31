import ColorScience
import Foundation
import PatternLink
import Testing

@testable import Calibration

@Suite struct WorkflowTests {
    @Test func sdrMovieWithLUTs() async throws {
        let rig = Rig(seed: 11)
        let start = ContinuousClock.now
        let events = try await runWorkflow(WorkflowRunner(), .movieSDR, rig)
        let r = try #require(events.result, "\(events.failure ?? "no result")")
        print("SDR movie before:", describe(r.before))
        print("SDR movie after: ", describe(r.after))
        print("SDR movie verify:", describe(r.verification))
        print("SDR movie uploads:", r.lutsUploaded, "warnings:", r.warnings, "failures:", r.failures, "time:", ContinuousClock.now - start)
        #expect(r.before.summary.grayscaleMaxDeltaE > 3)
        #expect(r.after.summary.grayscaleMaxDeltaE <= 1.5)
        #expect(r.after.summary.grayscaleAverageDeltaE <= 0.8)
        let v = r.verification.verificationPatches.map(\.error.deltaE2000)
        #expect(Metrics.percentile(v, 95) <= 2.0)
        #expect(v.max()! <= 3.0)
        #expect(abs(r.after.summary.averageGamma! / 2.4 - 1) <= 0.03)
        #expect(r.after.summary.maxLuminanceErrorPercent <= 3)
        #expect(r.lutsUploaded.count == 2)
        #expect(rig.panel.calibration(for: "expert1").lut1D != nil)
        #expect(r.passed, "\(r.failures)")
    }

    /// With a noise-free meter the 1D + 3D LUT chain must land essentially on target: proves the algorithms, not luck.
    @Test func noiseFreeMovieCalibrationIsExact() async throws {
        let rig = Rig(seed: 11)
        rig.meter.noiseScale = 0
        let events = try await runWorkflow(WorkflowRunner(), .movieSDR, rig)
        try #require(events.result != nil)
        let target = SessionProfile.movieSDR.target
        let gray = stride(from: 0.1, through: 1.0, by: 0.05).map {
            Metrics.deltaE(rig.truth(.gray($0)), target.reference(.gray($0)), target: target)
        }
        let colors = Stimuli.verification(target).map { Metrics.deltaE(rig.truth($0.signal), target.reference($0.signal), target: target) }
        #expect(gray.max()! < 0.1, "\(gray)")
        #expect(colors.max()! < 0.2, "\(colors)")
    }
}

@Suite struct ModeWorkflowTests {
    static let wbKeys = PictureKey.gains + PictureKey.offsets + [PictureKey.twentyPoint, PictureKey.backlight, PictureKey.contrast]

    @Test func sdrGameUsesControlsOnly() async throws {
        let rig = Rig(seed: 12)
        try await runWorkflow(WorkflowRunner(), .movieSDR, rig)
        let movie = try await rig.tv.readPictureSettings(pictureMode: "expert1")
        let events = try await runWorkflow(WorkflowRunner(), .gameSDR, rig)
        let r = try #require(events.result, "\(events.failure ?? "no result")")
        print("SDR game before:", describe(r.before))
        print("SDR game after: ", describe(r.after))
        print("SDR game verify:", describe(r.verification), r.failures)
        #expect(r.before.summary.grayscaleMaxDeltaE > r.after.summary.grayscaleMaxDeltaE)
        #expect(r.after.summary.grayscaleMaxDeltaE <= 2.0)
        #expect(r.after.summary.grayscaleAverageDeltaE <= 1.0)
        #expect(r.after.summary.maxLuminanceErrorPercent <= 5)
        #expect(r.lutsUploaded.isEmpty)
        #expect(rig.panel.calibration(for: "game").isEmpty)
        #expect(!rig.tv.commandLog.contains { $0.hasPrefix("sendCalibration") && $0.hasSuffix(" game") })
        let game = try await rig.tv.readPictureSettings(pictureMode: "game")
        let differing = Self.wbKeys.filter { game.values[$0] != movie.values[$0] }
        #expect(differing.count >= 4, "game and movie controls should differ, only \(differing) do")
        #expect(r.adjustments.contains { $0.control.hasPrefix(PictureKey.twentyPoint) })
    }

    @Test func hdr10Movie() async throws {
        let rig = Rig(seed: 13)
        let events = try await runWorkflow(WorkflowRunner(), .movieHDR10, rig)
        let r = try #require(events.result, "\(events.failure ?? "no result")")
        let tone = try #require(r.toneAnalysis)
        print("HDR movie before:", describe(r.before))
        print("HDR movie after: ", describe(r.after))
        print("HDR movie verify:", describe(r.verification), r.failures)
        print("HDR tone:", tone.peakLuminance, tone.kneeLuminance, tone.isHardClip, tone.proposed, r.lutsUploaded)
        #expect(abs(tone.peakLuminance / SimulatedPanel.hdrPeakLuminance - 1) < 0.05)
        #expect(!tone.isHardClip)
        #expect(r.lutsUploaded == ["tonemap hdr_cinema"])
        #expect(rig.panel.calibration(for: "hdr_cinema").toneMap == tone.proposed)
        let judged = r.after.grayscale.filter { $0.stimulus >= 0.05 && !$0.error.inRollOff }
        let before = r.before.grayscale.filter { $0.stimulus >= 0.05 && !$0.error.inRollOff }
        #expect(before.map(\.error.deltaEITP).max()! > 3)
        #expect(judged.map(\.error.deltaEITP).max()! <= 3)
        // Roll-off points are reported (with a modelled reference) but never judged.
        let rollOff = r.after.grayscale.filter(\.error.inRollOff)
        #expect(rollOff.count >= 6)
        #expect(r.after.summary.grayscaleMaxDeltaE == judged.map(\.error.deltaEITP).max()!)
        // P3 red lies outside the panel's native gamut: reported against the clipped reference, not judged.
        let red = try #require(r.after.saturationSweeps.first { $0.name == "Red 100% sat" })
        #expect(red.error.outOfGamut)
        #expect(SimulatedPanel.nativePrimaries.contains(red.error.reference.chromaticity))
        #expect(r.after.saturationSweeps.filter(\.error.outOfGamut).count < 6, "only the panel's gamut corners are excused")
        #expect(r.passed, "\(r.failures)")
    }

    @Test func hdr10GameHGiG() async throws {
        let rig = Rig(seed: 14)
        let events = try await runWorkflow(WorkflowRunner(), .gameHDR10, rig)
        let r = try #require(events.result, "\(events.failure ?? "no result")")
        let tone = try #require(r.toneAnalysis)
        print("HDR game before:", describe(r.before))
        print("HDR game after: ", describe(r.after))
        print("HDR game tone:", tone.peakLuminance, tone.kneeLuminance, tone.isHardClip, r.failures)
        #expect(tone.isHardClip)
        #expect(r.lutsUploaded.isEmpty)
        #expect(rig.panel.calibration(for: "hdr_game").isEmpty)
        #expect(r.after.summary.grayscaleMaxDeltaE < r.before.summary.grayscaleMaxDeltaE)
        #expect(r.after.summary.grayscaleMaxDeltaE <= 3)
        #expect(r.after.saturationSweeps.contains { $0.error.outOfGamut })
        #expect(r.passed, "\(r.failures)")
    }

    @Test func dolbyVisionFromHDR10Session() async throws {
        let rig = Rig(seed: 15)
        let store = try SessionStore(directory: temporaryDirectory())
        let runner = WorkflowRunner(store: store)
        let hdr = CalibrationSession(profile: .movieHDR10)
        try #require(try await runWorkflow(runner, .movieHDR10, rig, session: hdr).result != nil)

        let dv = SessionProfile.dolbyVision(source: hdr.id)
        let events = try await runWorkflow(runner, dv, rig) { event in
            if case .needsUser = event {
                try rig.source.simulateUserSelectsOutput(.dolbyVision)
                runner.confirmUser()
            }
        }
        let r = try #require(events.result, "\(events.failure ?? "no result")")
        let session = try #require(await runner.session)
        let config = try #require(session.dolbyConfig)
        print("DV config:", config)
        print("DV before:", describe(r.before))
        print("DV after: ", describe(r.after))
        print("DV verify:", describe(r.verification), r.failures)
        let native = SimulatedPanel.nativePrimaries
        #expect(config.red.distance(to: native.red) < 0.003)
        #expect(config.green.distance(to: native.green) < 0.003)
        #expect(config.blue.distance(to: native.blue) < 0.003)
        #expect(r.lutsUploaded == ["Dolby Vision config dolby_cinema_dark"])
        let before = r.before.verificationPatches.map(\.error.deltaEITP)
        let after = r.verification.verificationPatches.map(\.error.deltaEITP)
        #expect(after.reduce(0, +) < before.reduce(0, +) / 2)
        #expect(after.max()! < before.max()!)
    }

    @Test func dolbyVisionRefusesWithoutSource() async throws {
        let rig = Rig(seed: 16)
        let runner = WorkflowRunner(store: try SessionStore(directory: temporaryDirectory()))
        let events = try await runWorkflow(runner, .dolbyVision(source: nil), rig)
        let failure = try #require(events.failure)
        #expect(failure.contains("HDR10 movie session"))
        #expect(await runner.session?.status == .failed)
        #expect(rig.panel.calibration(for: "dolby_cinema_dark").isEmpty)
    }
}
