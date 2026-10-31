import Foundation

/// CIE 1931 XYZ tristimulus values. When produced by a meter, `Y` is absolute luminance in cd/m² (nits).
public struct XYZ: Hashable, Codable, Sendable {
    public var X: Double
    public var Y: Double
    public var Z: Double

    public init(X: Double, Y: Double, Z: Double) {
        self.X = X
        self.Y = Y
        self.Z = Z
    }

    public static let zero = XYZ(X: 0, Y: 0, Z: 0)

    /// Chromaticity; falls back to D65 when the sum is zero (a true black has no chromaticity).
    public var chromaticity: Chromaticity {
        let s = X + Y + Z
        guard s > 0 else { return .d65 }
        return Chromaticity(x: X / s, y: Y / s)
    }

    public var xyYColor: xyY { xyY(chromaticity: chromaticity, Y: Y) }

    public static func + (a: XYZ, b: XYZ) -> XYZ { XYZ(X: a.X + b.X, Y: a.Y + b.Y, Z: a.Z + b.Z) }
    public static func - (a: XYZ, b: XYZ) -> XYZ { XYZ(X: a.X - b.X, Y: a.Y - b.Y, Z: a.Z - b.Z) }
    public static func * (a: XYZ, k: Double) -> XYZ { XYZ(X: a.X * k, Y: a.Y * k, Z: a.Z * k) }
    public static func / (a: XYZ, k: Double) -> XYZ { XYZ(X: a.X / k, Y: a.Y / k, Z: a.Z / k) }
}

/// CIE 1931 xy chromaticity.
public struct Chromaticity: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// D65 as defined by ITU-R BT.709 / BT.2020 (4-digit values).
    public static let d65 = Chromaticity(x: 0.3127, y: 0.3290)
    /// DCI-P3 theatre white.
    public static let dciWhite = Chromaticity(x: 0.3140, y: 0.3510)

    /// XYZ with the given luminance.
    public func xyz(Y luminance: Double) -> XYZ {
        guard y > 0 else { return .zero }
        return XYZ(X: x * luminance / y, Y: luminance, Z: (1 - x - y) * luminance / y)
    }

    /// Euclidean distance in xy (a quick, non-perceptual check).
    public func distance(to other: Chromaticity) -> Double {
        ((x - other.x) * (x - other.x) + (y - other.y) * (y - other.y)).squareRoot()
    }
}

/// xyY colour: chromaticity plus luminance.
public struct xyY: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var Y: Double

    public init(x: Double, y: Double, Y: Double) {
        self.x = x
        self.y = y
        self.Y = Y
    }
    public init(chromaticity c: Chromaticity, Y: Double) { self.init(x: c.x, y: c.y, Y: Y) }

    public var chromaticity: Chromaticity { Chromaticity(x: x, y: y) }
    public var xyz: XYZ { chromaticity.xyz(Y: Y) }
}

/// A generic RGB triplet. The encoding (linear light, gamma-coded signal, code values…) is defined by context.
public struct RGB: Hashable, Codable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }
    public init(gray v: Double) { self.init(r: v, g: v, b: v) }

    public static let black = RGB(gray: 0)
    public static let white = RGB(gray: 1)

    public subscript(channel: Int) -> Double {
        get { channel == 0 ? r : channel == 1 ? g : b }
        set { if channel == 0 { r = newValue } else if channel == 1 { g = newValue } else { b = newValue } }
    }

    public var components: [Double] { [r, g, b] }
    public var max: Double { Swift.max(r, g, b) }
    public var min: Double { Swift.min(r, g, b) }
    public var isGray: Bool { r == g && g == b }

    public func map(_ f: (Double) -> Double) -> RGB { RGB(r: f(r), g: f(g), b: f(b)) }
    public func clamped(to range: ClosedRange<Double> = 0...1) -> RGB {
        map { Swift.min(Swift.max($0, range.lowerBound), range.upperBound) }
    }

    public static func + (a: RGB, b: RGB) -> RGB { RGB(r: a.r + b.r, g: a.g + b.g, b: a.b + b.b) }
    public static func - (a: RGB, b: RGB) -> RGB { RGB(r: a.r - b.r, g: a.g - b.g, b: a.b - b.b) }
    public static func * (a: RGB, k: Double) -> RGB { RGB(r: a.r * k, g: a.g * k, b: a.b * k) }
    public static func * (a: RGB, b: RGB) -> RGB { RGB(r: a.r * b.r, g: a.g * b.g, b: a.b * b.b) }
}

/// One reading from a colorimeter. `xyz.Y` is absolute luminance in cd/m².
public struct MeterReading: Hashable, Codable, Sendable {
    public var xyz: XYZ
    public var timestamp: Date
    /// Integration time actually used, in seconds, when the meter reports it.
    public var integrationTime: Double?
    /// Estimated 1σ relative luminance noise of this reading (0.01 = 1 %), when known.
    public var noiseEstimate: Double?
    /// Meter-side flags (e.g. "saturated", "below floor").
    public var flags: [String]

    public init(xyz: XYZ, timestamp: Date = Date(), integrationTime: Double? = nil, noiseEstimate: Double? = nil, flags: [String] = []) {
        self.xyz = xyz
        self.timestamp = timestamp
        self.integrationTime = integrationTime
        self.noiseEstimate = noiseEstimate
        self.flags = flags
    }

    public var luminance: Double { xyz.Y }
    public var chromaticity: Chromaticity { xyz.chromaticity }
}
