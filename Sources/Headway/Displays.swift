import AppKit
import HeadwayCore

/// Screens and the two coordinate systems: Cocoa (origin bottom-left of the main display, y up) and
/// global/CG (origin top-left of the main display, y down). Headway's models all use global coordinates.
enum Displays {
    struct Screen {
        let nsScreen: NSScreen
        let id: CGDirectDisplayID
        let geometry: ScreenGeometry
    }

    static func current() -> [Screen] {
        var seen = [String: Int]()
        return NSScreen.screens.compactMap { s -> Screen? in
            guard let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
            var key = "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
            // Two identical monitors without serial numbers: tell them apart by order.
            let n = seen[key, default: 0]
            seen[key] = n + 1
            if n > 0 { key += "#\(n)" }
            return Screen(nsScreen: s, id: id, geometry: ScreenGeometry(key: key, name: s.localizedName, frame: CGDisplayBounds(id)))
        }
    }

    private static var mainHeight: CGFloat { CGDisplayBounds(CGMainDisplayID()).height }

    static func toGlobal(_ p: NSPoint) -> CGPoint {
        CGPoint(x: p.x, y: mainHeight - p.y)
    }

    static func toCocoa(_ p: CGPoint) -> NSPoint {
        NSPoint(x: p.x, y: mainHeight - p.y)
    }

    static func toCocoa(_ r: CGRect) -> NSRect {
        NSRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
    }

    static func mouseLocation() -> CGPoint {
        toGlobal(NSEvent.mouseLocation)
    }

    static func screen(containing p: CGPoint, in screens: [ScreenGeometry]) -> ScreenGeometry? {
        screens.first { $0.frame.contains(p) }
    }

    /// The screen a window belongs to: the one holding its centre, else the one it overlaps most.
    static func screen(for rect: CGRect, in screens: [ScreenGeometry]) -> ScreenGeometry? {
        if let s = screen(containing: CGPoint(x: rect.midX, y: rect.midY), in: screens) { return s }
        return screens.max { a, b in
            let ia = a.frame.intersection(rect), ib = b.frame.intersection(rect)
            return (ia.isNull ? 0 : ia.width * ia.height) < (ib.isNull ? 0 : ib.width * ib.height)
        }
    }
}
