import CoreGraphics
import XCTest
@testable import HeadwayCore

// MARK: - Synthetic world: a laptop on the left, a monitor on the right.

let laptop = ScreenGeometry(key: "laptop", name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1470, height: 956))
let monitor = ScreenGeometry(key: "monitor", name: "DELL", frame: CGRect(x: 1470, y: -100, width: 1920, height: 1080))

/// Deterministic noise so tests never flake.
struct Noise {
    var state: UInt64 = 0x9E3779B97F4A7C15
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53) * 2 - 1
    }
}

/// A face looking at (u, v) on a screen. The monitor sits ~35° to the right; eyes do a bit of the work.
func face(_ screen: ScreenGeometry, u: Double, v: Double, t: Double = 0, noise: inout Noise, jitter: Double = 0.02) -> FaceSample {
    let centreYaw = screen.key == "laptop" ? -0.05 : 0.55
    let width = screen.key == "laptop" ? 0.35 : 0.45
    let yaw = centreYaw + (u - 0.5) * width + noise.next() * jitter
    let pitch = -0.15 + (v - 0.5) * 0.3 + noise.next() * jitter
    return FaceSample(
        t: t, yaw: yaw, pitch: pitch, roll: 0, faceX: 0.5, faceY: 0.5, faceW: 0.3,
        noseX: yaw * 0.25 + noise.next() * jitter * 0.3, noseY: 0.5 + pitch * 0.2,
        eyeX: (u - 0.5) * 0.1 + noise.next() * 0.05, eyeY: (v - 0.5) * 0.08 + noise.next() * 0.05
    )
}

func calibration(_ screens: [ScreenGeometry]) -> [TrainingSample] {
    var noise = Noise()
    var out = [TrainingSample]()
    let spots = [0.06, 0.5, 0.94]
    for s in screens {
        for v in spots {
            for u in spots {
                for _ in 0..<15 {
                    out.append(TrainingSample(face: face(s, u: u, v: v, noise: &noise), screen: s.key, u: u, v: v, source: .calibration))
                }
            }
        }
    }
    return out
}

final class LinearAlgebraTests: XCTestCase {
    func testRidgeRecoversLinearFunction() {
        var noise = Noise()
        var x = [[Double]]()
        var y = [[Double]]()
        for _ in 0..<200 {
            let a = noise.next(), b = noise.next() * 3
            x.append([a, b])
            y.append([2 * a - 0.5 * b + 1])
        }
        let model = RidgeRegression.fit(x: x, y: y, lambda: 0)!
        XCTAssertEqual(model.predict([0.3, -1])[0], 2 * 0.3 + 0.5 + 1, accuracy: 1e-6)
    }

    func testSolveRejectsSingularMatrix() {
        XCTAssertNil(Matrix.solve([[1, 2], [2, 4]], [[1], [2]]))
    }

    func testConstantFeatureDoesNotBlowUp() {
        let std = Standardizer.fit([[1, 5], [2, 5], [3, 5]])
        XCTAssertEqual(std.apply([2, 5.001])[1], 0.001, accuracy: 1e-9)
    }
}

final class HeadModelTests: XCTestCase {
    let model = GazeModel(samples: calibration([laptop, monitor]), screens: [laptop, monitor])!

    func testScreensAreWellSeparated() {
        XCTAssertGreaterThan(model.head.separation("laptop", "monitor")!, 3)
    }

    func testCentresReadAsThemselves() {
        var n = Noise()
        XCTAssertEqual(model.read(face(laptop, u: 0.5, v: 0.5, noise: &n), current: "monitor", threshold: 0.5, hysteresis: 0.06).choice, .screen("laptop"))
        XCTAssertEqual(model.read(face(monitor, u: 0.5, v: 0.5, noise: &n), current: "laptop", threshold: 0.5, hysteresis: 0.06).choice, .screen("monitor"))
    }

    func testProgressIsZeroToOneBetweenCentres() {
        var n = Noise()
        let atLaptop = model.read(face(laptop, u: 0.5, v: 0.5, noise: &n, jitter: 0), current: "laptop", threshold: 0.5, hysteresis: 0.06)
        let atMonitor = model.read(face(monitor, u: 0.5, v: 0.5, noise: &n, jitter: 0), current: "laptop", threshold: 0.5, hysteresis: 0.06)
        XCTAssertEqual(atLaptop.progress!, 0, accuracy: 0.15)
        XCTAssertEqual(atMonitor.progress!, 1, accuracy: 0.15)
    }

    func testBoundaryHasHysteresis() {
        // A pose exactly half way between the screens stays with whichever screen you were already facing.
        var n = Noise()
        var mid = face(laptop, u: 0.5, v: 0.5, noise: &n, jitter: 0)
        let other = face(monitor, u: 0.5, v: 0.5, noise: &n, jitter: 0)
        mid.yaw = (mid.yaw + other.yaw) / 2
        mid.noseX = (mid.noseX + other.noseX) / 2
        mid.eyeX = (mid.eyeX + other.eyeX) / 2
        XCTAssertEqual(model.read(mid, current: "laptop", threshold: 0.5, hysteresis: 0.06).choice, .screen("laptop"))
        XCTAssertEqual(model.read(mid, current: "monitor", threshold: 0.5, hysteresis: 0.06).choice, .screen("monitor"))
    }

    func testHeadTurnSettingMovesTheBoundary() {
        var n = Noise()
        var pose = face(laptop, u: 0.5, v: 0.5, noise: &n, jitter: 0)
        let other = face(monitor, u: 0.5, v: 0.5, noise: &n, jitter: 0)
        // 40% of the way to the monitor.
        pose.yaw += (other.yaw - pose.yaw) * 0.4
        pose.noseX += (other.noseX - pose.noseX) * 0.4
        pose.eyeX += (other.eyeX - pose.eyeX) * 0.4
        XCTAssertEqual(model.read(pose, current: "laptop", threshold: 0.5, hysteresis: 0.06).choice, .screen("laptop"))
        XCTAssertEqual(model.read(pose, current: "laptop", threshold: 0.25, hysteresis: 0.06).choice, .screen("monitor"))
    }

    func testLookingDownAtPhoneIsIgnored() {
        var n = Noise()
        var phone = face(laptop, u: 0.5, v: 0.5, noise: &n, jitter: 0)
        phone.pitch = -0.9
        phone.noseY = 0.5 + phone.pitch * 0.2
        XCTAssertEqual(model.read(phone, current: "laptop", threshold: 0.5, hysteresis: 0.06).choice, .ignored)
    }

    func testPointLandsOnTheRightPartOfTheScreen() {
        var n = Noise()
        let r = model.read(face(monitor, u: 0.8, v: 0.2, noise: &n, jitter: 0), current: "monitor", threshold: 0.5, hysteresis: 0.06)
        let p = r.point!
        XCTAssertEqual(p.x, monitor.point(u: 0.8, v: 0.2).x, accuracy: monitor.frame.width * 0.08)
        XCTAssertEqual(p.y, monitor.point(u: 0.8, v: 0.2).y, accuracy: monitor.frame.height * 0.08)
    }

    func testSingleScreenWorks() {
        let solo = GazeModel(samples: calibration([laptop]), screens: [laptop])!
        var n = Noise()
        let r = solo.read(face(laptop, u: 0.2, v: 0.5, noise: &n), current: "laptop", threshold: 0.5, hysteresis: 0.06)
        XCTAssertEqual(r.choice, .screen("laptop"))
        XCTAssertNil(r.progress)
        XCTAssertNotNil(r.point)
    }

    func testDisconnectedScreenIsLeftOut() {
        let m = GazeModel(samples: calibration([laptop, monitor]), screens: [laptop])!
        XCTAssertEqual(m.head.keys, ["laptop"])
    }
}

// MARK: - The engine

func reading(_ key: String, point: CGPoint? = nil) -> GazeReading {
    GazeReading(choice: .screen(key), nearest: key, progress: nil, farness: 0.5, point: point)
}

let ignored = GazeReading(choice: .ignored, nearest: "laptop", progress: nil, farness: 5, point: nil)

final class FocusEngineTests: XCTestCase {
    /// Feeds the same reading at 15 fps for `seconds` and returns the actions produced.
    func run(_ e: FocusEngine, _ r: GazeReading?, from t0: Double, for seconds: Double, focus: String,
             focusTarget: String? = nil, targets: [HitTarget] = [], sinceKey: (Double) -> Double = { _ in 100 },
             sinceMouse: (Double) -> Double = { _ in 100 }) -> [(Double, EngineAction)] {
        var out = [(Double, EngineAction)]()
        var t = t0
        while t < t0 + seconds - 1e-9 {
            let tick = EngineTick(t: t, reading: r, sinceKey: sinceKey(t), sinceMouse: sinceMouse(t),
                                  focusScreen: focus, focusTarget: focusTarget, targets: targets)
            if let a = e.step(tick) { out.append((t, a)) }
            t += 1.0 / 15
        }
        return out
    }

    func testQuickGlanceIsIgnored() {
        let e = FocusEngine()
        _ = run(e, reading("laptop"), from: 0, for: 1, focus: "laptop")
        XCTAssertTrue(run(e, reading("monitor"), from: 1, for: 0.2, focus: "laptop").isEmpty)
        XCTAssertTrue(run(e, reading("laptop"), from: 1.2, for: 1, focus: "laptop").isEmpty)
        XCTAssertEqual(e.facedScreen, "laptop")
    }

    func testTurningSwitchesAfterTheDelay() {
        let e = FocusEngine()
        _ = run(e, reading("laptop"), from: 0, for: 1, focus: "laptop")
        let acts = run(e, reading("monitor"), from: 1, for: 1, focus: "laptop")
        XCTAssertEqual(acts.count, 1)
        XCTAssertEqual(acts[0].1, .switchScreen("monitor"))
        XCTAssertEqual(acts[0].0 - 1, 0.3, accuracy: 0.07)
    }

    func testTypingDelaysScreenSwitchToAboutASecond() {
        let e = FocusEngine()
        _ = run(e, reading("laptop"), from: 0, for: 1, focus: "laptop")
        let acts = run(e, reading("monitor"), from: 1, for: 2, focus: "laptop", sinceKey: { $0 - 1 })
        XCTAssertEqual(acts.count, 1)
        XCTAssertEqual(acts[0].0 - 1, 1.0, accuracy: 0.07)
    }

    func testMouseUseHoldsTheSwitchUntilQuiet() {
        let e = FocusEngine()
        _ = run(e, reading("laptop"), from: 0, for: 1, focus: "laptop")
        // Mouse in use until t = 2, so nothing may happen before 3.5.
        let acts = run(e, reading("monitor"), from: 1, for: 3, focus: "laptop", sinceMouse: { max(0, $0 - 2) })
        XCTAssertEqual(acts.count, 1)
        XCTAssertGreaterThanOrEqual(acts[0].0, 3.5 - 1e-6)
    }

    func testClickingElsewhereCancelsThePendingSwitch() {
        let e = FocusEngine()
        _ = run(e, reading("laptop"), from: 0, for: 1, focus: "laptop")
        // Turn to the monitor while using the mouse; the user then clicks back on the laptop's other window.
        _ = run(e, reading("monitor"), from: 1, for: 0.6, focus: "laptop", sinceMouse: { _ in 0 })
        let acts = run(e, reading("monitor"), from: 1.6, for: 3, focus: "laptop", focusTarget: "w9")
        XCTAssertTrue(acts.isEmpty)
    }

    func testNoActionWhenFocusIsAlreadyThere() {
        let e = FocusEngine()
        _ = run(e, reading("laptop"), from: 0, for: 1, focus: "monitor")
        XCTAssertTrue(run(e, reading("monitor"), from: 1, for: 1, focus: "monitor").isEmpty)
    }

    func testLookingAwayDoesNotSwitch() {
        let e = FocusEngine()
        _ = run(e, reading("laptop"), from: 0, for: 1, focus: "laptop")
        XCTAssertTrue(run(e, ignored, from: 1, for: 2, focus: "laptop").isEmpty)
        XCTAssertTrue(run(e, nil, from: 3, for: 2, focus: "laptop").isEmpty)
        XCTAssertEqual(e.facedScreen, "laptop")
    }

    // Within one screen.

    let left = HitTarget(id: "w1", rect: CGRect(x: 0, y: 0, width: 700, height: 900), kind: .window, windowID: 1, pid: 10)
    let right = HitTarget(id: "w2", rect: CGRect(x: 700, y: 0, width: 770, height: 900), kind: .window, windowID: 2, pid: 11)

    func testLookingAtAnotherWindowFocusesIt() {
        let e = FocusEngine()
        let acts = run(e, reading("laptop", point: CGPoint(x: 1000, y: 400)), from: 0, for: 1, focus: "laptop",
                       focusTarget: "w1", targets: [left, right])
        XCTAssertEqual(acts.map(\.1), [.focus(right)])
    }

    func testTypingKeepsPanesPut() {
        let e = FocusEngine()
        let p = CGPoint(x: 1000, y: 400)
        let typingActs = run(e, reading("laptop", point: p), from: 0, for: 2, focus: "laptop", focusTarget: "w1",
                             targets: [left, right], sinceKey: { $0 })
        XCTAssertTrue(typingActs.isEmpty)
        // Stops typing at t=2 and keeps looking: after the 3 s typing pause focus follows.
        let later = run(e, reading("laptop", point: p), from: 2, for: 3, focus: "laptop", focusTarget: "w1",
                        targets: [left, right], sinceKey: { $0 - 2 + 1.9 })
        XCTAssertEqual(later.map(\.1), [.focus(right)])
    }

    func testWithinScreenCanBeTurnedOff() {
        var s = HeadwaySettings()
        s.focusWithinScreen = false
        let e = FocusEngine(settings: s)
        XCTAssertTrue(run(e, reading("laptop", point: CGPoint(x: 1000, y: 400)), from: 0, for: 1, focus: "laptop",
                          focusTarget: "w1", targets: [left, right]).isEmpty)
    }

    func testBorderJitterDoesNotPingPong() {
        let e = FocusEngine()
        _ = run(e, reading("laptop", point: CGPoint(x: 300, y: 400)), from: 0, for: 1, focus: "laptop",
                focusTarget: "w1", targets: [left, right])
        // Gaze wobbles ±15 pt across the border at x=700.
        var acts = [(Double, EngineAction)]()
        for i in 0..<45 {
            let x: CGFloat = i % 2 == 0 ? 690 : 712
            acts += run(e, reading("laptop", point: CGPoint(x: x, y: 400)), from: 1 + Double(i) / 15, for: 1.0 / 15,
                        focus: "laptop", focusTarget: "w1", targets: [left, right])
        }
        XCTAssertTrue(acts.isEmpty)
    }
}

final class HitTesterTests: XCTestCase {
    func testFrontWindowWins() {
        let back = HitTarget(id: "back", rect: CGRect(x: 0, y: 0, width: 1000, height: 800), kind: .window, windowID: 1, pid: 1)
        let front = HitTarget(id: "front", rect: CGRect(x: 200, y: 200, width: 300, height: 300), kind: .window, windowID: 2, pid: 2)
        XCTAssertEqual(HitTester.pick(CGPoint(x: 300, y: 300), targets: [front, back], current: nil, margin: 20)?.id, "front")
        XCTAssertEqual(HitTester.pick(CGPoint(x: 800, y: 300), targets: [front, back], current: nil, margin: 20)?.id, "back")
        // Current = back, point just inside front's edge: not clearly inside, so back keeps it.
        XCTAssertEqual(HitTester.pick(CGPoint(x: 205, y: 300), targets: [front, back], current: "back", margin: 20)?.id, "back")
        XCTAssertEqual(HitTester.pick(CGPoint(x: 300, y: 300), targets: [front, back], current: "back", margin: 20)?.id, "front")
    }
}

final class StoreTests: XCTestCase {
    func testClickCapKeepsNewest() {
        var store = CalibrationStore()
        for i in 0..<(CalibrationStore.clickCap + 10) {
            store.addClick(TrainingSample(face: FaceSample(t: Double(i)), screen: "laptop", u: 0, v: 0, source: .click))
        }
        store.addClick(TrainingSample(face: FaceSample(t: 0), screen: "monitor", u: 0, v: 0, source: .click))
        XCTAssertEqual(store.clicks.filter { $0.screen == "laptop" }.count, CalibrationStore.clickCap)
        XCTAssertEqual(store.clicks.first?.face.t, 10)
        XCTAssertEqual(store.clicks.filter { $0.screen == "monitor" }.count, 1)
    }

    func testMovedScreenIsNoticed() {
        var store = CalibrationStore()
        store.replaceCalibration(laptop, with: [])
        store.replaceCalibration(monitor, with: [])
        var moved = monitor
        moved.frame.origin.x = -1920
        XCTAssertEqual(store.movedScreens(current: [laptop, moved]), ["monitor"])
    }

    func testAccuracyTrackerSuggestsRecalibration() {
        var a = AccuracyTracker()
        for i in 0..<30 { a.record(predicted: i % 2 == 0 ? "laptop" : "monitor", actual: "laptop") }
        XCTAssertTrue(a.suggestsRecalibration)
        a.reset()
        for _ in 0..<30 { a.record(predicted: "laptop", actual: "laptop") }
        XCTAssertFalse(a.suggestsRecalibration)
    }

    func testOldSettingsStillLoad() throws {
        let s = try JSONDecoder().decode(HeadwaySettings.self, from: Data(#"{"headTurn":0.4}"#.utf8))
        XCTAssertEqual(s.headTurn, 0.4)
        XCTAssertEqual(s.switchDelay, 0.3)
        XCTAssertTrue(s.focusWithinScreen)
    }

    func testSmootherCutsJitterOnAStillFace() {
        var sm = SampleSmoother()
        var n = Noise()
        var raw = [Double](), smooth = [Double]()
        for i in 0..<90 {
            let y = 0.3 + n.next() * 0.03
            let s = sm.smooth(FaceSample(t: Double(i) / 15, yaw: y))
            if i >= 30 {
                raw.append(y)
                smooth.append(s.yaw)
            }
        }
        func sd(_ v: [Double]) -> Double {
            let m = v.reduce(0, +) / Double(v.count)
            return sqrt(v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count))
        }
        XCTAssertLessThan(sd(smooth), sd(raw) * 0.7)
    }

    func testSmootherFollowsARealTurnQuickly() {
        var sm = SampleSmoother()
        var last = FaceSample(t: 0)
        for i in 0..<30 { last = sm.smooth(FaceSample(t: Double(i) / 15, yaw: 0)) }
        // Head snaps to 0.6 rad; within 300 ms the smoothed value is most of the way there.
        for i in 30..<35 { last = sm.smooth(FaceSample(t: Double(i) / 15, yaw: 0.6)) }
        XCTAssertGreaterThan(last.yaw, 0.45)
    }
}

final class BezelTests: XCTestCase {
    func testBoundarySitsAtTheGapForUnequalScreens() {
        // A narrow laptop and a wide monitor: the gap is closer to the laptop than the midpoint of the centres.
        let model = GazeModel(samples: calibration([laptop, monitor]), screens: [laptop, monitor])!
        var n = Noise()
        let laptopEdge = face(laptop, u: 0.94, v: 0.5, noise: &n, jitter: 0)
        let monitorEdge = face(monitor, u: 0.06, v: 0.5, noise: &n, jitter: 0)
        // Just past the monitor's inner edge (towards its centre) must read as the monitor, even from the laptop.
        var pose = monitorEdge
        pose.yaw += 0.03
        pose.noseX += 0.03 * 0.25
        XCTAssertEqual(model.read(pose, current: "laptop", threshold: 0.5, hysteresis: 0.06).choice, .screen("monitor"))
        // And the laptop's own edge stays the laptop.
        XCTAssertEqual(model.read(laptopEdge, current: "laptop", threshold: 0.5, hysteresis: 0.06).choice, .screen("laptop"))
        _ = monitorEdge
    }

    func testAgreementIsHighForWellSeparatedScreens() {
        let samples = calibration([laptop, monitor])
        let model = GazeModel(samples: samples, screens: [laptop, monitor])!
        XCTAssertGreaterThan(model.agreement(samples)!, 0.97)
    }
}
