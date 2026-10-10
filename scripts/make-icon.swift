// Renders the Folio icon into an .iconset folder: a page with one highlighted, annotated line.
// Usage: swift scripts/make-icon.swift build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
import AppKit

let out = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.cgContext.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)

    let body = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 24
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.white.setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(srgbRed: 0.995, green: 0.99, blue: 0.97, alpha: 1),
               ending: NSColor(srgbRed: 0.93, green: 0.915, blue: 0.88, alpha: 1))!.draw(in: body, angle: -90)

    let ink = NSColor(srgbRed: 0.27, green: 0.28, blue: 0.31, alpha: 1)
    let lines: [(y: CGFloat, end: CGFloat)] = [(690, 774), (610, 774), (530, 700), (450, 774), (370, 774), (290, 600)]
    for (i, line) in lines.enumerated() {
        if i == 2 {
            NSColor(srgbRed: 1.0, green: 0.82, blue: 0.2, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 228, y: line.y - 24, width: line.end - 228 + 22, height: 74),
                         xRadius: 12, yRadius: 12).fill()
            NSColor(srgbRed: 0.62, green: 0.42, blue: 0.0, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: line.end + 36, y: line.y + 30, width: 30, height: 30)).fill()
        }
        ink.setFill()
        NSBezierPath(roundedRect: NSRect(x: 250, y: line.y, width: line.end - 250, height: 26), xRadius: 13, yRadius: 13).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
