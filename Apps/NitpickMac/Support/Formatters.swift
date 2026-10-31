import Calibration
import ColorScience
import Foundation
import SwiftUI

/// Number, date and setting formatting shared by the screens, exports and the headless demo run.
enum Fmt {
    static func num(_ value: Double, _ digits: Int = 2) -> String {
        value.isFinite ? value.formatted(.number.precision(.fractionLength(digits)).grouping(.never)) : "–"
    }

    static func nits(_ value: Double) -> String {
        let digits = value >= 100 ? 0 : value >= 1 ? 1 : 4
        return "\(num(value, digits)) cd/m²"
    }

    /// Stimulus 0…1 as "50 %".
    static func stimulus(_ value: Double) -> String { "\(num(value * 100, value * 100 == (value * 100).rounded() ? 0 : 1)) %" }

    static func date(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }

    /// "4:05" or "1:02:03".
    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func xy(_ c: Chromaticity) -> String { "\(num(c.x, 4)) / \(num(c.y, 4))" }

    static func contrast(_ ratio: Double?) -> String {
        guard let ratio else { return "∞" }
        return "\(ratio.formatted(.number.precision(.fractionLength(0)))):1"
    }

    /// A TV setting value as the TV reported it.
    static func json(_ value: JSONValue) -> String {
        switch value {
        case .string(let s): s
        case .number(let d): d == d.rounded() ? String(Int(d)) : num(d, 3)
        case .bool(let b): b ? "on" : "off"
        case .null: "–"
        case .array(let a): "\(a.count) entries"
        case .object(let o): "\(o.count) fields"
        }
    }

    /// One-line summary of a measurement set (used by the headless demo run).
    static func line(_ set: MeasurementSet) -> String {
        let s = set.summary
        let unit = set.dynamicRange == .sdr ? "ΔE2000" : "ΔE ITP"
        var parts = [
            "colour \(unit) avg \(num(s.averageDeltaE)) p95 \(num(s.p95DeltaE)) max \(num(s.maxDeltaE))",
            "gray avg \(num(s.grayscaleAverageDeltaE)) max \(num(s.grayscaleMaxDeltaE))",
        ]
        if let gamma = s.averageGamma { parts.append("gamma \(num(gamma))") }
        parts.append("EOTF track \(num(s.eotfTrackingErrorPercent, 1)) % (max \(num(s.maxLuminanceErrorPercent, 1)) %)")
        parts.append("contrast \(contrast(s.contrastRatio))")
        parts.append("white \(num(s.whitePointCCT, 0)) K")
        parts.append("peak \(nits(set.peakLuminance))")
        return parts.joined(separator: " | ")
    }
}

/// The five session groups of the sidebar.
enum ProfileGroup: String, CaseIterable, Identifiable {
    case movieSDR, gameSDR, movieHDR10, gameHDR10, dolbyVision

    var id: String { rawValue }

    init(_ profile: SessionProfile) {
        switch (profile.dynamicRange, profile.usage) {
        case (.dolbyVision, _): self = .dolbyVision
        case (.sdr, .game): self = .gameSDR
        case (.sdr, .movie): self = .movieSDR
        case (_, .game): self = .gameHDR10
        case (_, .movie): self = .movieHDR10
        }
    }

    var title: String {
        switch self {
        case .movieSDR: "Movie SDR"
        case .gameSDR: "Game SDR"
        case .movieHDR10: "Movie HDR10"
        case .gameHDR10: "Game HDR10"
        case .dolbyVision: "Dolby Vision"
        }
    }

    var symbol: String {
        switch self {
        case .movieSDR: "film"
        case .gameSDR: "gamecontroller"
        case .movieHDR10: "sun.max"
        case .gameHDR10: "gamecontroller.fill"
        case .dolbyVision: "sparkles.tv"
        }
    }
}

/// webOS picture-mode ids and their on-screen names.
enum PictureModes {
    static let names: [String: String] = [
        "expert1": "Expert (Dark Room)", "expert2": "Expert (Bright Room)", "cinema": "Cinema", "filmMaker": "Filmmaker",
        "game": "Game Optimizer", "hdr_cinema": "Cinema (HDR)", "hdr_filmMaker": "Filmmaker (HDR)",
        "hdr_game": "Game Optimizer (HDR)", "dolby_cinema_dark": "Cinema Dark (Dolby Vision)",
        "dolby_game": "Game Optimizer (Dolby Vision)",
    ]

    static func name(_ id: String) -> String { names[id] ?? id }

    static func ids(for range: DynamicRange) -> [String] {
        SimulatedPanel.pictureModes.filter { SimulatedPanel.signalPath(of: $0) == range }
    }

    static func isGame(_ id: String) -> Bool { SimulatedPanel.isGameMode(id) }
}

extension CalibrationSession.Status {
    var title: String {
        switch self {
        case .draft: "Not run"
        case .running: "Running"
        case .completed: "Completed"
        case .cancelled: "Cancelled"
        case .failed: "Failed"
        case .interrupted: "Interrupted"
        }
    }

    var symbol: String {
        switch self {
        case .draft: "circle.dashed"
        case .running: "play.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .cancelled: "xmark.circle"
        case .failed: "exclamationmark.octagon.fill"
        case .interrupted: "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .draft, .cancelled: .secondary
        case .running: .blue
        case .completed: .green
        case .failed: .red
        case .interrupted: .orange
        }
    }
}

extension CalibrationSession {
    /// "Movie · SDR · Expert (Dark Room) · HDMI 1"
    var subtitle: String {
        let p = profile
        return [
            p.usage == .movie ? "Movie" : "Game", p.dynamicRange.displayName, PictureModes.name(p.pictureMode),
            p.inputID.replacingOccurrences(of: "_", with: " "),
        ].joined(separator: " · ")
    }

    var targetDescription: String {
        let t = profile.target
        if t.isHDR {
            let metadata = t.hdr10Metadata.map { "\(Fmt.num($0.maxMasteringLuminance, 0)) cd/m² metadata" } ?? "no metadata"
            return "PQ · \(metadata) · \(t.hdrMapping == .rollOff ? "roll-off" : "hard clip (HGIG)")"
        }
        return "\(t.eotf.displayName) · \(Fmt.nits(t.peakWhite)) · D65"
    }

    /// Completed with every tolerance met.
    var passed: Bool { result?.passed ?? false }
}
