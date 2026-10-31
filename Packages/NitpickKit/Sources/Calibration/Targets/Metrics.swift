import ColorScience
import Foundation

/// Difference between a measured and a reference colour. All XYZ absolute (cd/m²).
public struct ColorError: Codable, Hashable, Sendable {
    public enum Flag: String, Codable, Hashable, Sendable {
        /// HDR grayscale above the expected roll-off knee: reported against a modelled reference, never judged.
        case inRollOff
        /// Colour target outside the display's measured native gamut: reported against the gamut-clipped reference
        /// (`Metrics.gamutClipped`), never judged.
        case outOfGamut
    }

    /// CIEDE2000 relative to `CalibrationTarget.referenceWhite`.
    public var deltaE2000: Double
    /// BT.2124 ΔE ITP on absolute values.
    public var deltaEITP: Double
    /// Δu′v′.
    public var deltaUV: Double
    /// (Y_measured − Y_reference) / Y_reference × 100; 0 when the reference is black.
    public var luminanceErrorPercent: Double
    public var measured: XYZ
    public var reference: XYZ
    public var flags: Set<Flag>

    public var inRollOff: Bool { flags.contains(.inRollOff) }
    public var outOfGamut: Bool { flags.contains(.outOfGamut) }

    /// The judged metric: ΔE ITP for HDR targets, ΔE2000 for SDR.
    public func value(hdr: Bool) -> Double { hdr ? deltaEITP : deltaE2000 }
}

public enum Metrics {
    public static func error(measured: XYZ, reference: XYZ, target: CalibrationTarget, flags: Set<ColorError.Flag> = []) -> ColorError {
        let white = target.referenceWhite
        return ColorError(
            deltaE2000: CIE.deltaE2000(CIE.lab(measured, white: white), CIE.lab(reference, white: white)),
            deltaEITP: CIE.deltaEITP(CIE.ictcp(measured), CIE.ictcp(reference)),
            deltaUV: CIE.deltaUV(measured.chromaticity, reference.chromaticity),
            luminanceErrorPercent: reference.Y > 0 ? (measured.Y - reference.Y) / reference.Y * 100 : 0,
            measured: measured, reference: reference, flags: flags)
    }

    /// The judged ΔE between two absolute XYZ for `target` (ΔE ITP for HDR, ΔE2000 for SDR).
    public static func deltaE(_ measured: XYZ, _ reference: XYZ, target: CalibrationTarget) -> Double {
        if target.isHDR { return CIE.deltaEITP(CIE.ictcp(measured), CIE.ictcp(reference)) }
        let white = target.referenceWhite
        return CIE.deltaE2000(CIE.lab(measured, white: white), CIE.lab(reference, white: white))
    }

    /// Expected HDR grey for PQ stimulus `s` on a display with measured peak `displayPeak`.
    ///
    /// Hard clip (HGiG): PQ up to the peak, then the peak; points above the peak are flagged.
    /// Roll-off: PQ up to a knee at 70 % of the peak, then `ToneCurve.rollOff` mapping max(1000, MaxMDL) to the peak;
    /// points above the knee are flagged. This is a simple model of "what a well-behaved TV does", not the TV's curve.
    public static func hdrGrayReference(stimulus s: Double, target: CalibrationTarget, displayPeak: Double) -> (xyz: XYZ, inRollOff: Bool) {
        let L = PQ.eotf(s)
        switch target.hdrMapping {
        case .hardClip:
            return (target.whitePoint.xyz(Y: min(L, displayPeak)), L > displayPeak)
        case .rollOff:
            let knee = 0.7 * displayPeak
            let source = max(1000, target.hdr10Metadata?.maxMasteringLuminance ?? 1000)
            return (target.whitePoint.xyz(Y: ToneCurve.rollOff(L, knee: knee, peak: displayPeak, source: source)), L > knee)
        }
    }

    /// `reference` desaturated at constant luminance onto the edge of the `gamut` triangle, along the xy line toward
    /// `gamut.white` (mixing with the equal-luminance white moves along that line). Nil when the reference is inside the
    /// triangle, black, or `gamut.white` is not inside it.
    public static func gamutClipped(_ reference: XYZ, gamut: ColorSpacePrimaries) -> XYZ? {
        let c = reference.chromaticity
        let w = gamut.white
        guard reference.Y > 0, !gamut.contains(c), gamut.contains(w) else { return nil }
        func cross(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double) -> Double { ax * by - ay * bx }
        let dx = c.x - w.x
        let dy = c.y - w.y
        var exit: Double?
        for (a, b) in [(gamut.red, gamut.green), (gamut.green, gamut.blue), (gamut.blue, gamut.red)] {
            let ex = b.x - a.x
            let ey = b.y - a.y
            let denominator = cross(dx, dy, ex, ey)
            guard denominator != 0 else { continue }
            let t = cross(a.x - w.x, a.y - w.y, ex, ey) / denominator
            let s = cross(a.x - w.x, a.y - w.y, dx, dy) / denominator
            if (0...1).contains(s), t >= 0, t < exit ?? .infinity { exit = t }
        }
        guard let t = exit else { return nil }
        return Chromaticity(x: w.x + t * dx, y: w.y + t * dy).xyz(Y: reference.Y)
    }

    /// The display's native gamut: the measured 100 % container primaries ("Red 100%", …) with the target white.
    /// HDR only: the BT.2020 container primaries drive the panel to its limits, while SDR container primaries are the
    /// target itself and cannot tell a narrow panel from a miscalibrated one. Nil when they were not measured.
    static func nativeGamut(_ patches: [(name: String, xyz: XYZ)], target: CalibrationTarget) -> ColorSpacePrimaries? {
        guard target.isHDR else { return nil }
        func xy(_ name: String) -> Chromaticity? { patches.first { $0.name == "\(name) 100%" }?.xyz.chromaticity }
        guard let red = xy("Red"), let green = xy("Green"), let blue = xy("Blue") else { return nil }
        return ColorSpacePrimaries(red: red, green: green, blue: blue, white: target.whitePoint)
    }

    /// Nearest-rank percentile (p in 0…100) of `values`; 0 for an empty list.
    public static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }
}

/// One grayscale measurement. `stimulus` is the normalised signal (0…1) as quantised to the pattern format.
public struct GrayscalePoint: Codable, Hashable, Sendable {
    public var stimulus: Double
    public var reading: MeterReading
    public var error: ColorError
    public var cct: Double
    /// Point gamma log(Y_rel)/log(stimulus) with Y_rel = (Y − black)/(peak − black); SDR only, 0 < stimulus < 1.
    public var gamma: Double?
}

public struct ColorPatchResult: Codable, Hashable, Sendable {
    public var name: String
    public var signal: SignalRGB
    public var error: ColorError
}

/// Every metric of a measurement run. Judged values use ΔE ITP for HDR and ΔE2000 for SDR.
public struct Summary: Codable, Hashable, Sendable {
    /// Colour patches (SDR: primaries/secondaries, sweeps, verification; HDR: sweeps, verification — HDR primaries are
    /// BT.2020 container limits, reported only). Patches flagged `.outOfGamut` are excluded.
    public var averageDeltaE: Double
    public var maxDeltaE: Double
    public var p95DeltaE: Double
    /// Grayscale points ≥ 5 % stimulus that are not in roll-off (lower points are dominated by meter noise).
    public var grayscaleAverageDeltaE: Double
    public var grayscaleMaxDeltaE: Double
    /// SDR: mean point gamma over 10–90 %.
    public var averageGamma: Double?
    /// Mean |luminance error| % over judged grayscale points ≥ 10 %.
    public var eotfTrackingErrorPercent: Double
    public var maxLuminanceErrorPercent: Double
    /// Peak / black; nil when black is below the meter floor.
    public var contrastRatio: Double?
    public var whitePointCCT: Double
}

public struct MeasurementSet: Codable, Hashable, Sendable {
    public var dynamicRange: DynamicRange
    public var grayscale: [GrayscalePoint]
    public var primariesSecondaries: [ColorPatchResult]
    public var saturationSweeps: [ColorPatchResult]
    public var verificationPatches: [ColorPatchResult]
    public var nearBlack: [GrayscalePoint]
    /// cd/m², brightest grayscale reading.
    public var peakLuminance: Double
    /// cd/m², 0 % reading (0 when below the meter floor).
    public var blackLevel: Double
    public var summary: Summary

    public init(
        dynamicRange: DynamicRange, grayscale: [GrayscalePoint] = [], primariesSecondaries: [ColorPatchResult] = [],
        saturationSweeps: [ColorPatchResult] = [], verificationPatches: [ColorPatchResult] = [], nearBlack: [GrayscalePoint] = [],
        peakLuminance: Double = 0, blackLevel: Double = 0
    ) {
        self.dynamicRange = dynamicRange
        self.grayscale = grayscale
        self.primariesSecondaries = primariesSecondaries
        self.saturationSweeps = saturationSweeps
        self.verificationPatches = verificationPatches
        self.nearBlack = nearBlack
        self.peakLuminance = peakLuminance
        self.blackLevel = blackLevel
        let hdr = dynamicRange != .sdr
        let judgedGray = grayscale.filter { $0.stimulus >= 0.049 && !$0.error.inRollOff }
        let grayDE = judgedGray.map { $0.error.value(hdr: hdr) }
        let tracked = judgedGray.filter { $0.stimulus >= 0.099 }.map { abs($0.error.luminanceErrorPercent) }
        let colors = ((hdr ? [] : primariesSecondaries) + saturationSweeps + verificationPatches).filter { !$0.error.outOfGamut }
        let colorDE = colors.map { $0.error.value(hdr: hdr) }
        let gammas = grayscale.filter { (0.099...0.901).contains($0.stimulus) }.compactMap(\.gamma)
        let white = judgedGray.max { $0.reading.luminance < $1.reading.luminance }
        summary = Summary(
            averageDeltaE: colorDE.isEmpty ? 0 : colorDE.reduce(0, +) / Double(colorDE.count),
            maxDeltaE: colorDE.max() ?? 0, p95DeltaE: Metrics.percentile(colorDE, 95),
            grayscaleAverageDeltaE: grayDE.isEmpty ? 0 : grayDE.reduce(0, +) / Double(grayDE.count),
            grayscaleMaxDeltaE: grayDE.max() ?? 0,
            averageGamma: hdr || gammas.isEmpty ? nil : gammas.reduce(0, +) / Double(gammas.count),
            eotfTrackingErrorPercent: tracked.isEmpty ? 0 : tracked.reduce(0, +) / Double(tracked.count),
            maxLuminanceErrorPercent: tracked.max() ?? 0,
            contrastRatio: blackLevel > 0 ? peakLuminance / blackLevel : nil,
            whitePointCCT: white?.cct ?? 0)
    }
}

extension MeasurementSet {
    /// The native gamut from this set's measured primaries (see `Metrics.nativeGamut`); nil for SDR or when unmeasured.
    public func nativeGamut(for target: CalibrationTarget) -> ColorSpacePrimaries? {
        Metrics.nativeGamut(primariesSecondaries.map { ($0.name, $0.error.measured) }, target: target)
    }
}

/// Pass/fail thresholds. Every criterion is checked; nothing passes on an average alone.
public struct Tolerances: Codable, Hashable, Sendable {
    public var grayscaleMax = 2.0
    public var grayscaleAverage = 1.0
    public var colorMax = 3.0
    public var colorP95 = 2.5
    /// SDR grayscale luminance error, %.
    public var luminanceErrorPercent = 5.0
    public var hdrGrayscaleMaxITP = 3.0
    public var hdrColorMaxITP = 5.0

    public init() {}

    /// The criteria `set` fails (empty = pass). Sections that were not measured are skipped.
    public func failures(_ set: MeasurementSet) -> [String] {
        let s = set.summary
        var out: [String] = []
        func check(_ value: Double, _ limit: Double, _ name: String) {
            if value > limit { out.append(String(format: "%@ %.2f > %.2f", name, value, limit)) }
        }
        let hasColors =
            !set.saturationSweeps.isEmpty || !set.verificationPatches.isEmpty
            || (!set.primariesSecondaries.isEmpty && set.dynamicRange == .sdr)
        if set.dynamicRange == .sdr {
            if !set.grayscale.isEmpty {
                check(s.grayscaleMaxDeltaE, grayscaleMax, "grayscale max ΔE2000")
                check(s.grayscaleAverageDeltaE, grayscaleAverage, "grayscale average ΔE2000")
                check(s.maxLuminanceErrorPercent, luminanceErrorPercent, "grayscale luminance error %")
            }
            if hasColors {
                check(s.maxDeltaE, colorMax, "colour max ΔE2000")
                check(s.p95DeltaE, colorP95, "colour p95 ΔE2000")
            }
        } else {
            if !set.grayscale.isEmpty { check(s.grayscaleMaxDeltaE, hdrGrayscaleMaxITP, "grayscale max ΔE ITP") }
            if hasColors { check(s.maxDeltaE, hdrColorMaxITP, "colour max ΔE ITP") }
        }
        return out
    }
}
