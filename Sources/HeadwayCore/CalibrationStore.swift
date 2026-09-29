import Foundation

/// Everything Headway has learned: the calibration dots plus a rolling window of clicks.
/// Saved as JSON. Holds numbers about face pose only — never images.
public struct CalibrationStore: Codable, Equatable, Sendable {
    public var version = 1
    /// Screens as they were when calibrated, to notice when the arrangement changes.
    public var screens: [ScreenGeometry] = []
    public var samples: [TrainingSample] = []
    public var clicks: [TrainingSample] = []
    public var calibratedAt: Date?

    /// Newest clicks kept per screen.
    public static let clickCap = 300

    public init() {}

    public var allSamples: [TrainingSample] { samples + clicks }

    public func isCalibrated(_ screen: String) -> Bool {
        samples.contains { $0.screen == screen }
    }

    /// Replaces one screen's calibration (and forgets clicks on it, which belonged to the old setup).
    public mutating func replaceCalibration(_ screen: ScreenGeometry, with new: [TrainingSample]) {
        samples.removeAll { $0.screen == screen.key }
        clicks.removeAll { $0.screen == screen.key }
        samples.append(contentsOf: new)
        screens.removeAll { $0.key == screen.key }
        screens.append(screen)
        calibratedAt = Date()
    }

    public mutating func addClick(_ sample: TrainingSample) {
        clicks.append(sample)
        let onScreen = clicks.indices.filter { clicks[$0].screen == sample.screen }
        if onScreen.count > Self.clickCap {
            let drop = Set(onScreen.prefix(onScreen.count - Self.clickCap))
            clicks = clicks.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
        }
    }

    public mutating func forgetClicks() {
        clicks.removeAll()
    }

    /// Screens that are connected now but have moved or resized since calibration.
    public func movedScreens(current: [ScreenGeometry]) -> [String] {
        current.compactMap { now in
            guard let then = screens.first(where: { $0.key == now.key }) else { return nil }
            return then.frame == now.frame ? nil : now.key
        }
    }
}

/// Watches whether the screen you click on is the screen Headway thought you were facing.
/// When it keeps getting it wrong, the setup has probably changed and a recalibration is due.
public struct AccuracyTracker: Sendable {
    public var window = 40
    public var minimum = 20
    public var threshold = 0.7
    private var hits: [Bool] = []

    public init() {}

    public mutating func record(predicted: String?, actual: String) {
        hits.append(predicted == actual)
        if hits.count > window { hits.removeFirst(hits.count - window) }
    }

    public mutating func reset() {
        hits.removeAll()
    }

    public var accuracy: Double? {
        hits.count < minimum ? nil : Double(hits.filter { $0 }.count) / Double(hits.count)
    }

    public var suggestsRecalibration: Bool {
        guard let a = accuracy else { return false }
        return a < threshold
    }
}
