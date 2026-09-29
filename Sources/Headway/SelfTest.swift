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
    }

    static func diagnose(seconds: Double) {
        let url = Storage.logs.appendingPathComponent("diagnose-\(Int(Date().timeIntervalSince1970)).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { exit(1) }
        let camera = CameraService()
        var count = 0, faces = 0
        let encoder = JSONEncoder()
        camera.onSample = { s in
            DispatchQueue.main.async {
                count += 1
                if let s {
                    faces += 1
                    if let d = try? encoder.encode(s) { handle.write(d + Data("\n".utf8)) }
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
