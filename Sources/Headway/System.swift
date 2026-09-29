import AppKit
import Carbon.HIToolbox

/// Notices lock, sleep, display sleep, fast user switching and screen arrangement changes.
@MainActor
final class SystemWatcher {
    var onChange: (() -> Void)?
    var onScreensChanged: (() -> Void)?

    private var locked = false
    private var sleeping = false
    private var screensAsleep = false
    private var sessionInactive = false
    private var tokens: [NSObjectProtocol] = []

    var asleep: Bool { locked || sleeping || screensAsleep || sessionInactive }

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        let dist = DistributedNotificationCenter.default()
        func on(_ center: NotificationCenter, _ name: Notification.Name, _ update: @escaping (SystemWatcher) -> Void) {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    update(self)
                    self.onChange?()
                }
            })
        }
        on(ws, NSWorkspace.willSleepNotification) { $0.sleeping = true }
        on(ws, NSWorkspace.didWakeNotification) { $0.sleeping = false }
        on(ws, NSWorkspace.screensDidSleepNotification) { $0.screensAsleep = true }
        on(ws, NSWorkspace.screensDidWakeNotification) { $0.screensAsleep = false }
        on(ws, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionInactive = true }
        on(ws, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionInactive = false }
        on(dist, Notification.Name("com.apple.screenIsLocked")) { $0.locked = true }
        on(dist, Notification.Name("com.apple.screenIsUnlocked")) { $0.locked = false }

        tokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onScreensChanged?() }
        })
    }
}

/// The system-wide pause/resume shortcut. Carbon hot keys need no permission.
enum HotkeyChoice: String, CaseIterable, Identifiable {
    case shiftCmdG
    case ctrlOptCmdG
    case off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .shiftCmdG: return "⇧⌘G"
        case .ctrlOptCmdG: return "⌃⌥⌘G"
        case .off: return "None"
        }
    }

    fileprivate var modifiers: UInt32? {
        switch self {
        case .shiftCmdG: return UInt32(cmdKey | shiftKey)
        case .ctrlOptCmdG: return UInt32(cmdKey | optionKey | controlKey)
        case .off: return nil
        }
    }

    static var saved: HotkeyChoice {
        get { HotkeyChoice(rawValue: UserDefaults.standard.string(forKey: "hotkey") ?? "") ?? .shiftCmdG }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "hotkey") }
    }
}

final class Hotkey {
    static let shared = Hotkey()
    var action: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var installed = false

    func register(_ choice: HotkeyChoice) {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        guard let mods = choice.modifiers else { return }
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), hotkeyPressed, 1, &spec, nil, nil)
            installed = true
        }
        let id = EventHotKeyID(signature: OSType(0x4844_5759), id: 1)  // 'HDWY'
        RegisterEventHotKey(UInt32(kVK_ANSI_G), mods, id, GetApplicationEventTarget(), 0, &ref)
    }
}

private func hotkeyPressed(_ next: EventHandlerCallRef?, _ event: EventRef?, _ user: UnsafeMutableRawPointer?) -> OSStatus {
    DispatchQueue.main.async { Hotkey.shared.action?() }
    return noErr
}
