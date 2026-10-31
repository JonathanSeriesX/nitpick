import ColorScience
import Foundation

/// What the per-mode adjustment stage produced.
struct AdjustOutcome {
    var lut1D: LUT1D?
    var lut3D: LUT3D?
    var dolbyConfig: DolbyVisionConfig?
    var tone: HDRToneReport?
}

/// The per-mode adjustment stage. Steps are shared, corrections are always measured on the mode being calibrated.
extension CalibrationContext {
    func adjust(_ profile: SessionProfile, capabilities: TVCapabilities, dolbySource: MeasurementSet?) async throws -> AdjustOutcome {
        switch (profile.dynamicRange, profile.usage) {
        case (.sdr, .movie): return try await sdrMovie(profile, capabilities)
        case (.sdr, .game): return try await sdrGame()
        case (.hdr10, .movie): return try await hdrMovie(profile, capabilities)
        case (.hdr10, .game): return try await hdrGame()
        case (.dolbyVision, _): return try await dolbyVision(dolbySource)
        default: throw CalibrationError.precondition("No workflow for \(profile.dynamicRange.displayName) \(profile.usage.rawValue)")
        }
    }

    /// SDR movie: OLED light/contrast → 2-point WB → (LUT path) reset, 1D LUT, optional 3D LUT; (controls path) 20-point WB.
    func sdrMovie(_ profile: SessionProfile, _ capabilities: TVCapabilities) async throws -> AdjustOutcome {
        let useLUTs = profile.useInternalLUTs && capabilities.supportsCalibrationAPI
        if profile.useInternalLUTs && !useLUTs { emit(.warning("The TV reports no calibration API; using picture controls only")) }
        if useLUTs {
            emit(.warning("Resetting the internal calibration of \(pictureMode); its previous LUTs cannot be read back or restored"))
            try await upload(.resetCalibration(pictureMode: pictureMode), "reset \(pictureMode)")
        }
        // Leave 3 % headroom so the 1D LUT can still steer every channel at white.
        try await setPeak(target.eotf.peakLuminance * (useLUTs ? 1.03 : 1))
        _ = try await TwoPointWhiteBalance().run(self)
        guard useLUTs else {
            _ = try await TwentyPointWhiteBalance().run(self)
            return AdjustOutcome()
        }

        // LUT source data is baked into the TV, so it averages at least 3 reads per patch.
        var careful = self
        careful.measurer.settings.minReads = max(careful.measurer.settings.minReads, 3)
        var gray: [(stimulus: Double, xyz: XYZ)] = []
        for s in Stimuli.grayscale(.sdr) { gray.append((target.quantizedGray(s), try await careful.measureGray(s).xyz)) }
        var primaries: [XYZ] = []
        for signal in [SignalRGB(r: 1, g: 0, b: 0), SignalRGB(r: 0, g: 1, b: 0), SignalRGB(r: 0, g: 0, b: 1)] {
            primaries.append(try await careful.measure(signal, reference: target.reference(signal)).xyz)
        }
        let (lut, report) = try GrayscaleLUTBuilder().build(
            grayscale: gray, primaries: (primaries[0], primaries[1], primaries[2]), target: target)
        report.warnings.forEach { emit(.warning($0)) }
        try await upload(.upload1DLUT(lut, pictureMode: pictureMode), "1D LUT \(pictureMode)")
        var outcome = AdjustOutcome(lut1D: lut)
        guard profile.cubeLUT else { return outcome }

        let builder = CubeLUTBuilder(size: profile.cubeSize, gridLevels: profile.cubeGridLevels)
        var grid: [XYZ] = []
        for signal in builder.gridSignals() { grid.append(try await careful.measure(signal, reference: target.reference(signal)).xyz) }
        let (cube, cubeReport) = try builder.build(measurements: grid, target: target, lut1D: lut)
        if cubeReport.clippedNodes > 0 {
            emit(.warning("\(cubeReport.clippedNodes) 3D LUT nodes lie outside the panel gamut and were pulled toward grey"))
        }
        try await upload(
            .upload3DLUT(cube, colorimetry: target.colorimetry, pictureMode: pictureMode),
            "3D LUT \(cube.size)³ \(target.colorimetry.rawValue) \(pictureMode)")
        outcome.lut3D = cube
        return outcome
    }

    /// SDR game: OLED light/contrast → 2-point → 20-point WB. Nothing is uploaded.
    func sdrGame() async throws -> AdjustOutcome {
        try await setPeak(target.eotf.peakLuminance)
        _ = try await TwoPointWhiteBalance().run(self)
        _ = try await TwentyPointWhiteBalance().run(self)
        return AdjustOutcome()
    }

    /// HDR10 movie: tone analysis → tonemap parameters (calibration API) → 20-point WB below the knee.
    func hdrMovie(_ profile: SessionProfile, _ capabilities: TVCapabilities) async throws -> AdjustOutcome {
        let tone = try await analyzeTone()
        if profile.useInternalLUTs && capabilities.supportsCalibrationAPI {
            try await upload(.setToneMap(tone.proposed, pictureMode: pictureMode), "tonemap \(pictureMode)")
        }
        let limit = PQ.inverseEOTF(min(tone.kneeLuminance, 0.7 * tone.peakLuminance))
        _ = try await TwentyPointWhiteBalance(optimizer: WhiteBalanceOptimizer(tolerance: 1.0), maxStimulus: limit).run(self)
        return AdjustOutcome(tone: tone)
    }

    /// HDR10 game (HGiG): tone analysis (report only) → 2-point → 20-point WB up to the clip. Nothing is uploaded.
    func hdrGame() async throws -> AdjustOutcome {
        let tone = try await analyzeTone()
        if !tone.isHardClip {
            emit(
                .warning(
                    String(
                        format: "Expected an HGiG hard clip but the TV rolls off from %.0f cd/m²; check Dynamic Tone Mapping = HGIG",
                        tone.kneeLuminance)))
        }
        let top = PQ.inverseEOTF(0.95 * min(tone.kneeLuminance, tone.peakLuminance))
        var twoPoint = TwoPointWhiteBalance(
            highStimulus: (PQ.inverseEOTF(0.5 * tone.peakLuminance) * 100).rounded() / 100,
            lowStimulus: 0.25, optimizer: WhiteBalanceOptimizer(tolerance: 1.0))
        twoPoint.verificationStimuli = twoPoint.verificationStimuli.filter { $0 <= top }
        _ = try await twoPoint.run(self)
        _ = try await TwentyPointWhiteBalance(optimizer: WhiteBalanceOptimizer(tolerance: 1.0), maxStimulus: top).run(self)
        return AdjustOutcome(tone: tone)
    }

    /// Dolby Vision: config from the source HDR10 measurements, uploaded to this mode.
    func dolbyVision(_ source: MeasurementSet?) async throws -> AdjustOutcome {
        guard let source else {
            throw CalibrationError.precondition("Dolby Vision needs the measurements of a completed HDR10 movie session")
        }
        let (config, warnings) = try DolbyVisionConfigBuilder().build(from: source)
        warnings.forEach { emit(.warning($0)) }
        try await upload(.setDolbyVisionConfig(config, pictureMode: pictureMode), "Dolby Vision config \(pictureMode)")
        return AdjustOutcome(dolbyConfig: config)
    }

    /// Measures the dense HDR grayscale and analyses it.
    func analyzeTone() async throws -> HDRToneReport {
        var readings: [(stimulus: Double, xyz: XYZ)] = []
        for s in HDRToneAnalyzer.stimuli { readings.append((target.quantizedGray(s), try await measureGray(s).xyz)) }
        let report = HDRToneAnalyzer().analyze(readings, metadata: target.hdr10Metadata, whitePoint: target.whitePoint)
        emit(
            .progress(
                fraction: 0,
                message: String(
                    format: "Peak %.0f cd/m², knee %.0f cd/m²%@", report.peakLuminance,
                    report.kneeLuminance, report.isHardClip ? ", hard clip" : "")))
        return report
    }

    /// Bounded search on the 100 % patch: smallest OLED light reaching `goal` (binary search), then contrast steps
    /// (≈ 0.4 % signal each) toward `goal`, within `bounds`.
    func setPeak(_ goal: Double) async throws {
        let settings = try await readSettings()
        var light = settings.int(PictureKey.backlight) ?? 50
        var contrast = settings.int(PictureKey.contrast) ?? 85
        var lo = bounds.oledLight.lowerBound
        var hi = bounds.oledLight.upperBound
        var best: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            try await write(keys: [PictureKey.backlight], values: [mid], previous: [light])
            light = mid
            if try await measureGray(1).luminance >= goal {
                best = mid
                hi = mid - 1
            } else {
                lo = mid + 1
            }
        }
        let chosen = best ?? bounds.oledLight.upperBound
        try await write(keys: [PictureKey.backlight], values: [chosen], previous: [light])
        light = chosen
        guard best != nil else {
            emit(.warning(String(format: "Peak white stays below %.0f cd/m² at the highest allowed OLED light", goal)))
            return
        }
        var y = try await measureGray(1).luminance
        for _ in 0..<3 {
            let steps = Int((log(y / goal) / (2.4 * 0.004)).rounded())
            let next = bounds.clamp(PictureKey.contrast, contrast - steps)
            guard steps != 0, next != contrast else { break }
            try await write(keys: [PictureKey.contrast], values: [next], previous: [contrast])
            contrast = next
            y = try await measureGray(1).luminance
        }
    }
}
