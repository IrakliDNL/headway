import AppKit
import Combine

/// The eye in the menu bar and its menu.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let coordinator: Coordinator
    private unowned let app: AppDelegate
    private var bag = Set<AnyCancellable>()

    init(coordinator: Coordinator, app: AppDelegate) {
        self.coordinator = coordinator
        self.app = app
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        coordinator.$status.combineLatest(coordinator.$suggestRecalibration, coordinator.$faceVisible)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshIcon() }
            .store(in: &bag)
        refreshIcon()
    }

    private func refreshIcon() {
        let s = coordinator.status
        let symbol: String
        switch s {
        case .paused, .asleep: symbol = "eye.slash"
        case .needsCamera, .needsAccessibility, .needsCalibration, .cameraProblem: symbol = "eye.trianglebadge.exclamationmark"
        default: symbol = coordinator.suggestRecalibration ? "eye.trianglebadge.exclamationmark" : "eye"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Headway")
        image?.isTemplate = true
        item.button?.image = image
        // Dim the eye while it can't see you, so a glance at the menu bar tells you.
        item.button?.alphaValue = (s == .noFace || s == .lookingAway) ? 0.45 : 1
        item.button?.toolTip = "Headway — \(s.title)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let c = coordinator

        let status = NSMenuItem(title: c.status.title, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        switch c.status {
        case .needsCamera:
            menu.addItem(action("Allow Camera…") { [app] in app.showWelcome() })
        case .needsAccessibility:
            menu.addItem(action("Grant Accessibility Permission…") { [app] in app.showWelcome() })
        default:
            break
        }
        for screen in c.uncalibratedScreens where !c.calibratedKeys.isEmpty {
            menu.addItem(action("Calibrate \(screen.name)…") { [app] in app.calibrate(only: [screen.key]) })
        }
        if c.suggestRecalibration {
            menu.addItem(action("Accuracy has dropped — Recalibrate…") { [app] in app.calibrate() })
        }
        menu.addItem(.separator())

        let pause = action(c.paused ? "Resume Tracking" : "Pause Tracking") { [c] in c.togglePause() }
        if HotkeyChoice.saved == .shiftCmdG {
            pause.keyEquivalent = "g"
            pause.keyEquivalentModifierMask = [.command, .shift]
        } else if HotkeyChoice.saved == .ctrlOptCmdG {
            pause.keyEquivalent = "g"
            pause.keyEquivalentModifierMask = [.command, .option, .control]
        }
        menu.addItem(pause)

        let dot = action("Show Gaze Dot") { [c] in c.update { $0.showGazeDot.toggle() } }
        dot.state = c.settings.showGazeDot ? .on : .off
        menu.addItem(dot)

        menu.addItem(action("Recalibrate…") { [app] in app.calibrate() })
        let settings = action("Settings…") { [app] in app.showSettings() }
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(action("Setup Guide…") { [app] in app.showWelcome() })
        menu.addItem(.separator())
        let quit = action("Quit Headway") { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func action(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, run: run)
        return item
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { run() }
}
