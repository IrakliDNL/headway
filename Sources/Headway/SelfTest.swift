import AppKit
import HeadwayCore
import SwiftUI

/// Command-line checks, used while building Headway:
///   Headway --windows          list screens and windows as Headway sees them
///   Headway --focus-test       focus each screen's front window in turn and verify it worked
///   Headway --diagnose <sec>   run the camera and log face numbers (launch via `open` so the app's
///                              own camera permission applies)
@MainActor
enum SelfTest {
    static func windows() {
        let screens = Displays.current().map(\.geometry)
        let provider = TargetProvider(panes: PaneFinder())
        let tracker = FocusTracker()
        let all = WindowCatalog.onScreen()
        tracker.refresh(now: 0, screens: screens, windows: all, panes: provider.panes, force: true)
        print("Accessibility trusted: \(AX.isTrusted)")
        print("Focused: \(tracker.focusedWindow.map { "\($0.owner) #\($0.id)" } ?? "none") on \(tracker.focusScreen ?? "?")")
        for s in screens {
            print("\nScreen \(s.name) [\(s.key)] frame=\(s.frame)")
            for w in all where Displays.screen(for: w.bounds, in: screens)?.key == s.key {
                print("  #\(w.id) \(w.owner) \(w.bounds) standard=\(provider.isStandard(w))")
            }
        }
    }

    static func focusTest() {
        let screens = Displays.current().map(\.geometry)
        let provider = TargetProvider(panes: PaneFinder())
        let tracker = FocusTracker()
        let focuser = FocusController()
        let all = WindowCatalog.onScreen()
        tracker.refresh(now: 0, screens: screens, windows: all, panes: provider.panes, force: true)
        let original = tracker.focusedWindow
        let pointer = Displays.mouseLocation()
        print("Start: \(original.map { "\($0.owner) #\($0.id)" } ?? "none") on \(tracker.focusScreen ?? "?")")
        let perScreen = screens.compactMap { s in
            all.first { Displays.screen(for: $0.bounds, in: screens)?.key == s.key && provider.isStandard($0) }
        }
        // Bounce between the screens a few times, then go back to where we started.
        var plan = [WindowInfo]()
        for _ in 0..<3 { plan += perScreen.reversed() }
        if let original { plan.append(original) }
        var failures = 0
        for w in plan {
            let t0 = CACurrentMediaTime()
            focuser.focus(window: w)
            var ok = false
            var waited = 0.0
            while waited < 1.0 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                waited += 0.05
                tracker.refresh(now: waited * 100, screens: screens, windows: all, panes: provider.panes, force: true)
                if tracker.focusedWindow?.id == w.id && NSWorkspace.shared.frontmostApplication?.processIdentifier == w.pid {
                    ok = true
                    break
                }
            }
            if !ok { failures += 1 }
            print("focus \(w.owner) #\(w.id) → \(tracker.focusedWindow.map { "\($0.owner) #\($0.id)" } ?? "none") "
                + "[\(ok ? "OK" : "FAILED")] after \(Int((CACurrentMediaTime() - t0) * 1000)) ms")
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        focuser.warp(to: pointer)
        print(failures == 0 ? "ALL OK" : "\(failures) FAILED")
    }

    /// Scans every on-screen window for panes (ignoring the app allowlist) and times it.
    static func panes() {
        for w in WindowCatalog.onScreen() {
            let electron = NSRunningApplication(processIdentifier: w.pid)?.bundleURL.map {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
            } ?? false
            let bundle = NSRunningApplication(processIdentifier: w.pid)?.bundleIdentifier ?? "?"
            let t0 = CACurrentMediaTime()
            let found = PaneScanner.scan(pid: w.pid, windowID: w.id, electron: electron, clip: w.bounds)
            let ms = Int((CACurrentMediaTime() - t0) * 1000)
            print("\(w.owner) #\(w.id) [\(bundle)] allowlisted=\(PaneFinder.supports(bundle: bundle)) electron=\(electron): \(found.count) pane(s) in \(ms) ms")
            for (i, p) in found.enumerated() { print("   p\(i) \(p.rect)") }
        }
    }

    /// Renders the Welcome, Settings and calibration screens to PNGs without showing them.
    static func renderUI(to dir: String) {
        let c = Coordinator()
        func snap(_ view: NSView, _ name: String) {
            let w = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            w.contentView = view
            view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
            print("wrote \(dir)/\(name).png \(Int(view.bounds.width))×\(Int(view.bounds.height))")
        }
        let welcome = NSHostingView(rootView: WelcomeView(c: c, calibrate: {}, close: {})
            .background(Color(nsColor: .windowBackgroundColor)))
        welcome.frame = NSRect(origin: .zero, size: welcome.fittingSize)
        snap(welcome, "welcome")
        let settings = NSHostingView(rootView: SettingsView(c: c, recalibrate: {}))
        settings.frame = NSRect(x: 0, y: 0, width: 540, height: 720)
        snap(settings, "settings")
        let cal = CalibrationView(frame: NSRect(x: 0, y: 0, width: 1470, height: 956))
        cal.title = "Screen 1 of 2 · Built-in Retina Display"
        cal.message = "Follow the dot, turning your head as much as you naturally would."
        cal.hint = "Press Space to start  ·  Esc to cancel"
        cal.tip = "Sit in your usual working position."
        snap(cal, "calibration-start")
        cal.running = true
        cal.faceFound = true
        cal.moveDot(to: NSPoint(x: 0.94 * 1470, y: 0.94 * 956), over: 0)
        cal.progress = 0.6
        snap(cal, "calibration-dot")
        cal.overlay = "Now keep your head still and follow the dot with just your eyes."
        cal.progress = nil
        cal.moveDot(to: NSPoint(x: 735, y: 478), over: 0)
        snap(cal, "calibration-eyes-intro")
        cal.overlay = nil
        cal.banner = "Eyes only — keep your head still"
        cal.bannerWarning = true
        cal.progress = 0.4
        cal.moveDot(to: NSPoint(x: 0.85 * 1470, y: 0.8 * 956), over: 0)
        snap(cal, "calibration-eyes-warning")
    }

    /// How well does the saved calibration aim *within* each screen? Uses the user's real clicks as ground
    /// truth (you look where you click), plus leave-one-dot-out on the calibration itself.
    static func evaluate() {
        let store = Storage.loadStore()
        let screens = Displays.current().map(\.geometry)
        func report(_ name: String, _ pairs: [(pu: Double, pv: Double, u: Double, v: Double)], _ screen: ScreenGeometry) {
            guard !pairs.isEmpty else { return }
            let eu = pairs.map { abs($0.pu - $0.u) }.sorted(), ev = pairs.map { abs($0.pv - $0.v) }.sorted()
            let med = { (a: [Double]) in a[a.count / 2] }
            let halves = pairs.filter { ($0.pu < 0.5) == ($0.u < 0.5) }.count
            print(String(format: "  %@: n=%d  median error x %.0f pt (%.0f%%), y %.0f pt (%.0f%%); left/right half right %d%%",
                         name, pairs.count, med(eu) * screen.frame.width, med(eu) * 100, med(ev) * screen.frame.height,
                         med(ev) * 100, halves * 100 / pairs.count))
        }
        for screen in screens {
            let cal = store.samples.filter { $0.screen == screen.key }
            let clicks = store.clicks.filter { $0.screen == screen.key }
            guard !cal.isEmpty else { continue }
            print("\(screen.name): \(cal.count) calibration samples, \(clicks.count) clicks")
            // 1. Calibration only → predict clicks.
            if let m = GazeModel(samples: store.samples, screens: screens), let r = m.within[screen.key] {
                report("calibration → clicks", clicks.map { let p = r.predict(Features.point($0.face)); return (p[0], p[1], $0.u, $0.v) }, screen)
            }
            // 2. Leave one calibration dot out.
            var loo = [(pu: Double, pv: Double, u: Double, v: Double)]()
            let spots = Set(cal.map { "\($0.u),\($0.v)" })
            for spot in spots {
                let train = store.samples.filter { "\($0.u),\($0.v)" != spot || $0.screen != screen.key }
                guard let m = GazeModel(samples: train, screens: screens), let r = m.within[screen.key] else { continue }
                for s in cal where "\(s.u),\(s.v)" == spot {
                    let p = r.predict(Features.point(s.face))
                    loo.append((p[0], p[1], s.u, s.v))
                }
            }
            report("leave-one-dot-out", loo, screen)
            // 3. Calibration + other clicks → each click (what click learning buys).
            var cv = [(pu: Double, pv: Double, u: Double, v: Double)]()
            for (i, c) in clicks.enumerated() {
                let others = clicks.enumerated().filter { $0.offset != i }.map(\.element)
                guard let m = GazeModel(samples: store.samples + others + store.clicks.filter { $0.screen != screen.key }, screens: screens),
                      let r = m.within[screen.key] else { continue }
                let p = r.predict(Features.point(c.face))
                cv.append((p[0], p[1], c.u, c.v))
            }
            report("with click learning", cv, screen)

            // How much of the left→right aim the model credits to the eyes (vs the head).
            let data = cal + clicks
            if let r = RidgeRegression.fit(x: data.map { Features.point($0.face) }, y: data.map { [$0.u] },
                                           weights: data.map { $0.source == .click ? 2 : 1 }, lambda: 0.02) {
                let left = cal.filter { $0.u < 0.3 }.map { Features.point($0.face) }
                let right = cal.filter { $0.u > 0.7 }.map { Features.point($0.face) }
                if !left.isEmpty && !right.isEmpty {
                    func mean(_ rows: [[Double]], _ j: Int) -> Double { rows.map { $0[j] }.reduce(0, +) / Double(rows.count) }
                    let part = (0..<6).map { j in r.coefficients[0][j] / r.standardizer.scale[j] * (mean(right, j) - mean(left, j)) }
                    let head = part[0..<4].reduce(0, +), eyes = part[4..<6].reduce(0, +)
                    print(String(format: "  eyes' share of the aim: %.0f%% (head %.2f, eyes %.2f of the screen width)",
                                 eyes / (head + eyes) * 100, head, eyes))
                }
            }
        }
    }

    /// Compares within-screen model variants against the user's clicks.
    static func experiment() {
        let store = Storage.loadStore()
        let screens = Displays.current().map(\.geometry)
        typealias Extract = (FaceSample) -> [Double]
        let sets: [(String, Extract)] = [
            ("full9", Features.full),
            ("head4", { [$0.yaw, $0.pitch, $0.noseX, $0.noseY] }),
            ("head+eyes6", Features.head),
            ("head+pos7", { [$0.yaw, $0.pitch, $0.noseX, $0.noseY, $0.faceX, $0.faceY, $0.faceW] }),
            ("yaw/nose/eyeX (x only)", { [$0.yaw, $0.noseX, $0.eyeX, $0.faceX] }),
        ]
        for screen in screens {
            let cal = store.samples.filter { $0.screen == screen.key }
            let clicks = store.clicks.filter { $0.screen == screen.key }
            guard !cal.isEmpty, !clicks.isEmpty else { continue }
            print("\n\(screen.name) (\(clicks.count) clicks; x error in points, median · 75th pct; halves = clicks clearly on one side)")
            for (name, f) in sets {
                for lambda in [0.02, 0.1, 0.3, 1.0] {
                    func errs(_ train: [TrainingSample], _ test: [TrainingSample]) -> [(Double, Double)] {
                        guard let r = RidgeRegression.fit(x: train.map { f($0.face) }, y: train.map { [$0.u] },
                                                          weights: train.map { $0.source == .click ? 2 : 1 }, lambda: lambda)
                        else { return [] }
                        return test.map { (r.predict(f($0.face))[0], $0.u) }
                    }
                    let a = errs(cal, clicks)
                    var b = [(Double, Double)]()
                    for (i, c) in clicks.enumerated() {
                        b += errs(cal + clicks.enumerated().filter { $0.offset != i }.map(\.element), [c])
                    }
                    func summary(_ p: [(Double, Double)]) -> String {
                        let e = p.map { abs($0.0 - $0.1) * screen.frame.width }.sorted()
                        let clear = p.filter { abs($0.1 - 0.5) > 0.12 }
                        let halves = clear.filter { ($0.0 < 0.5) == ($0.1 < 0.5) }.count
                        return String(format: "%4.0f · %4.0f pt, halves %3d%%", e[e.count / 2], e[e.count * 3 / 4],
                                      clear.isEmpty ? 0 : halves * 100 / clear.count)
                    }
                    print(String(format: "  %-24@ λ=%-4.2f  calib only: %@   + clicks: %@", name as NSString, lambda, summary(a), summary(b)))
                }
            }
        }
    }

    static func diagnose(seconds: Double) {
        let url = Storage.logs.appendingPathComponent("diagnose-\(Int(Date().timeIntervalSince1970)).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { exit(1) }
        let camera = CameraService()
        var count = 0, faces = 0
        let encoder = JSONEncoder()
        camera.onSample = { s in
            // Read on the camera queue, right after the frame that produced `s`.
            let vision = camera.lastVisionEye
            DispatchQueue.main.async {
                count += 1
                if let s {
                    faces += 1
                    if var d = try? encoder.encode(s) {
                        if let vision {
                            // Append Vision's own pupil estimate for comparison.
                            d.removeLast()
                            d += Data(",\"visionEyeX\":\(vision.x),\"visionEyeY\":\(vision.y)}".utf8)
                        }
                        handle.write(d + Data("\n".utf8))
                    }
                } else {
                    handle.write(Data("null\n".utf8))
                }
            }
        }
        CameraService.requestAccess { ok in
            guard ok else {
                handle.write(Data("{\"error\":\"camera denied\"}\n".utf8))
                exit(2)
            }
            try? camera.start(deviceID: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                camera.stop()
                handle.write(Data("{\"frames\":\(count),\"faces\":\(faces)}\n".utf8))
                try? handle.close()
                exit(0)
            }
        }
    }
}
