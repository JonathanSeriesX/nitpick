import Foundation

/// A per-channel 1D lookup table. Input index i maps to signal i/(size-1); outputs are normalised 0…1 signal.
public struct LUT1D: Hashable, Codable, Sendable {
    public var red: [Double]
    public var green: [Double]
    public var blue: [Double]

    public init(red: [Double], green: [Double], blue: [Double]) {
        precondition(red.count == green.count && green.count == blue.count && red.count >= 2)
        self.red = red; self.green = green; self.blue = blue
    }

    public var size: Int { red.count }

    public static func identity(size: Int = 1024) -> LUT1D {
        let ramp = (0..<size).map { Double($0) / Double(size - 1) }
        return LUT1D(red: ramp, green: ramp, blue: ramp)
    }

    public func channel(_ index: Int) -> [Double] { index == 0 ? red : index == 1 ? green : blue }

    /// Linear interpolation of one channel's table at normalised input `v`.
    public static func sample(_ table: [Double], at v: Double) -> Double {
        let x = Swift.min(Swift.max(v, 0), 1) * Double(table.count - 1)
        let i = Int(x.rounded(.down))
        if i >= table.count - 1 { return table[table.count - 1] }
        let f = x - Double(i)
        return table[i] + (table[i + 1] - table[i]) * f
    }

    public func apply(_ rgb: RGB) -> RGB {
        RGB(r: Self.sample(red, at: rgb.r), g: Self.sample(green, at: rgb.g), b: Self.sample(blue, at: rgb.b))
    }

    /// Integer tables scaled to `maxCode` (e.g. 4095 or 65535), clamped and rounded.
    public func quantized(maxCode: Int) -> (red: [UInt16], green: [UInt16], blue: [UInt16]) {
        func q(_ t: [Double]) -> [UInt16] {
            t.map { UInt16(Swift.min(Swift.max(($0 * Double(maxCode)).rounded(), 0), Double(maxCode))) }
        }
        return (q(red), q(green), q(blue))
    }
}

/// A 3D lookup table of `size³` RGB nodes. Node (ri, gi, bi) is stored at index `(ri * size + gi) * size + bi`
/// (blue varies fastest). Inputs and outputs are normalised 0…1 signal.
public struct LUT3D: Hashable, Codable, Sendable {
    public var size: Int
    public var nodes: [RGB]

    public init(size: Int, nodes: [RGB]) {
        precondition(nodes.count == size * size * size && size >= 2)
        self.size = size
        self.nodes = nodes
    }

    public static func identity(size: Int = 33) -> LUT3D {
        var nodes: [RGB] = []
        nodes.reserveCapacity(size * size * size)
        let d = Double(size - 1)
        for r in 0..<size { for g in 0..<size { for b in 0..<size {
            nodes.append(RGB(r: Double(r) / d, g: Double(g) / d, b: Double(b) / d))
        } } }
        return LUT3D(size: size, nodes: nodes)
    }

    public func index(_ r: Int, _ g: Int, _ b: Int) -> Int { (r * size + g) * size + b }

    public subscript(r: Int, g: Int, b: Int) -> RGB {
        get { nodes[index(r, g, b)] }
        set { nodes[index(r, g, b)] = newValue }
    }

    /// Trilinear interpolation.
    public func apply(_ rgb: RGB) -> RGB {
        let d = Double(size - 1)
        func split(_ v: Double) -> (Int, Double) {
            let x = Swift.min(Swift.max(v, 0), 1) * d
            let i = Swift.min(Int(x.rounded(.down)), size - 2)
            return (i, x - Double(i))
        }
        let (ri, rf) = split(rgb.r), (gi, gf) = split(rgb.g), (bi, bf) = split(rgb.b)
        func lerp(_ a: RGB, _ b: RGB, _ t: Double) -> RGB { a * (1 - t) + b * t }
        let c00 = lerp(self[ri, gi, bi], self[ri + 1, gi, bi], rf)
        let c10 = lerp(self[ri, gi + 1, bi], self[ri + 1, gi + 1, bi], rf)
        let c01 = lerp(self[ri, gi, bi + 1], self[ri + 1, gi, bi + 1], rf)
        let c11 = lerp(self[ri, gi + 1, bi + 1], self[ri + 1, gi + 1, bi + 1], rf)
        return lerp(lerp(c00, c10, gf), lerp(c01, c11, gf), bf)
    }
}
