import CoreGraphics
import Foundation

/// A screen as Headway sees it. Frames are in global display coordinates: origin at the top-left of the
/// main display, y growing downwards (the convention of CGWindowList and Accessibility).
public struct ScreenGeometry: Codable, Equatable, Sendable {
    /// Stable identity across reconnects (vendor/model/serial), not the transient display ID.
    public var key: String
    public var name: String
    public var frame: CGRect

    public init(key: String, name: String, frame: CGRect) {
        self.key = key
        self.name = name
        self.frame = frame
    }

    public func point(u: Double, v: Double) -> CGPoint {
        CGPoint(x: frame.minX + u * frame.width, y: frame.minY + v * frame.height)
    }
}

/// One labelled example: "when the face looked like this, the person was looking here".
public struct TrainingSample: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case calibration, click }
    public var face: FaceSample
    public var screen: String
    /// Position on that screen, 0…1 from the left and from the top.
    public var u: Double
    public var v: Double
    public var source: Source
    public var date: Date

    public init(face: FaceSample, screen: String, u: Double, v: Double, source: Source, date: Date = Date()) {
        self.face = face
        self.screen = screen
        self.u = u
        self.v = v
        self.source = source
        self.date = date
    }

    /// Clicks are fewer but more recent and taken in real working posture, so each counts double.
    var weight: Double { source == .click ? 2 : 1 }
}

// MARK: - Choosing the screen

public enum FacingChoice: Equatable, Sendable {
    case screen(String)
    /// The head points well away from every screen (phone, desk, window). Changes nothing.
    case ignored
}

/// Separates screens by head pose. Each screen is a cloud of calibration samples; the axis between two
/// clouds is weighted by how well each feature separates them relative to its noise (linear discriminant).
/// "Progress" along that axis is 0 at the current screen's centre and 1 at the other screen's centre,
/// with 0.5 placed at the physical gap between the screens (found from the calibration dots nearest
/// that gap), so the "head turn needed" setting of 50% means "at the bezel" even for unequal screens.
public struct HeadModel: Codable, Equatable, Sendable {
    public var standardizer: Standardizer
    public var keys: [String]
    public var means: [[Double]]
    /// Inverse of the pooled within-screen covariance.
    public var precision: [[Double]]
    /// Per screen: how far (in the same metric) its own samples typically sit from its centre.
    public var radius: [Double]
    /// bezels[i][j]: where the gap between screens i and j sits on the raw i→j axis (0.5 if unknown).
    public var bezels: [[Double]] = []

    public static func fit(_ samples: [TrainingSample], shrinkage: Double = 0.15) -> HeadModel? {
        let keys = Array(Set(samples.map(\.screen))).sorted()
        guard !keys.isEmpty else { return nil }
        let rows = samples.map { Features.head($0.face) }
        let weights = samples.map(\.weight)
        let std = Standardizer.fit(rows, weights: weights)
        let z = rows.map(std.apply)
        let d = z.first?.count ?? 0

        var means = [[Double]]()
        for key in keys {
            var m = [Double](repeating: 0, count: d)
            var total = 0.0
            for i in samples.indices where samples[i].screen == key {
                total += weights[i]
                for j in 0..<d { m[j] += weights[i] * z[i][j] }
            }
            guard total > 0 else { return nil }
            means.append(m.map { $0 / total })
        }

        var cov = [[Double]](repeating: [Double](repeating: 0, count: d), count: d)
        var total = 0.0
        for i in samples.indices {
            let k = keys.firstIndex(of: samples[i].screen)!
            let e = Matrix.sub(z[i], means[k])
            total += weights[i]
            for a in 0..<d { for b in 0..<d { cov[a][b] += weights[i] * e[a] * e[b] } }
        }
        let avgDiag = (0..<d).reduce(0.0) { $0 + cov[$1][$1] } / max(total, 1) / Double(max(d, 1))
        for a in 0..<d {
            for b in 0..<d {
                cov[a][b] = (1 - shrinkage) * cov[a][b] / max(total, 1)
            }
            cov[a][a] += shrinkage * max(avgDiag, 1e-3) + 1e-6
        }
        guard let precision = Matrix.inverse(cov) else { return nil }

        var model = HeadModel(standardizer: std, keys: keys, means: means, precision: precision, radius: [])
        model.radius = keys.indices.map { k in
            let own = samples.indices.filter { samples[$0].screen == keys[k] }.map { model.distance(z[$0], to: k) }
            return max(percentile(own, 0.9), 0.5)
        }
        model.bezels = model.findBezels(samples, z)
        return model
    }

    /// For each pair of screens: the three calibration dots of each screen nearest the other screen form
    /// its inner edge; the gap sits half way between the two edges.
    private func findBezels(_ samples: [TrainingSample], _ z: [[Double]]) -> [[Double]] {
        let n = keys.count
        var out = [[Double]](repeating: [Double](repeating: 0.5, count: n), count: n)
        struct SpotKey: Hashable { let u: Double, v: Double }
        for i in 0..<n {
            for j in (i + 1)..<n {
                func edge(_ k: Int, nearest: (Double, Double) -> Bool) -> Double? {
                    var sums = [SpotKey: (Double, Int)]()
                    for s in samples.indices where samples[s].screen == keys[k] && samples[s].source == .calibration {
                        let key = SpotKey(u: samples[s].u, v: samples[s].v)
                        let t = rawProgress(z[s], from: i, to: j)
                        sums[key, default: (0, 0)].0 += t
                        sums[key, default: (0, 0)].1 += 1
                    }
                    let spots = sums.values.map { $0.0 / Double($0.1) }.sorted(by: nearest)
                    guard spots.count >= 3 else { return nil }
                    return spots.prefix(3).reduce(0, +) / 3
                }
                guard let iEdge = edge(i, nearest: >), let jEdge = edge(j, nearest: <) else { continue }
                let bezel = min(max((iEdge + jEdge) / 2, 0.25), 0.75)
                out[i][j] = bezel
                out[j][i] = 1 - bezel
            }
        }
        return out
    }

    func distance(_ z: [Double], to k: Int) -> Double {
        let e = Matrix.sub(z, means[k])
        return sqrt(max(Matrix.dot(e, Matrix.mul(precision, e)), 0))
    }

    /// 0 at screen `a`'s centre, 1 at screen `b`'s centre.
    func rawProgress(_ z: [Double], from a: Int, to b: Int) -> Double {
        let diff = Matrix.sub(means[b], means[a])
        let w = Matrix.mul(precision, diff)
        let span = Matrix.dot(w, diff)
        guard span > 1e-9 else { return 0 }
        return Matrix.dot(w, Matrix.sub(z, means[a])) / span
    }

    /// Like `rawProgress`, but stretched so 0.5 falls on the gap between the screens.
    func progress(_ z: [Double], from a: Int, to b: Int) -> Double {
        let t = rawProgress(z, from: a, to: b)
        let bezel = bezels.isEmpty ? 0.5 : bezels[a][b]
        return t <= bezel ? t / bezel * 0.5 : 0.5 + (t - bezel) / (1 - bezel) * 0.5
    }

    /// How clearly two screens are told apart: distance between their centres in units of noise.
    /// Below ~3 switching will be unreliable.
    public func separation(_ a: String, _ b: String) -> Double? {
        guard let i = keys.firstIndex(of: a), let j = keys.firstIndex(of: b) else { return nil }
        let diff = Matrix.sub(means[j], means[i])
        return sqrt(max(Matrix.dot(diff, Matrix.mul(precision, diff)), 0))
    }

    public struct Reading: Equatable, Sendable {
        public var choice: FacingChoice
        /// The screen whose centre is nearest, whatever the hysteresis says.
        public var nearest: String
        /// Progress towards the most likely other screen (nil with one screen).
        public var progress: Double?
        /// Distance from the nearest screen in multiples of its normal spread. Above `farLimit` = ignored.
        public var farness: Double
    }

    /// - Parameters:
    ///   - current: the screen currently being faced (hysteresis is measured from it).
    ///   - threshold: fraction of the way to another screen the head must turn (the "head turn needed" setting).
    ///   - hysteresis: extra turn needed on top, so the boundary doesn't flicker.
    public func read(_ face: FaceSample, current: String?, threshold: Double, hysteresis: Double, farLimit: Double) -> Reading {
        let z = standardizer.apply(Features.head(face))
        let rel = keys.indices.map { distance(z, to: $0) / radius[$0] }
        let nearest = rel.indices.min { rel[$0] < rel[$1] }!
        let farness = rel[nearest]

        guard let cur = current, let ci = keys.firstIndex(of: cur) else {
            return Reading(choice: farness > farLimit ? .ignored : .screen(keys[nearest]),
                           nearest: keys[nearest], progress: nil, farness: farness)
        }
        var best: (index: Int, t: Double)?
        for b in keys.indices where b != ci {
            let t = progress(z, from: ci, to: b)
            if best == nil || t > best!.t { best = (b, t) }
        }
        if farness > farLimit {
            return Reading(choice: .ignored, nearest: keys[nearest], progress: best?.t, farness: farness)
        }
        if let best, best.t >= threshold + hysteresis {
            return Reading(choice: .screen(keys[best.index]), nearest: keys[nearest], progress: best.t, farness: farness)
        }
        return Reading(choice: .screen(cur), nearest: keys[nearest], progress: best?.t, farness: farness)
    }
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let s = values.sorted()
    let i = min(s.count - 1, max(0, Int((Double(s.count - 1) * p).rounded())))
    return s[i]
}

// MARK: - The whole model

public struct GazeReading: Equatable, Sendable {
    public var choice: FacingChoice
    public var nearest: String
    public var progress: Double?
    public var farness: Double
    /// Estimated point being looked at, in global coordinates. Nil when the pose is ignored.
    public var point: CGPoint?
}

/// Head model for choosing the screen + one regression per screen for the point on it.
public struct GazeModel: Sendable {
    public let head: HeadModel
    public let within: [String: RidgeRegression]
    public let screens: [ScreenGeometry]

    /// How far from every screen (in multiples of normal spread) a pose must be to be ignored.
    public static let farLimit = 2.2

    public init?(samples: [TrainingSample], screens: [ScreenGeometry]) {
        let known = Set(screens.map(\.key))
        let usable = samples.filter { known.contains($0.screen) }
        guard let head = HeadModel.fit(usable) else { return nil }
        var within = [String: RidgeRegression]()
        for key in head.keys {
            let own = usable.filter { $0.screen == key }
            if let r = RidgeRegression.fit(
                x: own.map { Features.full($0.face) }, y: own.map { [$0.u, $0.v] },
                weights: own.map(\.weight), lambda: 0.02
            ) {
                within[key] = r
            }
        }
        self.head = head
        self.within = within
        self.screens = screens.filter { head.keys.contains($0.key) }
    }

    /// Share of calibration samples that land on the right side of the 50% boundary against every
    /// other screen — a plain-language "how well can Headway tell your screens apart".
    public func agreement(_ samples: [TrainingSample]) -> Double? {
        guard head.keys.count > 1 else { return nil }
        var right = 0, total = 0
        for s in samples where s.source == .calibration {
            guard let a = head.keys.firstIndex(of: s.screen) else { continue }
            let z = head.standardizer.apply(Features.head(s.face))
            for b in head.keys.indices where b != a {
                total += 1
                if head.progress(z, from: a, to: b) < 0.5 { right += 1 }
            }
        }
        return total == 0 ? nil : Double(right) / Double(total)
    }

    public func read(_ face: FaceSample, current: String?, threshold: Double, hysteresis: Double) -> GazeReading {
        let r = head.read(face, current: current, threshold: threshold, hysteresis: hysteresis, farLimit: Self.farLimit)
        var point: CGPoint?
        if case .screen(let key) = r.choice, let screen = screens.first(where: { $0.key == key }),
           let model = within[key] {
            let uv = model.predict(Features.full(face))
            // Let the estimate run a little past the edges, but not wildly.
            let u = min(max(uv[0], -0.05), 1.05)
            let v = min(max(uv[1], -0.05), 1.05)
            point = screen.point(u: u, v: v)
        }
        return GazeReading(choice: r.choice, nearest: r.nearest, progress: r.progress, farness: r.farness, point: point)
    }
}
