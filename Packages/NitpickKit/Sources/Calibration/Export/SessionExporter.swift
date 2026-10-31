import ColorScience
import Foundation

/// Text exports of measurements, sessions and LUTs.
public enum SessionExporter {
    /// One row per measured patch: section, name, stimulus R′G′B′, measured and reference XYZ, xy, every ΔE, flags.
    public static func csv(_ set: MeasurementSet) -> String {
        var lines = ["section,name,stimulus_r,stimulus_g,stimulus_b,X,Y,Z,x,y,ref_X,ref_Y,ref_Z,dE2000,dEITP,duv,luminance_error_pct,flags"]
        func row(_ section: String, _ name: String, _ s: SignalRGB, _ e: ColorError, _ flags: [String]) {
            let c = e.measured.chromaticity
            let numbers = [
                s.r, s.g, s.b, e.measured.X, e.measured.Y, e.measured.Z, c.x, c.y, e.reference.X, e.reference.Y, e.reference.Z,
                e.deltaE2000, e.deltaEITP, e.deltaUV, e.luminanceErrorPercent,
            ].map { String(format: "%.6g", $0) }
            let quoted = "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            lines.append(
                ([section, quoted] + numbers + [(flags + e.flags.map(\.rawValue).sorted()).joined(separator: ";")]).joined(separator: ","))
        }
        for p in set.grayscale { row("grayscale", String(format: "%g%%", p.stimulus * 100), .gray(p.stimulus), p.error, p.reading.flags) }
        for p in set.nearBlack { row("nearBlack", String(format: "%g%%", p.stimulus * 100), .gray(p.stimulus), p.error, p.reading.flags) }
        for (section, patches) in [
            ("primaries", set.primariesSecondaries), ("saturation", set.saturationSweeps), ("verification", set.verificationPatches),
        ] {
            for p in patches { row(section, p.name, p.signal, p.error, []) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Pretty-printed, key-sorted JSON with ISO 8601 dates.
    public static func json(_ session: CalibrationSession) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(session)
    }

    /// DaVinci Resolve / Adobe `.cube`: TITLE, LUT_3D_SIZE, then size³ "r g b" lines with red changing fastest.
    public static func cube(_ lut: LUT3D, title: String) -> String {
        var lines = [
            "TITLE \"\(title.replacingOccurrences(of: "\"", with: "'"))\"", "LUT_3D_SIZE \(lut.size)", "DOMAIN_MIN 0.0 0.0 0.0",
            "DOMAIN_MAX 1.0 1.0 1.0",
        ]
        lines.reserveCapacity(lut.size * lut.size * lut.size + 4)
        for b in 0..<lut.size {
            for g in 0..<lut.size {
                for r in 0..<lut.size {
                    let n = lut[r, g, b]
                    lines.append(String(format: "%.6f %.6f %.6f", n.r, n.g, n.b))
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Resolve 1D `.cube`: LUT_1D_SIZE, then one "r g b" line per entry.
    public static func lut1DText(_ lut: LUT1D) -> String {
        var lines = ["LUT_1D_SIZE \(lut.size)", "DOMAIN_MIN 0.0 0.0 0.0", "DOMAIN_MAX 1.0 1.0 1.0"]
        for i in 0..<lut.size { lines.append(String(format: "%.6f %.6f %.6f", lut.red[i], lut.green[i], lut.blue[i])) }
        return lines.joined(separator: "\n") + "\n"
    }
}
