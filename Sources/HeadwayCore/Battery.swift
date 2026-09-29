import Foundation

/// Decides how many camera frames to analyse. The camera can't run slower than 15 fps, so savings come
/// from analysing fewer of its frames: every 2nd normally (7.5 a second), every 3rd once head and eyes have
/// been still for a while (5 a second), and every frame again the moment anything moves.
public struct FrameGovernor: Sendable {
    /// Seconds without movement before slowing down further.
    public var stillAfter = 2.0
    /// Changes between analysed frames larger than these count as movement (≈ 4× the measured jitter).
    public static let thresholds = (yaw: 0.035, pitch: 0.035, noseX: 0.012, noseY: 0.02, eyeX: 0.03, eyeY: 0.03)

    private var last: FaceSample?
    private var lastMove = -Double.infinity

    public init() {}

    /// Feed each analysed (smoothed) sample, nil when no face was found.
    /// - Returns: analyse every n-th camera frame.
    public mutating func everyNth(after sample: FaceSample?, saver: Bool) -> Int {
        guard saver else { return 1 }
        guard let s = sample else { return 3 }  // nobody there: look less often
        if let p = last, moved(p, s) { lastMove = s.t }
        if last == nil { lastMove = s.t }  // a face just appeared
        last = s
        return s.t - lastMove >= stillAfter ? 3 : 2
    }

    private func moved(_ a: FaceSample, _ b: FaceSample) -> Bool {
        let t = Self.thresholds
        return abs(a.yaw - b.yaw) > t.yaw || abs(a.pitch - b.pitch) > t.pitch || abs(a.noseX - b.noseX) > t.noseX
            || abs(a.noseY - b.noseY) > t.noseY || abs(a.eyeX - b.eyeX) > t.eyeX || abs(a.eyeY - b.eyeY) > t.eyeY
    }
}

/// "Pause when idle": the camera goes off after this long with no keyboard or mouse.
public enum IdlePause {
    public static let after = 300.0

    public static func shouldRest(sinceKey: Double, sinceMouse: Double, enabled: Bool) -> Bool {
        enabled && min(sinceKey, sinceMouse) >= after
    }
}
