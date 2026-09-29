import AppKit
import HeadwayCore

/// A focusable split inside a terminal or editor window.
struct Pane {
    /// Visible area of the pane, global coordinates.
    let rect: CGRect
    /// The text input that takes keyboard focus.
    let element: AXUIElement
}

/// Finds and focuses split panes in terminals and editors (see docs/pane-research.md). Every other app —
/// browsers, chat, documents — is focused as a whole window, so a chunk of a web page never steals focus.
@MainActor
final class PaneFinder {
    var enabled = true
    var clickFallback = true
    /// Called just before Headway posts its own click, so it isn't mistaken for the user's.
    var onSyntheticClick: (() -> Void)?

    /// VS Code family and other Electron terminals/editors: panes live in the web content.
    static let electronApps: Set<String> = [
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.exafunction.windsurf", "com.vscodium",
        "co.zeit.hyper",
    ]
    /// Native terminals and editors. Terminal.app is deliberately absent: its split panes are two views
    /// of the same shell, so there's nothing to choose between.
    static let nativeApps: Set<String> = [
        "com.apple.dt.Xcode", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "com.github.wez.wezterm", "dev.zed.Zed", "com.sublimetext.4", "com.sublimetext.3",
        "com.google.android.studio",
    ]

    static func supports(bundle: String) -> Bool {
        electronApps.contains(bundle) || nativeApps.contains(bundle) || bundle.hasPrefix("com.jetbrains.")
    }

    private var cache: [CGWindowID: (t: Double, panes: [Pane])] = [:]
    private var scanning: Set<CGWindowID> = []
    private var accessibilityOn: Set<pid_t> = []
    private var apps: [pid_t: (bundle: String?, electron: Bool)] = [:]
    private let queue = DispatchQueue(label: "headway.panes", qos: .userInitiated)

    func paneID(_ w: WindowInfo, _ index: Int) -> String { "\(w.targetID):p\(index)" }

    private func app(_ pid: pid_t) -> (bundle: String?, electron: Bool) {
        if let known = apps[pid] { return known }
        let running = NSRunningApplication(processIdentifier: pid)
        let electron = running?.bundleURL.map {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
        } ?? false
        let info = (running?.bundleIdentifier, electron)
        apps[pid] = info
        return info
    }

    func supports(_ pid: pid_t) -> Bool {
        guard let bundle = app(pid).bundle else { return false }
        return Self.supports(bundle: bundle)
    }

    /// Panes of `window`, ordered top-to-bottom then left-to-right (that order gives their IDs).
    /// Served from a cache; a stale entry triggers a background rescan. Empty until the first scan lands.
    func panes(in window: WindowInfo, now: Double) -> [Pane] {
        guard enabled, supports(window.pid) else { return [] }
        let cached = cache[window.id]
        if cached == nil || now - cached!.t > 1.0 { scan(window) }
        return cached?.panes ?? []
    }

    private func scan(_ w: WindowInfo) {
        guard !scanning.contains(w.id) else { return }
        let electron = app(w.pid).electron
        if electron && !accessibilityOn.contains(w.pid) {
            // Chromium only builds its accessibility tree when asked. The tree fills in over a second or two,
            // so early scans may come back empty; the next rescan picks the panes up.
            AX.set(AX.app(w.pid), "AXManualAccessibility", kCFBooleanTrue)
            accessibilityOn.insert(w.pid)
            Log.event("panes: enabled accessibility tree for \(app(w.pid).bundle ?? "?")")
        }
        scanning.insert(w.id)
        let pid = w.pid, id = w.id, bounds = w.bounds
        queue.async {
            let found = PaneScanner.scan(pid: pid, windowID: id, electron: electron, clip: bounds)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.scanning.remove(id)
                    self.cache[id] = (CACurrentMediaTime(), found)
                    if self.cache.count > 60 {
                        let cutoff = CACurrentMediaTime() - 30
                        self.cache = self.cache.filter { $0.value.t > cutoff }
                    }
                }
            }
        }
    }

    /// Which pane of the (frontmost) window has keyboard focus.
    func focusedPaneID(in w: WindowInfo) -> String? {
        guard enabled, let panes = cache[w.id]?.panes, panes.count >= 2, let focused = AX.focusedElement(of: w.pid)
        else { return nil }
        if let i = panes.firstIndex(where: { CFEqual($0.element, focused) }) { return paneID(w, i) }
        if let f = AX.frame(focused), let i = panes.firstIndex(where: { $0.rect.contains(CGPoint(x: f.midX, y: f.midY)) }) {
            return paneID(w, i)
        }
        return nil
    }

    @discardableResult
    func focus(_ target: HitTarget, in window: WindowInfo, focuser: FocusController) -> Bool {
        guard let i = target.paneIndex, let panes = cache[window.id]?.panes, i < panes.count else { return false }
        let pane = panes[i]
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if frontPID != window.pid || AX.focusedWindow(of: window.pid).flatMap(AX.windowID) != window.id {
            focuser.focus(window: window)
        }
        AX.set(pane.element, kAXFocusedAttribute, kCFBooleanTrue)
        // Check shortly after; apps that ignore the Accessibility route get a click in the pane's middle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = AX.focusedElement(of: window.pid)
                var ok = now.map { CFEqual($0, pane.element) } ?? false
                if !ok, let now, let f = AX.frame(now) { ok = pane.rect.contains(CGPoint(x: f.midX, y: f.midY)) }
                if !ok && self.clickFallback && self.supports(window.pid) {
                    Log.event("panes: Accessibility focus didn't take in \(window.owner); clicking the pane")
                    self.click(at: CGPoint(x: pane.rect.midX, y: pane.rect.midY))
                }
            }
        }
        return true
    }

    private func click(at p: CGPoint) {
        onSyntheticClick?()
        let saved = Displays.mouseLocation()
        let src = CGEventSource(stateID: .privateState)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(15_000)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(15_000)
        CGWarpMouseCursorPosition(saved)
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}

/// The tree walk, run off the main thread. Algorithm from docs/pane-research.md:
/// pane inputs are the terminal/editor text areas; each pane's area is the largest ancestor of its input
/// that contains no other pane input.
enum PaneScanner {
    static let electronInputClasses: Set<String> = ["inputarea", "xterm-helper-textarea", "aislash-editor-input", "ProseMirror"]
    /// Big lists (file navigators, outlines) hold no panes and can cost seconds to walk.
    static let prunedRoles: Set<String> = ["AXOutline", "AXTable", "AXList", "AXBrowser", "AXRow", "AXMenuBar", "AXToolbar"]
    static let leafRoles: Set<String> = [
        "AXTextArea", "AXTextField", "AXStaticText", "AXButton", "AXImage", "AXCheckBox", "AXRadioButton",
        "AXPopUpButton", "AXLink", "AXMenuButton",
    ]
    static let maxNodes = 3000

    private struct Node {
        let element: AXUIElement
        let parent: Int?
        let role: String
        let frame: CGRect?
        let classes: [String]
    }

    static func scan(pid: pid_t, windowID: CGWindowID, electron: Bool, clip: CGRect) -> [Pane] {
        guard let window = AX.window(pid: pid, id: windowID) else { return [] }
        var nodes = [Node]()
        var stack: [(AXUIElement, Int?, Int)] = [(window, nil, 0)]
        while nodes.count < maxNodes, let (element, parent, depth) = stack.popLast() {
            let role = AX.string(element, kAXRoleAttribute) ?? "?"
            let index = nodes.count
            let classes = electron ? (AX.value(element, "AXDOMClassList") as? [String] ?? []) : []
            nodes.append(Node(element: element, parent: parent, role: role, frame: AX.frame(element), classes: classes))
            if depth >= 80 || prunedRoles.contains(role) || leafRoles.contains(role) { continue }
            for child in AX.elements(element, kAXChildrenAttribute).reversed() { stack.append((child, index, depth + 1)) }
        }

        func ancestors(_ i: Int) -> [Int] {
            var out = [Int]()
            var j = nodes[i].parent
            while let k = j {
                out.append(k)
                j = nodes[k].parent
            }
            return out
        }
        func isInput(_ n: Node) -> Bool {
            guard n.role == "AXTextArea" || n.role == "AXTextField" else { return false }
            return electron ? !electronInputClasses.isDisjoint(with: n.classes) : n.role == "AXTextArea"
        }
        // Hidden inputs (background tabs, off-screen portals) sit under a 0–2 px ancestor.
        func visible(_ i: Int) -> Bool {
            !ancestors(i).contains { k in nodes[k].frame.map { $0.width <= 2 || $0.height <= 2 } ?? false }
        }

        let inputs = nodes.indices.filter { isInput(nodes[$0]) && visible($0) }
        let ancestorSets = inputs.map { Set(ancestors($0)) }
        var panes = [Pane]()
        for (a, input) in inputs.enumerated() {
            var region = input
            for anc in ancestors(input) {
                if inputs.indices.contains(where: { $0 != a && ancestorSets[$0].contains(anc) }) { break }
                region = anc
            }
            guard let frame = nodes[region].frame?.intersection(clip), !frame.isNull,
                  frame.width >= 60, frame.height >= 40 else { continue }
            panes.append(Pane(rect: frame, element: nodes[input].element))
        }
        return panes.sorted { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }
    }
}
