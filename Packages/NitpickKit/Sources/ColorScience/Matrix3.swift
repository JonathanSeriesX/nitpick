import Foundation

/// A 3×3 matrix stored row-major: `m[row * 3 + col]`. Vectors are columns, so `M * v` applies M to v and
/// `A * B` applies B first.
public struct Matrix3: Hashable, Codable, Sendable {
    public var m: [Double]

    /// `m` must hold exactly 9 values, row-major.
    public init(_ m: [Double]) {
        precondition(m.count == 9, "Matrix3 needs 9 values")
        self.m = m
    }

    public init(rows r0: (Double, Double, Double), _ r1: (Double, Double, Double), _ r2: (Double, Double, Double)) {
        self.init([r0.0, r0.1, r0.2, r1.0, r1.1, r1.2, r2.0, r2.1, r2.2])
    }

    public static let identity = Matrix3([1, 0, 0, 0, 1, 0, 0, 0, 1])

    /// Diagonal matrix.
    public static func scaling(_ x: Double, _ y: Double, _ z: Double) -> Matrix3 { Matrix3([x, 0, 0, 0, y, 0, 0, 0, z]) }

    public subscript(row: Int, col: Int) -> Double {
        get { m[row * 3 + col] }
        set { m[row * 3 + col] = newValue }
    }

    public subscript(row row: Int, col col: Int) -> Double {
        get { self[row, col] }
        set { self[row, col] = newValue }
    }

    public func determinant() -> Double {
        m[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (m[3] * m[8] - m[5] * m[6]) + m[2] * (m[3] * m[7] - m[4] * m[6])
    }

    /// Inverse by the adjugate; nil when the matrix is singular (|det| ≤ 1e-12 relative to the entries' scale).
    public var inverse: Matrix3? {
        let d = determinant()
        let scale = m.map(abs).max() ?? 0
        guard d.isFinite, abs(d) > 1e-12 * scale * scale * scale else { return nil }
        let a = Matrix3(
            rows: (m[4] * m[8] - m[5] * m[7], m[2] * m[7] - m[1] * m[8], m[1] * m[5] - m[2] * m[4]),
            (m[5] * m[6] - m[3] * m[8], m[0] * m[8] - m[2] * m[6], m[2] * m[3] - m[0] * m[5]),
            (m[3] * m[7] - m[4] * m[6], m[1] * m[6] - m[0] * m[7], m[0] * m[4] - m[1] * m[3]))
        return Matrix3(a.m.map { $0 / d })
    }

    public var transposed: Matrix3 { Matrix3([m[0], m[3], m[6], m[1], m[4], m[7], m[2], m[5], m[8]]) }

    public static func * (a: Matrix3, b: Matrix3) -> Matrix3 {
        Matrix3(
            (0..<9).map { i in
                let r = i / 3
                let c = i % 3
                return a.m[r * 3] * b.m[c] + a.m[r * 3 + 1] * b.m[3 + c] + a.m[r * 3 + 2] * b.m[6 + c]
            })
    }

    public static func * (a: Matrix3, v: XYZ) -> XYZ {
        let (x, y, z) = a.apply(v.X, v.Y, v.Z)
        return XYZ(X: x, Y: y, Z: z)
    }

    public static func * (a: Matrix3, v: RGB) -> RGB {
        let (r, g, b) = a.apply(v.r, v.g, v.b)
        return RGB(r: r, g: g, b: b)
    }

    func apply(_ x: Double, _ y: Double, _ z: Double) -> (Double, Double, Double) {
        (m[0] * x + m[1] * y + m[2] * z, m[3] * x + m[4] * y + m[5] * z, m[6] * x + m[7] * y + m[8] * z)
    }
}
