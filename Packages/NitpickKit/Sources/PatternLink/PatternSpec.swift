import ColorScience
import Foundation

/// A measurement window: a centred rectangle covering `areaFraction` of the screen area (0.10 = "10 % window").
public struct WindowSpec: Hashable, Codable, Sendable {
    public var areaFraction: Double
    /// Normalised centre (0.5, 0.5 = screen centre).
    public var centerX: Double
    public var centerY: Double

    public init(areaFraction: Double, centerX: Double = 0.5, centerY: Double = 0.5) {
        self.areaFraction = areaFraction
        self.centerX = centerX
        self.centerY = centerY
    }

    public static let tenPercent = WindowSpec(areaFraction: 0.10)
    public static let fivePercent = WindowSpec(areaFraction: 0.05)
    public static let twoPercent = WindowSpec(areaFraction: 0.02)
    public static let fullField = WindowSpec(areaFraction: 1.0)

    /// Pixel rectangle (x, y, width, height) for a frame of the given size; the window keeps the frame's aspect ratio.
    public func pixelRect(width: Int, height: Int) -> (x: Int, y: Int, width: Int, height: Int) {
        let scale = areaFraction.clamped(to: 0.0001...1).squareRoot()
        let w = max(2, Int((Double(width) * scale).rounded()) & ~1)
        let h = max(2, Int((Double(height) * scale).rounded()) & ~1)
        // Centres are clamped before the Int conversion, which traps on the huge values a malformed request can carry.
        let x = min(max(Int((Double(width) * centerX.clamped(to: 0...1)).rounded()) - w / 2, 0), width - w) & ~1
        let y = min(max(Int((Double(height) * centerY.clamped(to: 0...1)).rounded()) - h / 2, 0), height - h) & ~1
        return (x, y, w, h)
    }
}

/// What to draw.
public enum PatternContent: Hashable, Codable, Sendable {
    /// A patch inside a window on a background (the normal measurement pattern).
    case window(patch: SignalRGB, window: WindowSpec, background: SignalRGB)
    /// The whole screen in one colour.
    case fullField(SignalRGB)
    /// A step wedge of `steps` equal bars from `from` to `to` (inclusive), left→right or top→bottom.
    case ramp(steps: Int, from: SignalRGB, to: SignalRGB, horizontal: Bool)
    /// Explicit vertical bars (e.g. near-white clipping bars) on a background.
    case bars([SignalRGB], background: SignalRGB)
    /// Full black (also used between measurements).
    case black

    /// The colour a meter pointed at the screen centre sees, when the pattern has a single measurable centre.
    public var centerColor: SignalRGB? {
        switch self {
        case .window(let patch, _, _): patch
        case .fullField(let c): c
        case .black: .black
        case .ramp, .bars: nil
        }
    }
}

/// A complete pattern request: content plus how the frame is encoded and (for HDR10) its static metadata.
public struct PatternSpec: Hashable, Codable, Sendable {
    public var content: PatternContent
    public var format: SignalFormat
    public var hdr10Metadata: HDR10StaticMetadata?

    public init(content: PatternContent, format: SignalFormat, hdr10Metadata: HDR10StaticMetadata? = nil) {
        self.content = content
        self.format = format
        self.hdr10Metadata = hdr10Metadata
    }

    /// Convenience: a window patch in the given format.
    public static func patch(
        _ color: SignalRGB, window: WindowSpec = .tenPercent, background: SignalRGB = .black,
        format: SignalFormat, hdr10Metadata: HDR10StaticMetadata? = nil
    ) -> PatternSpec {
        PatternSpec(content: .window(patch: color, window: window, background: background), format: format, hdr10Metadata: hdr10Metadata)
    }

    public static func black(format: SignalFormat) -> PatternSpec { PatternSpec(content: .black, format: format) }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}
