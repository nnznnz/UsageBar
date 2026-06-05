import AppKit

// Renders the UsageBar app icon: a generic "stats" bar-chart on a rounded
// indigo squircle. Pure AppKit, no assets to ship — the icon is reproducible
// from this code. Usage: swift scripts/make-icon.swift <output-1024.png>

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"
let S: CGFloat = 1024

guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let gctx = NSGraphicsContext(bitmapImageRep: rep) else {
    fatalError("could not create bitmap context")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = gctx
let ctx = gctx.cgContext
let cs = CGColorSpaceCreateDeviceRGB()

// Rounded-square background with a vertical indigo gradient.
let inset: CGFloat = 76
let bgRect = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
let radius = bgRect.width * 0.2237
let bgPath = CGPath(roundedRect: bgRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()
let top = CGColor(colorSpace: cs, components: [0.36, 0.42, 0.96, 1])!
let bottom = CGColor(colorSpace: cs, components: [0.20, 0.25, 0.78, 1])!
let grad = CGGradient(colorsSpace: cs, colors: [top, bottom] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])
ctx.restoreGState()

// Four ascending white bars (the "stats" mark).
ctx.setFillColor(CGColor(colorSpace: cs, components: [1, 1, 1, 0.96])!)
let barW: CGFloat = 96
let gap: CGFloat = 44
let heights: [CGFloat] = [180, 288, 396, 504]
let baseY: CGFloat = 276
let groupW = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
var x = (S - groupW) / 2
for h in heights {
    let bar = CGRect(x: x, y: baseY, width: barW, height: h)
    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 26, cornerHeight: 26, transform: nil))
    ctx.fillPath()
    x += barW + gap
}

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not encode PNG")
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
