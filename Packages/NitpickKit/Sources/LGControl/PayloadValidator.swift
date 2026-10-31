import ColorScience
import Foundation

/// Last check before calibration data leaves the app. Wrong data "COULD brick your TV … requiring a mainboard
/// replacement" (bscpylgtv README, SPEC §0 consequence 5), so this re-decodes the bytes and refuses anything outside
/// the documented layout: wrong command/type/count, out-of-range values, NaN, non-monotonic 1D LUTs (flats allowed).
public enum PayloadValidator {
    /// - Parameter lut3DSize: the TV's 3D LUT grid (17 or 33); nil refuses 3D LUT uploads.
    public static func validate(_ data: ExternalPQData, lut3DSize: Int?) throws {
        let c = data.command
        let expected = c == .calStart ? .float32 : c.dataType
        guard let expected, expected == data.dataType else {
            throw LGError.invalidPayload("\(c.rawValue) needs dataType \(expected?.rawValue ?? "none")")
        }
        guard data.count > 0, data.bytes.count == data.count * data.dataType.byteWidth else {
            throw LGError.invalidPayload("\(c.rawValue): \(data.bytes.count) bytes do not hold \(data.count) × \(data.dataType.rawValue)")
        }
        let v = data.values
        func count(_ n: Int) throws {
            guard v.count == n else { throw LGError.invalidPayload("\(c.rawValue) needs \(n) values, got \(v.count)") }
        }
        func range(_ r: ClosedRange<Double>) throws {
            if let bad = v.first(where: { !$0.isFinite || !r.contains($0) }) {
                throw LGError.invalidPayload("\(c.rawValue) value \(bad) outside \(r.lowerBound)…\(r.upperBound)")
            }
        }
        switch c {
        case .calStart, .calEnd:
            try count(9)
            try range(-1024...1024)
        case _ where ExternalPQCommand.uiData.contains(c):
            try count(1)
            try range(0...100)
        case _ where ExternalPQCommand.flags.contains(c):
            try count(1)
            try range(0...1)
        case .lut1D:
            try count(3072)
            try range(0...32767)
            for ch in 0..<3 {
                let t = v[(ch * 1024)..<(ch * 1024 + 1024)]
                if zip(t, t.dropFirst()).contains(where: { $1 < $0 }) {
                    throw LGError.invalidPayload("1D LUT channel \(ch) is not monotonic")
                }
            }
        case .bt709LUT3D, .bt2020LUT3D:
            guard let n = lut3DSize else { throw LGError.invalidPayload("this TV has no known 3D LUT size") }
            try count(n * n * n * 3)
            try range(0...4095)
        case .bt709Gamut, .bt2020Gamut, .hdrGamut:
            try count(9)
            try range(-1024...1024)
        case .toneMap:
            try count(7)
            for (x, r) in zip(v, LGToneMapParameters.ranges) where !r.contains(x) {
                throw LGError.invalidPayload("tone-map value \(x) outside \(r)")
            }
        case .dolbyConfig:
            guard data.count <= 8192, data.bytes.allSatisfy({ (0x20...0x7E).contains($0) || $0 == 0x0D || $0 == 0x0A }) else {
                throw LGError.invalidPayload("Dolby Vision config must be printable ASCII with CRLF, at most 8 KB")
            }
        default:
            throw LGError.invalidPayload("\(c.rawValue) carries no data")
        }
    }
}

/// `externalpq/getExternalPqData` read commands (SPEC §5.7).
public enum ExternalPQGetter: String, Sendable, CaseIterable {
    case lut1D = "GET_1D_DPG_DATA"
    case lut3D = "GET_3D_LUT_DATA"
    case degamma22 = "GET_1D_2_2_EN"
    case regamma045 = "GET_1D_0_45_EN"
    case gamut = "GET_3BY3_GAMUT_DATA"
    case hdrGamut = "GET_HDR_3BY3_GAMUT_DATA"
}

/// Data the TV reports for the **active** picture mode. It is post-processed with all customisations factored in and
/// "can be partially or completely broken" depending on firmware (SPEC §5.7). Show it as `label`, never as a backup.
public struct ExternalPQReadback: Sendable, Equatable {
    public static let label = "TV readback (processed, not a factory backup)"

    public enum Value: Sendable, Equatable {
        /// Normalised 0…1 (code / 32767).
        case lut1D(LUT1D)
        /// Normalised (code / 4096), in LUT3D's blue-fastest order.
        case lut3D(LUT3D)
        case flag(Bool)
        case matrix(Matrix3)
    }

    public var getter: ExternalPQGetter
    /// Raw element values as sent by the TV.
    public var raw: [Double]
    public var value: Value
    /// Count, range and shape look like real data (1D: near-monotonic with tolerance 1 % of full scale, top ≥ half scale;
    /// 3D: black node dark and white node bright; flag 0/1; matrix finite, ±1024, non-singular).
    public var isPlausible: Bool

    public init(getter: ExternalPQGetter, payload: JSON) throws {
        guard let b64 = payload["data"]?.stringValue, let bytes = Data(base64Encoded: b64),
            let type = payload["dataType"]?.stringValue.flatMap(ExternalPQDataType.init(rawValue:))
        else {
            throw LGError.malformedResponse("readback without data/dataType")
        }
        let raw = ExternalPQData.decode(bytes, as: type)
        if let declared = payload["dataCount"]?.intValue, declared != raw.count {
            throw LGError.malformedResponse("readback dataCount \(declared) but \(raw.count) values")
        }
        self.getter = getter
        self.raw = raw
        switch getter {
        case .lut1D:
            guard raw.count == 3072 else { throw LGError.malformedResponse("1D LUT readback has \(raw.count) values") }
            let t = (0..<3).map { c in raw[(c * 1024)..<(c * 1024 + 1024)].map { $0 / 32767 } }
            value = .lut1D(LUT1D(red: t[0], green: t[1], blue: t[2]))
            isPlausible = (0..<3).allSatisfy { c in
                let ch = raw[(c * 1024)..<(c * 1024 + 1024)]
                return ch.allSatisfy { (0...32767).contains($0) } && (ch.last ?? 0) >= 16384
                    && !zip(ch, ch.dropFirst()).contains { $1 < $0 - 328 }
            }
        case .lut3D:
            let size = Int(cbrt(Double(raw.count / 3)).rounded())
            guard size * size * size * 3 == raw.count, size >= 2 else {
                throw LGError.malformedResponse("3D LUT readback has \(raw.count) values")
            }
            var nodes = [RGB](repeating: .black, count: size * size * size)
            for b in 0..<size {
                for g in 0..<size {
                    for r in 0..<size {
                        let i = 3 * (r + size * g + size * size * b)
                        nodes[(r * size + g) * size + b] = RGB(r: raw[i] / 4096, g: raw[i + 1] / 4096, b: raw[i + 2] / 4096)
                    }
                }
            }
            value = .lut3D(LUT3D(size: size, nodes: nodes))
            isPlausible =
                raw.allSatisfy { (0...4095).contains($0) } && raw.prefix(3).allSatisfy { $0 <= 256 }
                && raw.suffix(3).allSatisfy { $0 >= 2048 }
        case .degamma22, .regamma045:
            guard raw.count == 1 else { throw LGError.malformedResponse("flag readback has \(raw.count) values") }
            value = .flag(raw[0] != 0)
            isPlausible = raw[0] == 0 || raw[0] == 1
        case .gamut, .hdrGamut:
            guard raw.count == 9 else { throw LGError.malformedResponse("3×3 readback has \(raw.count) values") }
            let m = Matrix3(raw)
            value = .matrix(m)
            isPlausible = raw.allSatisfy { $0.isFinite && abs($0) <= 1024 } && abs(m.determinant()) > 1e-6
        }
    }
}
