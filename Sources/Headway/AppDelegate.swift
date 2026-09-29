import AppKit
import HeadwayCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let coordinator = Coordinator()
    private var statusMenu: StatusMenu?
    private var welcomeWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var calibration: CalibrationFlow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.boot()
        statusMenu = StatusMenu(coordinator: coordinator, app: self)
        Hotkey.shared.action = { [weak self] in
            MainActor.assumeIsolated { self?.coordinator.togglePause() }
        }
        Hotkey.shared.register(HotkeyChoice.saved)
        if !coordinator.cameraAuthorized || !coordinator.axTrusted || coordinator.calibratedKeys.isEmpty {
            showWelcome()
        }
    }

    func showWelcome() {
        if welcomeWindow == nil {
            let view = WelcomeView(c: coordinator, calibrate: { [weak self] in self?.calibrate() },
                                   close: { [weak self] in self?.welcomeWindow?.close() })
            welcomeWindow = makeWindow("Headway Setup", NSHostingController(rootView: view))
        }
        coordinator.previewRequested = true
        present(welcomeWindow)
    }

    func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(c: coordinator, recalibrate: { [weak self] in self?.calibrate() })
            settingsWindow = makeWindow("Headway Settings", NSHostingController(rootView: view))
        }
        present(settingsWindow)
    }

    /// Calibrates every connected screen, or just the given ones. Screens go left to right.
    func calibrate(only keys: [String]? = nil) {
        guard calibration == nil else { return }
        guard coordinator.cameraAuthorized else {
            showWelcome()
            return
        }
        var screens = Displays.current().sorted { $0.geometry.frame.minX < $1.geometry.frame.minX }
        if let keys { screens = screens.filter { keys.contains($0.geometry.key) } }
        let flow = CalibrationFlow(coordinator: coordinator, screens: screens)
        flow.onFinish = { [weak self] ok, problems in
            self?.calibration = nil
            self?.report(ok: ok, problems: problems)
        }
        calibration = flow
        flow.start()
    }

    private func report(ok: Bool, problems: [String]) {
        if problems == ["Cancelled"] { return }
        let alert = NSAlert()
        if ok, let model = coordinator.model {
            alert.messageText = "Calibration done"
            var text = "Look at a screen and start typing."
            if let agreement = model.agreement(coordinator.store.samples) {
                let pct = Int((agreement * 100).rounded())
                text = "Headway told your screens apart on \(pct)% of the calibration samples.\n\n" + text
                if agreement < 0.85 {
                    alert.messageText = "Calibration done — but your screens are hard to tell apart"
                    text += "\n\nSwitching may be unreliable. Try turning your head (not just your eyes) a little more "
                        + "when you look at each screen, make sure the camera faces you, and recalibrate."
                }
            }
            alert.informativeText = text
        } else {
            alert.messageText = "Calibration didn't finish"
            alert.informativeText = (problems.isEmpty ? "" : problems.joined(separator: "\n") + "\n\n")
                + "Check that the camera can see your face (good light, nothing covering it) and try again."
            alert.alertStyle = .warning
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func makeWindow(_ title: String, _ controller: NSViewController) -> NSWindow {
        let w = NSWindow(contentViewController: controller)
        w.title = title
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        return w
    }

    private func present(_ w: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        w?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === welcomeWindow {
            coordinator.previewRequested = false
        }
    }
}
