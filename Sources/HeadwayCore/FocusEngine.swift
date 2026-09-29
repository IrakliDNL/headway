import CoreGraphics
import Foundation

/// Something that can take keyboard focus: a whole window, or one pane inside a terminal/editor window.
public struct HitTarget: Equatable, Sendable {
    public enum Kind: String, Sendable { case window, pane }
    public var id: String
    public var rect: CGRect
    public var kind: Kind
    public var windowID: UInt32
    public var pid: Int32
    public var paneIndex: Int?

    public init(id: String, rect: CGRect, kind: Kind, windowID: UInt32, pid: Int32, paneIndex: Int? = nil) {
        self.id = id
        self.rect = rect
        self.kind = kind
        self.windowID = windowID
        self.pid = pid
        self.paneIndex = paneIndex
    }
}

public enum HitTester {
    /// The target at `p`, given targets ordered front to back. The current target keeps the point while
    /// it's within `margin` of its edge; another target must contain it clearly (by `margin`) to take over.
    public static func pick(_ p: CGPoint, targets: [HitTarget], current: String?, margin: CGFloat) -> HitTarget? {
        let front = targets.first { $0.rect.contains(p) }
        guard let cur = current, let ci = targets.firstIndex(where: { $0.id == cur }) else { return front }
        let c = targets[ci]
        let clearly = { (t: HitTarget) in t.rect.insetBy(dx: margin, dy: margin).contains(p) }
        if let inFront = targets[..<ci].first(where: clearly) { return inFront }
        if c.rect.contains(p) { return c }
        if c.rect.insetBy(dx: -margin, dy: -margin).contains(p) {
            return targets.first(where: { $0.id != cur && clearly($0) }) ?? c
        }
        return front
    }
}

/// One moment's worth of everything the engine needs to decide.
public struct EngineTick: Sendable {
    public var t: Double
    /// Nil when no face was seen this frame.
    public var reading: GazeReading?
    public var sinceKey: Double
    public var sinceMouse: Double
    /// The screen that holds keyboard focus right now.
    public var focusScreen: String?
    /// The window that holds keyboard focus right now.
    public var focusWindow: String?
    /// The window or pane that holds keyboard focus right now (same as the window for apps without panes).
    public var focusTarget: String?
    /// Windows/panes on the faced screen, front to back.
    public var targets: [HitTarget]
    public var hitMargin: CGFloat

    public init(t: Double, reading: GazeReading?, sinceKey: Double = 100, sinceMouse: Double = 100,
                focusScreen: String?, focusWindow: String? = nil, focusTarget: String? = nil,
                targets: [HitTarget] = [], hitMargin: CGFloat = 24) {
        self.t = t
        self.reading = reading
        self.sinceKey = sinceKey
        self.sinceMouse = sinceMouse
        self.focusScreen = focusScreen
        self.focusWindow = focusWindow ?? focusTarget
        self.focusTarget = focusTarget
        self.targets = targets
        self.hitMargin = hitMargin
    }
}

public enum EngineAction: Equatable, Sendable {
    /// Move focus to the screen: its last-used window, or failing that its frontmost one.
    case switchScreen(String)
    case focus(HitTarget)
}

/// Decides *when* focus moves. Reacts to changes in where you face — it never fights a click you made —
/// and waits out quick glances, typing and mouse use.
public final class FocusEngine {
    public var settings: HeadwaySettings
    /// The screen you're facing, after the delay has passed.
    public private(set) var facedScreen: String?
    /// The window/pane you're looking at on it, after the delay has passed.
    public private(set) var gazedTarget: String?

    private var screenCandidate: (key: String, since: Double)?
    private var pendingScreen: String?
    private var targetCandidate: (id: String?, since: Double)?
    private var pendingTarget: HitTarget?
    private var lastFocusScreen: String?
    private var lastFocusWindow: String?
    private var lastFocusTarget: String?

    public init(settings: HeadwaySettings = HeadwaySettings()) {
        self.settings = settings
    }

    public func reset() {
        facedScreen = nil
        gazedTarget = nil
        screenCandidate = nil
        pendingScreen = nil
        targetCandidate = nil
        pendingTarget = nil
    }

    /// True while the engine is holding back because of typing or the mouse — for the status display.
    public private(set) var waiting = false

    public func step(_ tick: EngineTick) -> EngineAction? {
        let typing = settings.waitWhileTyping && tick.sinceKey < settings.typingPause
        let mouseBusy = tick.sinceMouse < HeadwaySettings.mouseQuiet
        waiting = false

        // If focus moved by some other means (a click, ⌘-Tab, an app popping up), drop what we meant to do.
        if tick.focusScreen != lastFocusScreen || tick.focusWindow != lastFocusWindow {
            lastFocusScreen = tick.focusScreen
            lastFocusWindow = tick.focusWindow
            pendingScreen = nil
            pendingTarget = nil
        }
        if tick.focusTarget != lastFocusTarget {
            lastFocusTarget = tick.focusTarget
            pendingTarget = nil
        }

        // 1. Which screen are you facing?
        if case .screen(let key)? = tick.reading?.choice {
            if facedScreen == nil {
                facedScreen = key
            } else if key == facedScreen {
                screenCandidate = nil
            } else {
                if screenCandidate?.key != key { screenCandidate = (key, tick.t) }
                let delay = typing ? max(settings.switchDelay, HeadwaySettings.typingScreenDelay) : settings.switchDelay
                if tick.t - screenCandidate!.since >= delay {
                    facedScreen = key
                    screenCandidate = nil
                    gazedTarget = nil
                    targetCandidate = nil
                    pendingTarget = nil
                    pendingScreen = key == tick.focusScreen ? nil : key
                }
            }
        } else {
            // No face, or looking far away: a half-finished turn doesn't count.
            screenCandidate = nil
        }

        // 2. Follow a change of screen.
        if let p = pendingScreen {
            if p != facedScreen || p == tick.focusScreen {
                pendingScreen = nil
            } else if mouseBusy {
                waiting = true
                return nil
            } else {
                pendingScreen = nil
                return .switchScreen(p)
            }
        }

        // 3. Within the screen: which window or pane are you looking at?
        guard settings.focusWithinScreen, let faced = facedScreen, faced == tick.focusScreen,
              case .screen(let key)? = tick.reading?.choice, key == faced, let point = tick.reading?.point
        else {
            targetCandidate = nil
            return nil
        }
        let hit = HitTester.pick(point, targets: tick.targets, current: gazedTarget, margin: tick.hitMargin)
        if hit?.id == gazedTarget {
            targetCandidate = nil
        } else {
            if targetCandidate == nil || targetCandidate!.id != hit?.id { targetCandidate = (hit?.id, tick.t) }
            if tick.t - targetCandidate!.since >= settings.paneDelay {
                gazedTarget = hit?.id
                targetCandidate = nil
                pendingTarget = (hit != nil && hit!.id != tick.focusTarget) ? hit : nil
            }
        }
        if let pt = pendingTarget {
            if pt.id != gazedTarget || pt.id == tick.focusTarget {
                pendingTarget = nil
            } else if typing || mouseBusy {
                waiting = true
            } else {
                pendingTarget = nil
                return .focus(pt)
            }
        }
        return nil
    }
}
