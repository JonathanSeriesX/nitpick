import Foundation

/// Spectral power distributions sampled at uniform wavelength steps (one row per sample, e.g. R, G, B, W of a display).
public struct SpectralSamples: Hashable, Codable, Sendable {
    public var startWavelength: Double  // nm
    public var step: Double  // nm
    public var rows: [[Double]]

    public init(startWavelength: Double, step: Double, rows: [[Double]]) {
        self.startWavelength = startWavelength
        self.step = step
        self.rows = rows
    }

    public var count: Int { rows.first?.count ?? 0 }
    public func wavelength(at index: Int) -> Double { startWavelength + Double(index) * step }
}

/// A colorimeter correction for a display technology: either a 3×3 XYZ→XYZ matrix (Argyll .ccmx)
/// or display spectral samples (Argyll .ccss) from which the meter driver derives a matrix using its own sensor curves.
public struct ColorimeterCorrection: Hashable, Codable, Sendable {
    public enum Kind: Hashable, Codable, Sendable {
        /// Row-major 3×3 applied to the meter's uncorrected XYZ.
        case matrix([Double])
        case spectral(SpectralSamples)
    }

    public var name: String
    public var displayTechnology: String?
    public var kind: Kind
    /// Where it came from (file path, "built-in", …) for the UI and reports.
    public var source: String?

    public init(name: String, displayTechnology: String? = nil, kind: Kind, source: String? = nil) {
        self.name = name
        self.displayTechnology = displayTechnology
        self.kind = kind
        self.source = source
    }
}
