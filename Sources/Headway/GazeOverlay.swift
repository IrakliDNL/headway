import AppKit

/// The optional "gaze dot": a click-through layer over every screen showing where Headway thinks
/// you're looking, and outlining the window or pane it has picked.
@MainActor
final class GazeOverlay {
    private var windows: [NSWindow] = []
    private var views: [OverlayView] = []

    func rebuild() {
        let wasVisible = windows.first?.isVisible ?? false
        windows.forEach { $0.orderOut(nil) }
        windows = []
        views = []
        for screen in NSScreen.screens {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.isReleasedWhenClosed = false
            let v = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
            w.contentView = v
            w.setFrame(screen.frame, display: false)
            windows.append(w)
            views.append(v)
        }
        if wasVisible { windows.forEach { $0.orderFrontRegardless() } }
    }

    func show(point: CGPoint?, ignored: Bool, highlight: CGRect?, waiting: Bool) {
        if windows.isEmpty { rebuild() }
        for (w, v) in zip(windows, views) {
            if !w.isVisible { w.orderFrontRegardless() }
            let origin = w.frame.origin
            func local(_ p: CGPoint) -> NSPoint {
                let c = Displays.toCocoa(p)
                return NSPoint(x: c.x - origin.x, y: c.y - origin.y)
            }
            var dot: NSPoint?
            if let point {
                let d = local(point)
                if v.bounds.insetBy(dx: -40, dy: -40).contains(d) { dot = d }
            }
            var box: NSRect?
            if let highlight {
                let r = Displays.toCocoa(highlight).offsetBy(dx: -origin.x, dy: -origin.y)
                if v.bounds.intersects(r) { box = r }
            }
            v.update(dot: dot, box: box, color: ignored ? .systemGray : waiting ? .systemOrange : .systemGreen)
        }
    }

    func hide() {
        windows.forEach { $0.orderOut(nil) }
    }
}

private final class OverlayView: NSView {
    private var dot: NSPoint?
    private var box: NSRect?
    private var color: NSColor = .systemGreen

    func update(dot: NSPoint?, box: NSRect?, color: NSColor) {
        guard dot != self.dot || box != self.box || color != self.color else { return }
        self.dot = dot
        self.box = box
        self.color = color
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if let box {
            let path = NSBezierPath(roundedRect: box.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
            path.lineWidth = 3
            color.withAlphaComponent(0.6).setStroke()
            path.stroke()
        }
        if let dot {
            let r: CGFloat = 13
            let circle = NSBezierPath(ovalIn: NSRect(x: dot.x - r, y: dot.y - r, width: 2 * r, height: 2 * r))
            color.withAlphaComponent(0.75).setFill()
            circle.fill()
            NSColor.white.withAlphaComponent(0.9).setStroke()
            circle.lineWidth = 2.5
            circle.stroke()
        }
    }
}
