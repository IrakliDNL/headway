import CoreGraphics

/// Finds the iris centre inside an eye outline in a grayscale (luma) image: the weighted centroid of the
/// darkest pixels within the eye opening. Sharper than Vision's pupil landmark, which moves too little
/// when only the eyes move. Works on numbers in memory only.
public enum Pupil {
    /// Share of the eye opening treated as iris. The iris usually covers 30–45% of the visible eye.
    public static let darkShare = 0.3

    /// - Parameters:
    ///   - base: first byte of the luma plane; row `y` starts at `base + y * bytesPerRow`.
    ///   - outline: the eye opening in pixel coordinates, origin top-left.
    /// - Returns: the iris centre in the same coordinates, or nil when the eye is closed or too small.
    public static func locate(in base: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int,
                              outline: [CGPoint]) -> CGPoint? {
        guard outline.count >= 3 else { return nil }
        let xs = outline.map(\.x), ys = outline.map(\.y)
        let minX = max(0, Int(xs.min()!.rounded(.down))), maxX = min(width - 1, Int(xs.max()!.rounded(.up)))
        let minY = max(0, Int(ys.min()!.rounded(.down))), maxY = min(height - 1, Int(ys.max()!.rounded(.up)))
        // A blink or a face too far away leaves nothing to measure.
        guard maxX - minX >= 8, maxY - minY >= 3 else { return nil }

        var pixels = [(x: Int, y: Int, luma: UInt8)]()
        pixels.reserveCapacity((maxX - minX + 1) * (maxY - minY + 1))
        for y in minY...maxY {
            let row = base + y * bytesPerRow
            for x in minX...maxX where contains(outline, CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
                pixels.append((x, y, row[x]))
            }
        }
        guard pixels.count >= 20 else { return nil }
        let sorted = pixels.map(\.luma).sorted()
        let threshold = Double(sorted[Int(Double(sorted.count - 1) * darkShare)])
        let dark = pixels.filter { Double($0.luma) <= threshold }

        func centroid(near centre: CGPoint?, radius: Double) -> CGPoint? {
            var sx = 0.0, sy = 0.0, sw = 0.0
            for p in dark {
                let x = Double(p.x) + 0.5, y = Double(p.y) + 0.5
                if let c = centre, hypot(x - c.x, y - c.y) > radius { continue }
                // Darker counts more, so the pupil pulls harder than the iris edge.
                let w = threshold - Double(p.luma) + 1
                sx += w * x
                sy += w * y
                sw += w
            }
            return sw > 0 ? CGPoint(x: sx / sw, y: sy / sw) : nil
        }
        // Start from all dark pixels, then close in on the compact dark blob (the iris) so that dark
        // lashes or shadow spread along the lids stop pulling the answer towards the middle.
        guard var c = centroid(near: nil, radius: 0) else { return nil }
        let radius = Double(maxX - minX) * 0.2
        for _ in 0..<4 {
            guard let next = centroid(near: c, radius: radius) else { break }
            c = next
        }
        return c
    }

    /// Even-odd ray casting.
    static func contains(_ polygon: [CGPoint], _ p: CGPoint) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}
