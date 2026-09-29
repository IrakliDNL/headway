import Foundation

/// The little bit of dense linear algebra the models need. Matrices here are at most ~10×10.
enum Matrix {
    static func identity(_ n: Int) -> [[Double]] {
        (0..<n).map { i in (0..<n).map { $0 == i ? 1 : 0 } }
    }

    /// Solves A·X = B with Gaussian elimination and partial pivoting. A is n×n, B is n×m.
    static func solve(_ a: [[Double]], _ b: [[Double]]) -> [[Double]]? {
        let n = a.count
        guard n > 0, b.count == n, let m = b.first?.count else { return nil }
        var A = a
        var B = b
        for col in 0..<n {
            var pivot = col
            var best = abs(A[col][col])
            for r in (col + 1)..<n where abs(A[r][col]) > best {
                best = abs(A[r][col])
                pivot = r
            }
            guard best > 1e-12 else { return nil }
            if pivot != col {
                A.swapAt(pivot, col)
                B.swapAt(pivot, col)
            }
            let d = A[col][col]
            for r in 0..<n where r != col {
                let f = A[r][col] / d
                if f == 0 { continue }
                for c in col..<n { A[r][c] -= f * A[col][c] }
                for c in 0..<m { B[r][c] -= f * B[col][c] }
            }
        }
        for r in 0..<n {
            let d = A[r][r]
            for c in 0..<m { B[r][c] /= d }
        }
        return B
    }

    static func inverse(_ a: [[Double]]) -> [[Double]]? {
        solve(a, identity(a.count))
    }

    static func dot(_ a: [Double], _ b: [Double]) -> Double {
        var s = 0.0
        for i in a.indices { s += a[i] * b[i] }
        return s
    }

    static func mul(_ m: [[Double]], _ v: [Double]) -> [Double] {
        m.map { dot($0, v) }
    }

    static func sub(_ a: [Double], _ b: [Double]) -> [Double] {
        zip(a, b).map { $0 - $1 }
    }
}

/// Rescales each feature to mean 0, spread 1 so no single unit (radians vs. fractions) dominates.
public struct Standardizer: Codable, Equatable, Sendable {
    public var mean: [Double]
    public var scale: [Double]

    public static func fit(_ rows: [[Double]], weights: [Double]? = nil) -> Standardizer {
        let d = rows.first?.count ?? 0
        var mean = [Double](repeating: 0, count: d)
        var total = 0.0
        for (i, r) in rows.enumerated() {
            let w = weights?[i] ?? 1
            total += w
            for j in 0..<d { mean[j] += w * r[j] }
        }
        if total > 0 { mean = mean.map { $0 / total } }
        var variance = [Double](repeating: 0, count: d)
        for (i, r) in rows.enumerated() {
            let w = weights?[i] ?? 1
            for j in 0..<d {
                let e = r[j] - mean[j]
                variance[j] += w * e * e
            }
        }
        // A feature that never varies (e.g. a measurement the camera can't provide) is left unscaled,
        // so it contributes zeros instead of blowing up.
        let scale = variance.map { v -> Double in
            let sd = total > 0 ? sqrt(v / total) : 0
            return sd < 1e-6 ? 1 : sd
        }
        return Standardizer(mean: mean, scale: scale)
    }

    public func apply(_ x: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: x.count)
        for i in x.indices { out[i] = (x[i] - mean[i]) / scale[i] }
        return out
    }
}

/// Linear least squares with a small penalty that keeps weights sane when data is thin.
public struct RidgeRegression: Codable, Equatable, Sendable {
    public var standardizer: Standardizer
    /// One row per output; the last entry of each row is the intercept.
    public var coefficients: [[Double]]

    /// `lambda` is relative to the total sample weight, so it means the same thing for 50 or 5,000 samples.
    public static func fit(
        x: [[Double]], y: [[Double]], weights: [Double]? = nil, lambda: Double = 0.01
    ) -> RidgeRegression? {
        guard let d = x.first?.count, x.count == y.count, let k = y.first?.count else { return nil }
        let std = Standardizer.fit(x, weights: weights)
        let p = d + 1
        var xtx = [[Double]](repeating: [Double](repeating: 0, count: p), count: p)
        var xty = [[Double]](repeating: [Double](repeating: 0, count: k), count: p)
        var total = 0.0
        for i in x.indices {
            let w = weights?[i] ?? 1
            total += w
            let z = std.apply(x[i]) + [1]
            for a in 0..<p {
                let wa = w * z[a]
                for b in 0..<p { xtx[a][b] += wa * z[b] }
                for o in 0..<k { xty[a][o] += wa * y[i][o] }
            }
        }
        // Penalise the feature weights, never the intercept.
        for a in 0..<d { xtx[a][a] += lambda * total }
        guard let beta = Matrix.solve(xtx, xty) else { return nil }
        let coefficients = (0..<k).map { o in (0..<p).map { beta[$0][o] } }
        return RidgeRegression(standardizer: std, coefficients: coefficients)
    }

    public func predict(_ x: [Double]) -> [Double] {
        let z = standardizer.apply(x) + [1]
        return coefficients.map { Matrix.dot($0, z) }
    }
}
