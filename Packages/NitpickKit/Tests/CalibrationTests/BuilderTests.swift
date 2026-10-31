import Foundation
import Testing
import ColorScience
import PatternLink
@testable import Calibration

@Suite struct BuilderTests {
    @Test func cubeInvertsSyntheticDeviceQuickly() throws {
        // A P3 display with mismatched channel gammas and a 0.02 cd/m² black.
        let device = ColorSpacePrimaries.dciP3D65
        func show(_ v: SignalRGB) -> XYZ {
            device.xyz(fromLinear: RGB(r: pow(max(v.r, 0), 2.2), g: pow(max(v.g, 0), 2.35), b: pow(max(v.b, 0), 2.5)) * 100)
                + Chromaticity.d65.xyz(Y: 0.02)
        }
        let target = CalibrationTarget.sdrMovie.withBlackLevel(0.02)
        let builder = CubeLUTBuilder(size: 33, gridLevels: 9)
        let grid = builder.gridSignals().map(show)
        let start = ContinuousClock.now
        let (lut, report) = try builder.build(measurements: grid, target: target, lut1D: nil)
        let elapsed = ContinuousClock.now - start
        print("33³ cube build:", elapsed, report)
        #expect(elapsed < .seconds(2))
        #expect(lut.size == 33)
        var random = SeededRandom(seed: 42)
        let errors = (0..<300).map { _ -> Double in
            let v = SignalRGB(r: random.uniform(), g: random.uniform(), b: random.uniform())
            return Metrics.deltaE(show(SignalRGB(lut.apply(v.rgb))), target.reference(v), target: target)
        }
        print("cube inversion ΔE2000 mean", errors.reduce(0, +) / 300, "max", errors.max()!)
        #expect(errors.reduce(0, +) / 300 < 0.3)
        #expect(errors.max()! < 1.0)
    }

    @Test func grayscaleLUTReachesTargetOnPanel() async throws {
        let rig = Rig(seed: 20)
        try await rig.connect()
        var ctx = rig.context(.sdrMovie, mode: "expert1")
        ctx.measurer.settings.minReads = 3
        var gray: [(stimulus: Double, xyz: XYZ)] = []
        for s in Stimuli.grayscale(.sdr) { gray.append((ctx.target.quantizedGray(s), try await ctx.measureGray(s).xyz)) }
        var primaries: [XYZ] = []
        for signal in [SignalRGB(r: 1, g: 0, b: 0), SignalRGB(r: 0, g: 1, b: 0), SignalRGB(r: 0, g: 0, b: 1)] {
            primaries.append(try await ctx.measure(signal, reference: nil).xyz)
        }
        let (lut, report) = try GrayscaleLUTBuilder().build(grayscale: gray, primaries: (primaries[0], primaries[1], primaries[2]), target: ctx.target)
        #expect(lut.size == 1024)
        for c in 0..<3 {
            let table = lut.channel(c)
            #expect(zip(table, table.dropFirst()).allSatisfy { $0 <= $1 }, "channel \(c) not monotonic")
        }
        #expect(report.clippedRange == nil && report.pointsUsed == 21)
        try await ctx.upload(.upload1DLUT(lut, pictureMode: "expert1"), "1D LUT expert1")
        for s in stride(from: 0.1, through: 1.0, by: 0.05) {
            let truth = rig.truth(.gray(s)), reference = ctx.target.reference(.gray(s))
            #expect(abs(truth.Y / reference.Y - 1) < 0.01, "\(Int(s * 100)) %: \(truth.Y) vs \(reference.Y)")
            #expect(truth.chromaticity.distance(to: .d65) < 0.003, "\(Int(s * 100)) %: \(truth.chromaticity)")
        }
    }

    @Test func toneAnalyzerFindsKneeAndClip() {
        // Synthetic readings: track PQ to a 600-nit knee then roll off to 750 (movie) vs. hard clip at 750 (HGiG).
        let stimuli = HDRToneAnalyzer.stimuli
        func readings(_ curve: (Double) -> Double) -> [(stimulus: Double, xyz: XYZ)] {
            stimuli.map { ($0, Chromaticity.d65.xyz(Y: curve(PQ.eotf($0)))) }
        }
        let roll = HDRToneAnalyzer().analyze(readings { ToneCurve.rollOff($0, knee: 450, peak: 750, source: 1000) }, metadata: .p3D65_1000)
        let clip = HDRToneAnalyzer().analyze(readings { min($0, 750) }, metadata: .p3D65_1000)
        #expect(abs(roll.peakLuminance - 750) < 1 && abs(clip.peakLuminance - 750) < 1)
        #expect(!roll.isHardClip && clip.isHardClip)
        #expect(roll.kneeLuminance > 450 && roll.kneeLuminance < 650)
        #expect(roll.proposed.displayLuminance == 750 && roll.proposed.masteringPeak == 1000)
        #expect(roll.points.contains { $0.region == .rollOff } && clip.points.contains { $0.region == .clipped })
        #expect(roll.points.filter { $0.reference < 450 }.allSatisfy { $0.deltaEITP < 0.01 && $0.region == .tracking })
        #expect(roll.maxDeltaEITPBelowKnee < 3, "only the gentle start of the roll-off may count as tracking")
    }

    @Test func dolbyConfigBuilderAppliesBounds() throws {
        let target = CalibrationTarget.hdr10Movie
        func patch(_ name: String, _ c: Chromaticity) -> ColorPatchResult {
            ColorPatchResult(name: name, signal: .black, error: Metrics.error(measured: c.xyz(Y: 20), reference: c.xyz(Y: 20), target: target))
        }
        let set = MeasurementSet(dynamicRange: .hdr10, primariesSecondaries: [patch("Red 100%", .init(x: 0.676, y: 0.316)),
                                                                             patch("Green 100%", .init(x: 0.253, y: 0.700)),
                                                                             patch("Blue 100%", .init(x: 0.145, y: 0.052))],
                                 peakLuminance: 5000, blackLevel: 0.2)
        let (config, warnings) = try DolbyVisionConfigBuilder().build(from: set)
        #expect(config.whiteLevel == 4000 && config.blackLevel == 0.05 && config.gamma == 2.2)
        #expect(warnings.count == 2)
        #expect(config.red == Chromaticity(x: 0.676, y: 0.316))
        #expect(throws: CalibrationError.self) { try DolbyVisionConfigBuilder().build(from: MeasurementSet(dynamicRange: .hdr10)) }
    }
}
