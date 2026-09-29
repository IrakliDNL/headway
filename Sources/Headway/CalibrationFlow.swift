import AppKit
import HeadwayCore

/// Full-screen calibration, one screen at a time: a dot visits nine spots (corners, edges, centre) and
/// Headway records what your face looks like while you look at each. About 20 seconds per screen.
@MainActor
final class CalibrationFlow {
    private struct Spot { let u: Double, v: Double }
    // A snake through the grid so the dot never jumps across the whole screen.
    private static let spots: [Spot] = [
        Spot(u: 0.06, v: 0.06), Spot(u: 0.5, v: 0.06), Spot(u: 0.94, v: 0.06),
        Spot(u: 0.94, v: 0.5), Spot(u: 0.5, v: 0.5), Spot(u: 0.06, v: 0.5),
        Spot(u: 0.06, v: 0.94), Spot(u: 0.5, v: 0.94), Spot(u: 0.94, v: 0.94),
    ]
    private static let moveTime = 0.45
    private static let settleTime = 0.5
    private static let collectTime = 1.1
    private static let graceTime = 2.0
    private static let minSamples = 8

    private enum Phase { case waiting, moving, settling, collecting }

    private let coordinator: Coordinator
    private let screens: [Displays.Screen]
    private var screenIndex = 0
    private var window: CalibrationWindow?
    private var view: CalibrationView?
    private var results: [(ScreenGeometry, [TrainingSample])] = []
    private var collected: [TrainingSample] = []
    private var buffer: [FaceSample] = []
    private var phase = Phase.waiting
    private var phaseStart = 0.0
    private var spotIndex = 0
    private var retried = false
    private var skipped = 0
    private var lastFace = 0.0
    private var timer: Timer?

    /// Called with true when every screen got a usable calibration.
    var onFinish: ((_ ok: Bool, _ problems: [String]) -> Void)?
    private var problems: [String] = []

    init(coordinator: Coordinator, screens: [Displays.Screen]) {
        self.coordinator = coordinator
        self.screens = screens
    }

    func start() {
        guard !screens.isEmpty else { return }
        coordinator.calibrationSink = { [weak self] s in self?.receive(s) }
        coordinator.reconsiderCamera()
        coordinator.overlay.hide()
        NSApp.activate(ignoringOtherApps: true)
        showScreen()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func showScreen() {
        window?.orderOut(nil)
        let screen = screens[screenIndex]
        let w = CalibrationWindow(screen: screen.nsScreen)
        let v = CalibrationView(frame: NSRect(origin: .zero, size: screen.nsScreen.frame.size))
        v.title = screens.count > 1 ? "Screen \(screenIndex + 1) of \(screens.count) · \(screen.geometry.name)" : screen.geometry.name
        v.message = screenIndex == 0
            ? "Follow the dot, turning your head as much as you naturally would."
            : "Now turn to this screen and follow the dot here too."
        v.hint = "Press Space to start  ·  Esc to cancel"
        v.tip = "Sit in your usual working position."
        w.contentView = v
        w.onKey = { [weak self] code in self?.key(code) }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
        view = v
        phase = .waiting
        collected = []
        skipped = 0
    }

    private func key(_ code: UInt16) {
        switch code {
        case 53: finish(cancelled: true)                   // Esc
        case 49 where phase == .waiting: beginSpot(0)      // Space
        default: break
        }
    }

    private func beginSpot(_ i: Int) {
        spotIndex = i
        retried = false
        phase = .moving
        phaseStart = CACurrentMediaTime()
        buffer = []
        guard let view else { return }
        view.running = true
        let s = Self.spots[i]
        view.moveDot(to: NSPoint(x: s.u * view.bounds.width, y: (1 - s.v) * view.bounds.height), over: Self.moveTime)
    }

    private func receive(_ s: FaceSample?) {
        guard let s else { return }
        lastFace = CACurrentMediaTime()
        if phase == .collecting { buffer.append(s) }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let elapsed = now - phaseStart
        view?.faceFound = now - lastFace < 0.4
        switch phase {
        case .waiting:
            break
        case .moving:
            if elapsed >= Self.moveTime { enter(.settling, now) }
        case .settling:
            if elapsed >= Self.settleTime {
                buffer = []
                enter(.collecting, now)
            }
        case .collecting:
            view?.progress = min(elapsed / Self.collectTime, 1)
            if elapsed >= Self.collectTime && buffer.count >= Self.minSamples {
                keepSpot()
            } else if elapsed >= Self.collectTime + Self.graceTime {
                if buffer.count >= Self.minSamples / 2 {
                    keepSpot()
                } else if !retried {
                    // Try this spot once more before giving up on it.
                    retried = true
                    buffer = []
                    enter(.settling, now)
                } else {
                    skipped += 1
                    nextSpot()
                }
            }
        }
        view?.needsDisplay = true
    }

    private func enter(_ p: Phase, _ now: Double) {
        phase = p
        phaseStart = now
        view?.progress = p == .collecting ? 0 : nil
    }

    private func keepSpot() {
        let s = Self.spots[spotIndex]
        let key = screens[screenIndex].geometry.key
        collected += buffer.map { TrainingSample(face: $0, screen: key, u: s.u, v: s.v, source: .calibration) }
        nextSpot()
    }

    private func nextSpot() {
        if spotIndex + 1 < Self.spots.count {
            beginSpot(spotIndex + 1)
            return
        }
        let geometry = screens[screenIndex].geometry
        if Self.spots.count - skipped >= 6 {
            results.append((geometry, collected))
        } else {
            problems.append("\(geometry.name): couldn't see your face for most of the dots")
        }
        if screenIndex + 1 < screens.count {
            screenIndex += 1
            showScreen()
        } else {
            finish(cancelled: false)
        }
    }

    private func finish(cancelled: Bool) {
        timer?.invalidate()
        timer = nil
        window?.orderOut(nil)
        window = nil
        coordinator.calibrationSink = nil
        if !cancelled && !results.isEmpty { coordinator.applyCalibration(results) }
        coordinator.reconsiderCamera()
        coordinator.updateStatus(force: true)
        onFinish?(!cancelled && problems.isEmpty && !results.isEmpty, cancelled ? ["Cancelled"] : problems)
    }
}

final class CalibrationWindow: NSWindow {
    var onKey: ((UInt16) -> Void)?

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: true)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        onKey?(event.keyCode)
    }
}

final class CalibrationView: NSView {
    var title = ""
    var message = ""
    var hint = ""
    var tip = ""
    var running = false
    var faceFound = false
    var progress: Double?

    private var from: NSPoint?
    private var to: NSPoint?
    private var moveStart = 0.0
    private var moveDuration = 0.0

    func moveDot(to p: NSPoint, over duration: Double) {
        from = currentDot ?? p
        to = p
        moveStart = CACurrentMediaTime()
        moveDuration = duration
    }

    private var currentDot: NSPoint? {
        guard let from, let to else { return nil }
        let x = min(max((CACurrentMediaTime() - moveStart) / max(moveDuration, 0.001), 0), 1)
        let e = x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2
        return NSPoint(x: from.x + (to.x - from.x) * e, y: from.y + (to.y - from.y) * e)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.06, alpha: 0.94).setFill()
        bounds.fill()

        func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, y: CGFloat) {
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: para,
            ]
            let r = NSRect(x: 40, y: y, width: bounds.width - 80, height: size * 1.6)
            (s as NSString).draw(in: r, withAttributes: attrs)
        }

        let mid = bounds.midY
        if !running {
            text(title, size: 15, weight: .medium, color: NSColor(white: 1, alpha: 0.55), y: mid + 90)
            text(message, size: 28, weight: .semibold, color: .white, y: mid + 30)
            text(hint, size: 17, weight: .regular, color: NSColor(white: 1, alpha: 0.8), y: mid - 20)
            text(tip, size: 14, weight: .regular, color: NSColor(white: 1, alpha: 0.5), y: mid - 60)
        }

        // Face check, always visible so you know the camera can see you.
        let status = faceFound ? "●  Face found" : "●  Looking for your face…"
        text(status, size: 14, weight: .medium, color: faceFound ? .systemGreen : .systemOrange, y: 28)

        if running, let p = currentDot {
            let r: CGFloat = 11
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)).fill()
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)).fill()
            if let progress {
                let ring = NSBezierPath()
                ring.appendArc(withCenter: p, radius: 22, startAngle: 90, endAngle: 90 - 360 * CGFloat(progress), clockwise: true)
                ring.lineWidth = 3
                NSColor.systemGreen.setStroke()
                ring.stroke()
            }
        }
    }
}
