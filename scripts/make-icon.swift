// Renders the Saltbush icon into an .iconset folder: a page with a highlighted line and a note circle,
// on a saltbush-coloured tile.
// Usage: swift scripts/make-icon.swift build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
import AppKit

let out = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func rgb(_ hex: Int) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.cgContext.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)

    // Saltbush tile.
    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 24
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    rgb(0xA3B8B4).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: rgb(0xB9CBC6), ending: rgb(0x8AA29C))!.draw(in: tile, angle: -90)

    // Page.
    let page = NSRect(x: 214, y: 190, width: 596, height: 650)
    NSGraphicsContext.saveGraphicsState()
    let pageShadow = NSShadow()
    pageShadow.shadowColor = NSColor(srgbRed: 0.12, green: 0.2, blue: 0.18, alpha: 0.3)
    pageShadow.shadowOffset = NSSize(width: 0, height: -8)
    pageShadow.shadowBlurRadius = 18
    pageShadow.set()
    rgb(0xFFFDF8).setFill()
    NSBezierPath(roundedRect: page, xRadius: 26, yRadius: 26).fill()
    NSGraphicsContext.restoreGraphicsState()

    // Text lines, one highlighted, with a note circle in the margin beside it.
    let ink = rgb(0x4A5552)
    let lines: [(y: CGFloat, end: CGFloat)] = [(740, 740), (670, 740), (590, 700), (510, 740), (440, 740), (370, 650), (300, 710)]
    for (i, line) in lines.enumerated() {
        if i == 2 {
            rgb(0xF5CD4C).setFill()
            NSBezierPath(roundedRect: NSRect(x: 318, y: line.y - 26, width: line.end - 318 + 18, height: 70),
                         xRadius: 12, yRadius: 12).fill()
            let circle = NSBezierPath(ovalIn: NSRect(x: 244, y: line.y - 22, width: 60, height: 60))
            rgb(0xF5CD4C).setFill()
            circle.fill()
            rgb(0x9C7A12).setStroke()
            circle.lineWidth = 7
            circle.stroke()
        }
        ink.setFill()
        NSBezierPath(roundedRect: NSRect(x: 334, y: line.y, width: line.end - 334, height: 18), xRadius: 9, yRadius: 9).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
