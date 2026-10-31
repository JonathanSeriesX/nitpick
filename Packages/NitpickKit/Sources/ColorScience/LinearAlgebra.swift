import Foundation

public enum LinearAlgebra {
    /// Solves A·x = b (A is n×n, row-major `a[row][col]`) by Gauss-Jordan elimination with partial pivoting.
    /// Returns nil for mismatched sizes or a singular (pivot ≤ 1e-12 × largest |a|) system.
    public static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        let n = b.count
        guard a.count == n, a.allSatisfy({ $0.count == n }) else { return nil }
        let tolerance = 1e-12 * (a.joined().map(abs).max() ?? 0)
        var m = zip(a, b).map { $0 + [$1] }
        for col in 0..<n {
            let p = (col..<n).max { abs(m[$0][col]) < abs(m[$1][col]) }!
            guard abs(m[p][col]) > tolerance else { return nil }
            m.swapAt(col, p)
            let pivot = m[col][col]
            m[col] = m[col].map { $0 / pivot }
            for r in 0..<n where r != col && m[r][col] != 0 {
                let f = m[r][col]
                for c in col...n { m[r][c] -= f * m[col][c] }
            }
        }
        return m.map { $0[n] }
    }

    /// The 3×3 M minimising Σ|M·inputs[i] − outputs[i]|² (ordinary least squares via the normal equations
    /// M = (Σ out·inᵀ)(Σ in·inᵀ)⁻¹). Needs ≥ 3 pairs whose inputs span 3D; nil otherwise.
    /// Used to build CCMX-style meter corrections (inputs = meter XYZ, outputs = reference XYZ).
    public static func leastSquaresMatrix(from inputs: [XYZ], to outputs: [XYZ]) -> Matrix3? {
        guard inputs.count == outputs.count, inputs.count >= 3 else { return nil }
        var inIn = [Double](repeating: 0, count: 9)
        var outIn = inIn
        for (i, o) in zip(inputs, outputs) {
            let iv = [i.X, i.Y, i.Z]
            let ov = [o.X, o.Y, o.Z]
            for r in 0..<3 {
                for c in 0..<3 {
                    inIn[r * 3 + c] += iv[r] * iv[c]
                    outIn[r * 3 + c] += ov[r] * iv[c]
                }
            }
        }
        guard let inverse = Matrix3(inIn).inverse else { return nil }
        return Matrix3(outIn) * inverse
    }
}
