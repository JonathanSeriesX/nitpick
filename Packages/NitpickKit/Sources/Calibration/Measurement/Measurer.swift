import Foundation
import ColorScience
import PatternLink

public struct MeasurementSettings: Codable, Hashable, Sendable {
    /// Wait after a pattern is acknowledged before the first read.
    public var settlingTime: Duration
    public var minReads: Int
    public var maxReads: Int
    /// Stop reading once the relative 1σ luminance noise of the averaged result is at or below this (0.004 = 0.4 %).
    public var targetNoise: Double
    public var window: WindowSpec
    /// Show black for 0.3 s before every pattern (limits retention / ABL history effects; costs time).
    public var blackPatchBetweenPatterns: Bool
    /// Wall-clock deadline for each pattern-generator or meter call.
    public var perPatternTimeout: Duration

    public init(settlingTime: Duration, minReads: Int = 1, maxReads: Int = 5, targetNoise: Double = 0.004,
                window: WindowSpec = .tenPercent, blackPatchBetweenPatterns: Bool = false, perPatternTimeout: Duration = .seconds(15)) {
        self.settlingTime = settlingTime; self.minReads = minReads; self.maxReads = maxReads; self.targetNoise = targetNoise
        self.window = window; self.blackPatchBetweenPatterns = blackPatchBetweenPatterns; self.perPatternTimeout = perPatternTimeout
    }

    public static let sdr = MeasurementSettings(settlingTime: .milliseconds(800))
    public static let hdr = MeasurementSettings(settlingTime: .milliseconds(1200))
}

/// Shows patterns and reads the meter: show → settle → read until the averaged noise is low enough.
public struct Measurer: Sendable {
    public var meter: any Meter
    public var source: any PatternSource
    public var sleeper: any Sleeper
    public var settings: MeasurementSettings

    public init(meter: any Meter, source: any PatternSource, sleeper: any Sleeper, settings: MeasurementSettings) {
        self.meter = meter; self.source = source; self.sleeper = sleeper; self.settings = settings
    }

    /// Measures one window patch. The result averages XYZ over 1…maxReads reads; `noiseEstimate` is the relative
    /// 1σ luminance noise of that average; `integrationTime` the mean per read; flags are the union.
    /// `expectedLuminance` is the meter's hint for its first read; later reads use the previous reading.
    public func measure(_ signal: SignalRGB, format: SignalFormat, metadata: HDR10StaticMetadata? = nil,
                        expectedLuminance: Double? = nil) async throws -> MeterReading {
        let source = self.source, meter = self.meter, timeout = settings.perPatternTimeout
        try Task.checkCancellation()
        if settings.blackPatchBetweenPatterns {
            _ = try await withTimeout(timeout, "Pattern generator") { try await source.show(.black(format: format)) }
            try await sleeper.sleep(for: .milliseconds(300))
        }
        let pattern = PatternSpec.patch(signal, window: settings.window, format: format, hdr10Metadata: metadata)
        _ = try await withTimeout(timeout, "Pattern generator") { try await source.show(pattern) }
        try await sleeper.sleep(for: settings.settlingTime)

        var readings: [MeterReading] = []
        var hint = expectedLuminance
        while true {
            try Task.checkCancellation()
            let h = hint
            let reading = try await withTimeout(timeout, "Meter") { try await meter.measure(expectedLuminance: h) }
            readings.append(reading)
            hint = reading.luminance
            if readings.count >= settings.maxReads { break }
            if readings.count >= max(settings.minReads, 1), Self.noiseOfMean(readings) <= settings.targetNoise { break }
        }
        return Self.average(readings)
    }

    /// Relative 1σ of the mean luminance: the larger of the meter's own estimate and the sample spread, over √n.
    static func noiseOfMean(_ readings: [MeterReading]) -> Double {
        let n = Double(readings.count)
        let mean = readings.map(\.luminance).reduce(0, +) / n
        let estimates = readings.compactMap(\.noiseEstimate)
        var single = estimates.isEmpty ? 0 : estimates.reduce(0, +) / Double(estimates.count)
        if readings.count > 1, mean > 0 {
            let variance = readings.map { ($0.luminance - mean) * ($0.luminance - mean) }.reduce(0, +) / (n - 1)
            single = max(single, variance.squareRoot() / mean)
        }
        return single / n.squareRoot()
    }

    static func average(_ readings: [MeterReading]) -> MeterReading {
        let n = Double(readings.count)
        let xyz = readings.map(\.xyz).reduce(XYZ.zero, +) / n
        let times = readings.compactMap(\.integrationTime)
        var flags: [String] = []
        for flag in readings.flatMap(\.flags) where !flags.contains(flag) { flags.append(flag) }
        return MeterReading(xyz: xyz, timestamp: readings.last!.timestamp,
                            integrationTime: times.isEmpty ? nil : times.reduce(0, +) / Double(times.count),
                            noiseEstimate: noiseOfMean(readings), flags: flags)
    }
}

/// Which sections a measurement run includes.
public struct MeasurementPlan: Hashable, Sendable {
    public var grayscale = true
    public var nearBlack = true
    public var primariesSecondaries = true
    public var saturationSweeps = true
    public var verification = true

    public init(grayscale: Bool = true, nearBlack: Bool = true, primariesSecondaries: Bool = true,
                saturationSweeps: Bool = true, verification: Bool = true) {
        self.grayscale = grayscale; self.nearBlack = nearBlack; self.primariesSecondaries = primariesSecondaries
        self.saturationSweeps = saturationSweeps; self.verification = verification
    }

    public static let full = MeasurementPlan()
    public static let withoutVerification = MeasurementPlan(verification: false)
    public static let verificationOnly = MeasurementPlan(grayscale: false, nearBlack: false, primariesSecondaries: false, saturationSweeps: false)
}

extension Measurer {
    /// Measures `plan` against `target` (grayscale ascending to limit settling transients) and computes every error.
    ///
    /// SDR: the target's black is replaced by the measured black (0 when below the meter floor) before references are
    /// computed. HDR: grey references use `Metrics.hdrGrayReference` with the measured peak; points beyond the expected
    /// knee are flagged `.inRollOff`. `onReading` sees every averaged reading with its reference.
    public func measureSet(_ plan: MeasurementPlan, target: CalibrationTarget,
                           onReading: @Sendable (SignalRGB, MeterReading, XYZ?) -> Void = { _, _, _ in }) async throws -> MeasurementSet {
        let format = target.format, metadata = target.hdr10Metadata
        // Signals are quantised up front so stimuli and references describe what the TV really received.
        func read(_ signal: SignalRGB) async throws -> MeterReading {
            let reading = try await measure(signal, format: format, metadata: metadata, expectedLuminance: target.reference(signal).Y)
            onReading(signal, reading, nil)
            return reading
        }
        let grayStimuli = plan.grayscale ? Stimuli.grayscale(target.dynamicRange) : []
        var grayReadings: [(Double, MeterReading)] = []
        for s in grayStimuli.map(target.quantizedGray) { grayReadings.append((s, try await read(.gray(s)))) }
        var nearReadings: [(Double, MeterReading)] = []
        if plan.nearBlack { for s in Stimuli.nearBlack.map(target.quantizedGray) { nearReadings.append((s, try await read(.gray(s)))) } }

        let blackReading = grayReadings.first { $0.0 == 0 }?.1
        let black = blackReading.map { $0.flags.contains("belowFloor") ? 0 : max($0.luminance, 0) } ?? 0
        let peak = grayReadings.map(\.1.luminance).max() ?? 0
        let resolved = blackReading == nil ? target : target.withBlackLevel(black)

        func grayPoint(_ s: Double, _ reading: MeterReading) -> GrayscalePoint {
            var reference = resolved.reference(.gray(s)), flags: Set<ColorError.Flag> = []
            if resolved.isHDR {
                let r = Metrics.hdrGrayReference(stimulus: s, target: resolved, displayPeak: peak)
                reference = r.xyz
                if r.inRollOff { flags.insert(.inRollOff) }
            }
            var gamma: Double?
            let relative = (reading.luminance - black) / (peak - black)
            if !resolved.isHDR, s > 0, s < 1, relative > 0, peak > black { gamma = log(relative) / log(s) }
            return GrayscalePoint(stimulus: s, reading: reading, error: Metrics.error(measured: reading.xyz, reference: reference, target: resolved, flags: flags),
                                  cct: CIE.cct(reading.chromaticity), gamma: gamma)
        }

        func patches(_ list: [(name: String, signal: SignalRGB)]) async throws -> [ColorPatchResult] {
            var out: [ColorPatchResult] = []
            for p in list {
                let signal = p.signal.quantized(in: format)
                let reading = try await read(signal)
                out.append(ColorPatchResult(name: p.name, signal: signal,
                                            error: Metrics.error(measured: reading.xyz, reference: resolved.reference(signal), target: resolved)))
            }
            return out
        }
        let primaries = plan.primariesSecondaries ? try await patches(Stimuli.primariesSecondaries(resolved)) : []
        let sweeps = plan.saturationSweeps ? try await patches(Stimuli.saturationSweeps(resolved)) : []
        let verification = plan.verification ? try await patches(Stimuli.verification(resolved)) : []
        return MeasurementSet(dynamicRange: target.dynamicRange, grayscale: grayReadings.map(grayPoint),
                              primariesSecondaries: primaries, saturationSweeps: sweeps, verificationPatches: verification,
                              nearBlack: nearReadings.map(grayPoint), peakLuminance: peak, blackLevel: black)
    }
}
