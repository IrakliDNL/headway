// Draws Resources/AppIcon.icns: a white eye with a turning arrow on a deep teal-to-indigo tile.
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let tile = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let path = NSBezierPath(roundedRect: tile, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(colors: [NSColor(red: 0.05, green: 0.45, blue: 0.5, alpha: 1), NSColor(red: 0.2, green: 0.2, blue: 0.55, alpha: 1)])!
        .draw(in: path, angle: -60)
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.36, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let eye = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let r = NSRect(x: (s - eye.size.width) / 2, y: s * 0.44, width: eye.size.width, height: eye.size.height)
        eye.draw(in: r)
    }
    let arrowConfig = NSImage.SymbolConfiguration(pointSize: s * 0.2, weight: .bold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.white.withAlphaComponent(0.85)]))
    if let arrow = NSImage(systemSymbolName: "arrow.left.and.right", accessibilityDescription: nil)?.withSymbolConfiguration(arrowConfig) {
        arrow.draw(in: NSRect(x: (s - arrow.size.width) / 2, y: s * 0.22, width: arrow.size.width, height: arrow.size.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let set = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: set.appendingPathComponent("icon_\(name).png"))
}
