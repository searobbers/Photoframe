import AppKit

let iconset = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

func drawIcon() {
    let charcoal = NSColor(calibratedRed: 0.19, green: 0.23, blue: 0.22, alpha: 1)
    let orange = NSColor(calibratedRed: 0.79, green: 0.31, blue: 0.18, alpha: 1)

    let background = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 212, yRadius: 212)
    NSColor(calibratedRed: 0.965, green: 0.973, blue: 0.965, alpha: 1).setFill()
    background.fill()
    NSColor(calibratedRed: 0.86, green: 0.89, blue: 0.87, alpha: 1).setStroke()
    background.lineWidth = 8
    background.stroke()

    let frame = NSBezierPath(roundedRect: NSRect(x: 210, y: 228, width: 604, height: 568), xRadius: 46, yRadius: 46)
    frame.lineWidth = 32
    charcoal.setStroke()
    frame.stroke()

    let landscape = NSBezierPath()
    landscape.move(to: NSPoint(x: 294, y: 361))
    landscape.line(to: NSPoint(x: 433, y: 535))
    landscape.line(to: NSPoint(x: 522, y: 436))
    landscape.line(to: NSPoint(x: 617, y: 552))
    landscape.line(to: NSPoint(x: 728, y: 405))
    landscape.lineWidth = 27
    landscape.lineCapStyle = .round
    landscape.lineJoinStyle = .round
    orange.setStroke()
    landscape.stroke()

    let sun = NSBezierPath(ovalIn: NSRect(x: 631, y: 621, width: 82, height: 82))
    orange.setFill()
    sun.fill()
}

for (name, size) in sizes {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Could not create icon bitmap")
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(size) / 1024)
    transform.concat()
    drawIcon()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode icon")
    }
    try data.write(to: iconset.appendingPathComponent(name))
}
