import AppKit
import ApplicationServices

/// Maps an Accessibility window element to its window-server ID. Private, but stable for a decade and
/// used by every window manager on macOS (AltTab, Rectangle, yabai). Fine for a personal build.
@_silgen_name("_AXUIElementGetWindow") @discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Thin, forgiving wrappers over the Accessibility C API.
enum AX {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that leads to System Settings › Privacy & Security › Accessibility.
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func app(_ pid: pid_t) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        // Never let a hung app hang Headway.
        AXUIElementSetMessagingTimeout(el, 0.25)
        return el
    }

    static func value(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v
    }

    static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = value(el, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func elements(_ el: AXUIElement, _ name: String) -> [AXUIElement] {
        guard let v = value(el, name), CFGetTypeID(v) == CFArrayGetTypeID() else { return [] }
        return (v as! [AnyObject]).compactMap {
            CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil
        }
    }

    static func string(_ el: AXUIElement, _ name: String) -> String? {
        value(el, name) as? String
    }

    static func bool(_ el: AXUIElement, _ name: String) -> Bool? {
        (value(el, name) as? NSNumber)?.boolValue
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = value(el, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = value(el, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &origin)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    static func windowID(_ el: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(el, &id) == .success && id != 0 ? id : nil
    }

    @discardableResult
    static func set(_ el: AXUIElement, _ name: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(el, name as CFString, value) == .success
    }

    static func isSettable(_ el: AXUIElement, _ name: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(el, name as CFString, &settable) == .success && settable.boolValue
    }

    @discardableResult
    static func perform(_ el: AXUIElement, _ action: String) -> Bool {
        AXUIElementPerformAction(el, action as CFString) == .success
    }

    static func windows(of pid: pid_t) -> [AXUIElement] {
        elements(app(pid), kAXWindowsAttribute)
    }

    static func window(pid: pid_t, id: CGWindowID) -> AXUIElement? {
        windows(of: pid).first { windowID($0) == id }
    }

    static func focusedWindow(of pid: pid_t) -> AXUIElement? {
        element(app(pid), kAXFocusedWindowAttribute)
    }

    static func focusedElement(of pid: pid_t) -> AXUIElement? {
        element(app(pid), kAXFocusedUIElementAttribute)
    }
}

/// Brings a specific window of another app to the front from the background — the route AltTab,
/// Hammerspoon and yabai use. Public activation APIs can be refused for a background app on macOS 14+
/// (and some apps, e.g. Dia, ignore the Accessibility "frontmost" request). Looked up at run time so a
/// future macOS without these symbols just falls back to the public route.
enum SkyLight {
    private typealias SetFront = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    private typealias PostRecord = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
    private typealias ProcessForPID = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let setFront: SetFront? = symbol(handle, "_SLPSSetFrontProcessWithOptions")
    private static let postRecord: PostRecord? = symbol(handle, "SLPSPostEventRecordTo")
    private static let processForPID: ProcessForPID? = symbol(UnsafeMutableRawPointer(bitPattern: -2), "GetProcessForPID")

    private static func symbol<T>(_ lib: UnsafeMutableRawPointer?, _ name: String) -> T? {
        guard let lib, let p = dlsym(lib, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    static var available: Bool { setFront != nil && postRecord != nil && processForPID != nil }

    static func bringToFront(pid: pid_t, window: CGWindowID) -> Bool {
        guard let setFront, let postRecord, let processForPID else { return false }
        var psn = ProcessSerialNumber()
        guard processForPID(pid, &psn) == noErr else { return false }
        guard setFront(&psn, window, 0x200 /* user generated */) == .success else { return false }
        // Two synthetic window-server records that make the window key (ported via Hammerspoon #370).
        var bytes = [UInt8](repeating: 0, count: 0xF8)
        bytes[0x04] = 0xF8
        bytes[0x3A] = 0x10
        var wid = window
        withUnsafeBytes(of: &wid) { raw in for i in 0..<4 { bytes[0x3C + i] = raw[i] } }
        for i in 0..<0x10 { bytes[0x20 + i] = 0xFF }
        bytes[0x08] = 0x01
        _ = bytes.withUnsafeMutableBufferPointer { postRecord(&psn, $0.baseAddress!) }
        bytes[0x08] = 0x02
        _ = bytes.withUnsafeMutableBufferPointer { postRecord(&psn, $0.baseAddress!) }
        return true
    }
}
