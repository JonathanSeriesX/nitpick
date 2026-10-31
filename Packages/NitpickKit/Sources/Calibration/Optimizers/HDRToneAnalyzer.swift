import Foundation
import ColorScience

/// How an HDR10 grayscale run tracks PQ and where the TV starts tone mapping.
public struct HDRToneReport: Codable, Hashable, Sendable {
    public enum Region: String, Codable, Sendable { case tracking, rollOff, clipped }

    public struct Point: Codable, Hashable, Sendable {
        public var stimulus: Double
        /// PQ luminance of the stimulus, cd/m².
        public var reference: Double
        public var measured: Double
        public var region: Region
        public var deltaEITP: Double
    }

    public var points: [Point]
    /// Median of the readings within 2 % of the brightest one, cd/m².
    public var peakLuminance: Double
    /// Reference luminance where measured / reference first drops below the knee ratio (interpolated), cd/m².
    public var kneeLuminance: Double
    /// True when tracking continues to ≥ 95 % of the peak (HGiG-style hard clip).
    public var isHardClip: Bool
    /// Mean |measured / reference − 1| × 100 over tracking points ≥ 1 cd/m².
    public var trackingErrorPercent: Double
    /// ΔE ITP over tracking points at ≥ 5 % stimulus.
    public var maxDeltaEITPBelowKnee: Double
    public var averageDeltaEITPBelowKnee: Double
    /// Suggested LG tonemap parameters: measured peak rounded to 10, MaxMDL, knee as % of peak (50…100).
    public var proposed: ToneMapParameters
}

public struct HDRToneAnalyzer: Sendable {
    public var kneeRatio = 0.97

    public init(kneeRatio: Double = 0.97) { self.kneeRatio = kneeRatio }

    /// Standard HDR grayscale plus 1 % steps from 50 to 85 % PQ, where knees and clips sit on consumer TVs.
    public static let stimuli: [Double] = Array(Set(Stimuli.grayscale(.hdr10) + (50...85).map { Double($0) / 100 })).sorted()

    public func analyze(_ readings: [(stimulus: Double, xyz: XYZ)], metadata: HDR10StaticMetadata?, whitePoint: Chromaticity = .d65) -> HDRToneReport {
        let sorted = readings.sorted { $0.stimulus < $1.stimulus }
        let top = sorted.map(\.xyz.Y).max() ?? 0
        let plateau = sorted.map(\.xyz.Y).filter { $0 >= 0.98 * top }.sorted()
        let peak = plateau.isEmpty ? top : plateau[plateau.count / 2]

        var knee = peak
        var previous: (ref: Double, ratio: Double)?
        for p in sorted {
            let ref = PQ.eotf(p.stimulus)
            guard ref >= 10 else { continue }
            let ratio = p.xyz.Y / ref
            if ratio < kneeRatio {
                if let prev = previous, prev.ratio > ratio {
                    knee = prev.ref + (prev.ratio - kneeRatio) / (prev.ratio - ratio) * (ref - prev.ref)
                } else {
                    knee = ref
                }
                break
            }
            previous = (ref, ratio)
        }

        let points = sorted.map { p -> HDRToneReport.Point in
            let ref = PQ.eotf(p.stimulus)
            let region: HDRToneReport.Region = ref <= knee ? .tracking : (p.xyz.Y >= 0.98 * peak && ref > peak ? .clipped : .rollOff)
            return HDRToneReport.Point(stimulus: p.stimulus, reference: ref, measured: p.xyz.Y, region: region,
                                       deltaEITP: CIE.deltaEITP(CIE.ictcp(p.xyz), CIE.ictcp(whitePoint.xyz(Y: ref))))
        }
        let tracking = points.filter { $0.region == .tracking }
        let tracked = tracking.filter { $0.reference >= 1 }.map { abs($0.measured / $0.reference - 1) * 100 }
        let itp = tracking.filter { $0.stimulus >= 0.049 }.map(\.deltaEITP)
        let mastering = Int(metadata?.maxMasteringLuminance ?? 1000)
        return HDRToneReport(
            points: points, peakLuminance: peak, kneeLuminance: knee, isHardClip: knee >= 0.95 * peak,
            trackingErrorPercent: tracked.isEmpty ? 0 : tracked.reduce(0, +) / Double(tracked.count),
            maxDeltaEITPBelowKnee: itp.max() ?? 0, averageDeltaEITPBelowKnee: itp.isEmpty ? 0 : itp.reduce(0, +) / Double(itp.count),
            proposed: ToneMapParameters(displayLuminance: Int((peak / 10).rounded()) * 10, masteringPeak: mastering,
                                        rolloffPoint: min(100, max(50, Int((knee / max(peak, 1) * 100).rounded())))))
    }
}

/// Derives the Dolby Vision display configuration from an HDR10 measurement set of the same panel.
///
/// Uses the BT.2020 container primaries at 100 % saturation (they clip to the panel's native primaries), the white of
/// the brightest grayscale point that still tracks, the measured peak and black. Gamma defaults to 2.2, following the
/// common Calman practice for LG panels — an assumption to verify on real hardware. Sanity bounds: peak 300…4000,
/// black 0…0.05 cd/m².
public struct DolbyVisionConfigBuilder: Sendable {
    public var gamma = 2.2

    public init(gamma: Double = 2.2) { self.gamma = gamma }

    public func build(from set: MeasurementSet, sdrGamma: Double? = nil) throws -> (config: DolbyVisionConfig, warnings: [String]) {
        func primary(_ name: String) throws -> Chromaticity {
            guard let p = set.primariesSecondaries.first(where: { $0.name == "\(name) 100%" }) else {
                throw CalibrationError.precondition("The HDR10 measurements lack the 100 % \(name.lowercased()) primary")
            }
            return p.error.measured.chromaticity
        }
        var warnings: [String] = []
        let peak = set.peakLuminance.clamped(300, 4000)
        if peak != set.peakLuminance { warnings.append(String(format: "Measured peak %.0f cd/m² clamped to %.0f", set.peakLuminance, peak)) }
        let black = set.blackLevel.clamped(0, 0.05)
        if black != set.blackLevel { warnings.append(String(format: "Measured black %.4f cd/m² clamped to %.4f", set.blackLevel, black)) }
        let white = set.grayscale.filter { !$0.error.inRollOff && $0.stimulus >= 0.049 }.max { $0.reading.luminance < $1.reading.luminance }?
            .reading.chromaticity ?? .d65
        let config = DolbyVisionConfig(whiteLevel: peak, blackLevel: black, gamma: (sdrGamma ?? gamma).clamped(2.0, 2.6),
                                       red: try primary("Red"), green: try primary("Green"), blue: try primary("Blue"), white: white)
        return (config, warnings)
    }
}
