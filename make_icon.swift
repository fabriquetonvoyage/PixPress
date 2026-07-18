import AppKit
import Foundation

// Renders a simple app icon (gradient rounded square + photo glyph) and builds AppIcon.icns.

func drawIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext

    // Transparent background; rounded square artwork with padding.
    let inset = size * 0.08
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.225
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    path.addClip()

    // Diagonal gradient (indigo -> teal).
    let colors = [
        NSColor(calibratedRed: 0.36, green: 0.32, blue: 0.86, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.18, green: 0.62, blue: 0.86, alpha: 1).cgColor,
    ] as CFArray
    let space = CGColorSpaceCreateDeviceRGB()
    if let grad = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(grad, start: CGPoint(x: rect.minX, y: rect.maxY),
                               end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    }

    // White photo glyph.
    let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .semibold)
    if let sym = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let tinted = NSImage(size: sym.size)
        tinted.lockFocus()
        NSColor.white.set()
        let r = NSRect(origin: .zero, size: sym.size)
        sym.draw(in: r)
        r.fill(using: .sourceAtop)
        tinted.unlockFocus()
        let gw = sym.size.width, gh = sym.size.height
        let gr = CGRect(x: (size - gw) / 2, y: (size - gh) / 2, width: gw, height: gh)
        tinted.draw(in: gr)
    }

    img.unlockFocus()
    return img
}

func png(_ image: NSImage, _ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(size: CGFloat(px)).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let specs: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in specs {
    let data = png(NSImage(), px)
    try! data.write(to: iconset.appendingPathComponent("\(name).png"))
}
print("iconset écrit")
