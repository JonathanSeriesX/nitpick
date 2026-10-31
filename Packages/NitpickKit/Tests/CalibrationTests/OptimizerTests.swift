import ColorScience
import Foundation
import PatternLink
import Testing

@testable import Calibration

@Suite struct OptimizerTests {
    /// Gains at 80 % on expert1 through the real TV/meter path.
    func gainRun(_ rig: Rig, start: [Int], target: Chromaticity = .d65, tolerance: Double = 0.5) async throws
        -> WhiteBalanceOptimizer.Result
    {
        let ctx = rig.context(.sdrMovie, mode: "expert1")
        var current = [0, 0, 0]
        try await ctx.write(keys: PictureKey.gains, values: start, previous: current)
        current = start
        return try await WhiteBalanceOptimizer(tolerance: tolerance).optimize(
            start: start, target: target, targetLuminance: nil, deltaE: ctx.deltaE,
            apply: { new in
                try await ctx.write(keys: PictureKey.gains, values: new, previous: current)
                current = new
            },
            measure: { try await ctx.measureGray(0.8) })
    }

    @Test func convergesFromLargeError() async throws {
        let rig = Rig(seed: 7)
        try await rig.connect()
        let r = try await gainRun(rig, start: [35, 0, -35])
        print("WB converge:", r.initialDeltaE, "→", r.deltaE, r.iterations, r.stopReason, r.controls)
        #expect(r.initialDeltaE > 5)
        #expect(r.iterations <= 6)
        #expect(r.deltaE < 0.5)
        // Noise-free check of the final state.
        let truth = rig.truth(.gray(0.8))
        let error = Metrics.deltaE(truth, Chromaticity.d65.xyz(Y: truth.Y), target: .sdrMovie)
        #expect(error < 0.6, "true ΔE \(error)")
        #expect(!r.limitedByBounds)
    }

    @Test func unreachableTargetReportsBounds() async throws {
        let rig = Rig(seed: 8)
        try await rig.connect()
        let r = try await gainRun(rig, start: [0, 0, 0], target: Chromaticity(x: 0.36, y: 0.33))
        print("WB bounds:", r.initialDeltaE, "→", r.deltaE, r.stopReason, r.controls)
        #expect(r.limitedByBounds)
        #expect(r.controls.allSatisfy { (-50...50).contains($0) })
        #expect(r.deltaE < r.initialDeltaE)
    }

    @Test func doesNotDivergeUnderNoise() async throws {
        let rig = Rig(seed: 9)
        try await rig.connect()
        rig.meter.noiseScale = 4
        let r = try await gainRun(rig, start: [20, 0, -20])
        print("WB noisy:", r.initialDeltaE, "→", r.deltaE, r.stopReason, r.controls)
        let truth = rig.truth(.gray(0.8))
        let error = Metrics.deltaE(truth, Chromaticity.d65.xyz(Y: truth.Y), target: .sdrMovie)
        #expect(error < r.initialDeltaE)
        #expect(error < 1.5)
    }
}
