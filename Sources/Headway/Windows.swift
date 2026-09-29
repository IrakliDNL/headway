import AppKit
import HeadwayCore

struct WindowInfo: Equatable {
    let id: CGWindowID
    let pid: pid_t
    let owner: String
    let bounds: CGRect

    var targetID: String { "w\(id)" }
}

/// Ordinary app windows currently on screen, front to back.
enum WindowCatalog {
    private static let ignoredOwners: Set<String> = [
        "Window Server", "Dock", "Control Center", "Notification Center", "Spotlight", "SystemUIServer", "WindowManager",
    ]

    static func onScreen() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        let me = getpid()
        return list.compactMap { d in
            guard (d[kCGWindowLayer as String] as? Int) == 0,
                  let id = (d[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != me,
                  let bounds = d[kCGWindowBounds as String],
                  let rect = CGRect(dictionaryRepresentation: bounds as! CFDictionary),
                  rect.width >= 120, rect.height >= 80,
                  ((d[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0.05
            else { return nil }
            let owner = d[kCGWindowOwnerName as String] as? String ?? ""
            if ignoredOwners.contains(owner) { return nil }
            return WindowInfo(id: id, pid: pid, owner: owner, bounds: rect)
        }
    }
}

/// Seconds since the person last typed or touched the mouse. Hardware events only, so Headway's own
/// pointer moves and pane clicks don't count as "you using the mouse". Needs no permission.
enum Activity {
    static var sinceKey: Double {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
    }

    static var sinceMouse: Double {
        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDown, .leftMouseDragged, .rightMouseDown, .rightMouseDragged,
            .otherMouseDown, .otherMouseDragged, .scrollWheel,
        ]
        return types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? 1000
    }
}

/// Keeps track of where keyboard focus is and, per screen, the last window used and the last pointer spot.
@MainActor
final class FocusTracker {
    private(set) var focusedWindow: WindowInfo?
    private(set) var focusScreen: String?
    private(set) var focusTarget: String?
    private(set) var lastWindowOnScreen: [String: WindowInfo] = [:]
    private(set) var lastPointerOnScreen: [String: CGPoint] = [:]
    private var lastRefresh = 0.0

    func refresh(now: Double, screens: [ScreenGeometry], windows: [WindowInfo], panes: PaneFinder, force: Bool = false) {
        guard force || now - lastRefresh >= 0.25 else { return }
        lastRefresh = now

        let mouse = Displays.mouseLocation()
        if let s = Displays.screen(containing: mouse, in: screens) { lastPointerOnScreen[s.key] = mouse }

        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        // Headway's own settings or welcome window: keep the last real answer.
        if app.processIdentifier == getpid() { return }
        let pid = app.processIdentifier
        var info: WindowInfo?
        if let axWin = AX.focusedWindow(of: pid), let id = AX.windowID(axWin) {
            info = windows.first { $0.id == id }
            if info == nil, let f = AX.frame(axWin), f.width >= 120 {
                info = WindowInfo(id: id, pid: pid, owner: app.localizedName ?? "", bounds: f)
            }
        }
        focusedWindow = info
        guard let info, let screen = Displays.screen(for: info.bounds, in: screens) else {
            focusScreen = nil
            focusTarget = nil
            return
        }
        focusScreen = screen.key
        lastWindowOnScreen[screen.key] = info
        focusTarget = panes.focusedPaneID(in: info) ?? info.targetID
    }
}

/// Carries out the engine's decisions through Accessibility — no clicks, except the pane fallback.
@MainActor
final class FocusController {
    /// Brings `window` forward and gives it keyboard focus.
    @discardableResult
    func focus(window: WindowInfo) -> Bool {
        guard let ax = AX.window(pid: window.pid, id: window.id) else { return false }
        AX.set(ax, kAXMainAttribute, kCFBooleanTrue)
        if !SkyLight.bringToFront(pid: window.pid, window: window.id) {
            AX.set(AX.app(window.pid), kAXFrontmostAttribute, kCFBooleanTrue)
        }
        AX.perform(ax, kAXRaiseAction)
        AX.set(ax, kAXFocusedAttribute, kCFBooleanTrue)
        // Activation is occasionally refused without an error. Check, and retry once the other way.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier != window.pid else { return }
            NSRunningApplication(processIdentifier: window.pid)?.activate(options: [])
            AX.set(ax, kAXMainAttribute, kCFBooleanTrue)
            AX.set(ax, kAXFocusedAttribute, kCFBooleanTrue)
            Log.event("focus: retried activation of \(window.owner)")
        }
        return true
    }

    /// Focuses the screen's last-used window (or its frontmost one) and optionally brings the pointer along.
    @discardableResult
    func switchScreen(to screen: ScreenGeometry, screens: [ScreenGeometry], windows: [WindowInfo],
                      tracker: FocusTracker, standard: (WindowInfo) -> Bool, movePointer: Bool) -> WindowInfo? {
        let onScreen = windows.filter { Displays.screen(for: $0.bounds, in: screens)?.key == screen.key }
        var target: WindowInfo?
        if let last = tracker.lastWindowOnScreen[screen.key] {
            target = onScreen.first { $0.id == last.id }
        }
        if target == nil { target = onScreen.first(where: standard) }
        if let target { focus(window: target) }
        if movePointer {
            let fallback = target.map { CGPoint(x: $0.bounds.midX, y: $0.bounds.midY) }
                ?? CGPoint(x: screen.frame.midX, y: screen.frame.midY)
            let p = tracker.lastPointerOnScreen[screen.key] ?? fallback
            warp(to: screen.frame.contains(p) ? p : fallback)
        }
        return target
    }

    func warp(to p: CGPoint) {
        CGWarpMouseCursorPosition(p)
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}

/// Builds the list of things you could be looking at on a screen: whole windows, or panes inside
/// terminal/editor windows. Cached briefly, since this runs up to 15 times a second.
@MainActor
final class TargetProvider {
    let panes: PaneFinder
    private var windowCache: (t: Double, list: [WindowInfo]) = (-1, [])
    private var standardCache: [CGWindowID: (t: Double, ok: Bool)] = [:]

    init(panes: PaneFinder) {
        self.panes = panes
    }

    func windows(now: Double) -> [WindowInfo] {
        if now - windowCache.t > 0.2 { windowCache = (now, WindowCatalog.onScreen()) }
        return windowCache.list
    }

    func invalidate() {
        windowCache.t = -1
    }

    /// True for real document/app windows; false for invisible helper windows some apps keep on screen.
    func isStandard(_ w: WindowInfo, now: Double = CACurrentMediaTime()) -> Bool {
        if let c = standardCache[w.id], now - c.t < 5 { return c.ok }
        var ok = false
        if let ax = AX.window(pid: w.pid, id: w.id) {
            let sub = AX.string(ax, kAXSubroleAttribute)
            ok = sub == nil || sub == kAXStandardWindowSubrole || sub == kAXDialogSubrole || sub == kAXFloatingWindowSubrole
        }
        standardCache[w.id] = (now, ok)
        if standardCache.count > 400 { standardCache = standardCache.filter { now - $0.value.t < 5 } }
        return ok
    }

    func targets(on screen: ScreenGeometry, screens: [ScreenGeometry], now: Double) -> [HitTarget] {
        var out = [HitTarget]()
        for w in windows(now: now) where Displays.screen(for: w.bounds, in: screens)?.key == screen.key {
            guard isStandard(w, now: now) else { continue }
            let found = panes.panes(in: w, now: now)
            if found.count >= 2 {
                // Smallest first: floating panes (e.g. Cursor's agent prompt) sit on top of the tiles below.
                let order = found.indices.sorted { found[$0].rect.width * found[$0].rect.height < found[$1].rect.width * found[$1].rect.height }
                for i in order {
                    out.append(HitTarget(id: panes.paneID(w, i), rect: found[i].rect, kind: .pane, windowID: w.id, pid: w.pid, paneIndex: i))
                }
                // The rest of the window (sidebars, tab bars) still belongs to it, not to whatever is behind.
                out.append(HitTarget(id: w.targetID, rect: w.bounds, kind: .window, windowID: w.id, pid: w.pid))
            } else {
                out.append(HitTarget(id: w.targetID, rect: w.bounds, kind: .window, windowID: w.id, pid: w.pid))
            }
        }
        return out
    }
}
