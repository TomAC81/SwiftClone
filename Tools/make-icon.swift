// Draws the SwiftClone app icon and writes an .iconset folder.
// Usage: swift Tools/make-icon.swift <output.iconset>   (then: iconutil -c icns <output.iconset>)
import AppKit

func drawIcon(size s: CGFloat) {
    let ctx = NSGraphicsContext.current!.cgContext
    // macOS icon grid: the rounded square occupies 824/1024 of the canvas.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: s * 0.18, cornerHeight: s * 0.18, transform: nil)

    // Soft drop shadow under the body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(bodyPath); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()

    // Background gradient.
    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()
    let colors = [NSColor(red: 0.16, green: 0.78, blue: 0.72, alpha: 1).cgColor,
                  NSColor(red: 0.07, green: 0.36, blue: 0.80, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.maxY),
                           end: CGPoint(x: body.maxX, y: body.minY), options: [])
    ctx.restoreGState()

    // Two cards: the original (behind, translucent) and its copy (front, solid).
    let card = CGSize(width: s * 0.40, height: s * 0.46)
    let radius = s * 0.055
    let back = CGRect(x: s * 0.215, y: s * 0.385, width: card.width, height: card.height)
    let front = CGRect(x: s * 0.385, y: s * 0.20, width: card.width, height: card.height)

    ctx.addPath(CGPath(roundedRect: back, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.38).cgColor); ctx.fillPath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.035,
                  color: NSColor.black.withAlphaComponent(0.28).cgColor)
    ctx.addPath(CGPath(roundedRect: front, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
    ctx.restoreGState()

    // Check mark on the copy: "copied and verified".
    let check = CGMutablePath()
    check.move(to: CGPoint(x: front.minX + card.width * 0.24, y: front.minY + card.height * 0.50))
    check.addLine(to: CGPoint(x: front.minX + card.width * 0.43, y: front.minY + card.height * 0.33))
    check.addLine(to: CGPoint(x: front.minX + card.width * 0.77, y: front.minY + card.height * 0.67))
    ctx.addPath(check)
    ctx.setStrokeColor(NSColor(red: 0.08, green: 0.50, blue: 0.78, alpha: 1).cgColor)
    ctx.setLineWidth(s * 0.05); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.strokePath()
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(size: CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(pixels: base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(pixels: base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("Wrote \(out.path)")
