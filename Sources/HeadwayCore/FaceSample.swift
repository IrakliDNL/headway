import Foundation

/// One camera frame's worth of face measurements. Numbers only — no image data is ever kept.
public struct FaceSample: Codable, Equatable, Sendable {
    /// Seconds on a monotonic clock.
    public var t: Double
    /// Head rotation from Apple Vision, in radians.
    public var yaw: Double
    public var pitch: Double
    public var roll: Double
    /// Face box centre in the camera image, 0…1.
    public var faceX: Double
    public var faceY: Double
    /// Face box width as a fraction of the image width. Bigger means closer to the camera.
    public var faceW: Double
    /// Nose offset from the midpoint of the jaw line, as a fraction of face width. Moves with head turn.
    public var noseX: Double
    /// Nose height between the eye line (0) and the chin (1). Moves with head tilt.
    public var noseY: Double
    /// Pupil offset inside the eye outline, as a fraction of eye width. Moves with eye direction.
    public var eyeX: Double
    public var eyeY: Double
    public var confidence: Double

    public init(
        t: Double, yaw: Double = 0, pitch: Double = 0, roll: Double = 0,
        faceX: Double = 0.5, faceY: Double = 0.5, faceW: Double = 0.25,
        noseX: Double = 0, noseY: Double = 0.5, eyeX: Double = 0, eyeY: Double = 0,
        confidence: Double = 1
    ) {
        self.t = t
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
        self.faceX = faceX
        self.faceY = faceY
        self.faceW = faceW
        self.noseX = noseX
        self.noseY = noseY
        self.eyeX = eyeX
        self.eyeY = eyeY
        self.confidence = confidence
    }
}

/// Which measurements feed which model.
public enum Features {
    /// Where the head (and eyes) point. Chooses the screen.
    public static func head(_ s: FaceSample) -> [Double] {
        [s.yaw, s.pitch, s.noseX, s.noseY, s.eyeX, s.eyeY]
    }

    /// Everything, including where the face sits and how close it is. Places the point on a screen.
    public static func full(_ s: FaceSample) -> [Double] {
        [s.yaw, s.pitch, s.noseX, s.noseY, s.eyeX, s.eyeY, s.faceX, s.faceY, s.faceW]
    }
}

/// Smooths the jitter out of successive samples without adding much lag when the head moves fast.
public struct SampleSmoother {
    private var filters: [OneEuroFilter]
    private var lastT: Double?
    public var minCutoff: Double
    public var beta: Double

    public init(minCutoff: Double = 1.5, beta: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        filters = []
    }

    public mutating func reset() {
        filters = []
        lastT = nil
    }

    public mutating func smooth(_ s: FaceSample) -> FaceSample {
        // After a gap (face lost, camera paused) start fresh rather than dragging old values along.
        if let last = lastT, s.t - last > 0.5 { reset() }
        lastT = s.t
        let raw = [s.yaw, s.pitch, s.roll, s.faceX, s.faceY, s.faceW, s.noseX, s.noseY, s.eyeX, s.eyeY]
        if filters.count != raw.count {
            filters = raw.map { _ in OneEuroFilter(minCutoff: minCutoff, beta: beta) }
        }
        var out = [Double]()
        out.reserveCapacity(raw.count)
        for i in raw.indices { out.append(filters[i].filter(raw[i], t: s.t)) }
        return FaceSample(
            t: s.t, yaw: out[0], pitch: out[1], roll: out[2], faceX: out[3], faceY: out[4], faceW: out[5],
            noseX: out[6], noseY: out[7], eyeX: out[8], eyeY: out[9], confidence: s.confidence
        )
    }
}

/// The 1€ filter (Casiez et al.): heavy smoothing when still, light smoothing when moving.
public struct OneEuroFilter {
    public var minCutoff: Double
    public var beta: Double
    public var dCutoff: Double
    private var x: Double?
    private var dx: Double = 0
    private var lastT: Double?

    public init(minCutoff: Double = 1.5, beta: Double = 1.0, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    public mutating func filter(_ value: Double, t: Double) -> Double {
        guard let prev = x, let lt = lastT, t > lt else {
            x = value
            lastT = t
            return value
        }
        let dt = t - lt
        let aD = Self.alpha(dt: dt, cutoff: dCutoff)
        dx = aD * ((value - prev) / dt) + (1 - aD) * dx
        let a = Self.alpha(dt: dt, cutoff: minCutoff + beta * abs(dx))
        let v = a * value + (1 - a) * prev
        x = v
        lastT = t
        return v
    }

    private static func alpha(dt: Double, cutoff: Double) -> Double {
        let tau = 1 / (2 * Double.pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}
