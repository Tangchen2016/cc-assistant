import Cocoa

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(size) / 100, y: CGFloat(size) / 100)
    context.translateBy(x: 0, y: 100)
    context.scaleBy(x: 1, y: -1)
    let scale = CGFloat(size) / 100
    let rgb = { (r: CGFloat, g: CGFloat, b: CGFloat) in NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1).cgColor }
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    // Body on the macOS icon grid (824/1024) with a warm vertical gradient.
    let body = CGPath(roundedRect: CGRect(x: 10, y: 10, width: 80, height: 80), cornerWidth: 18, cornerHeight: 18, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -1.2 * scale), blur: 2.5 * scale, color: NSColor(white: 0, alpha: 0.25).cgColor)
    context.addPath(body)
    context.setFillColor(rgb(214, 112, 78))
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(body)
    context.clip()
    let background = CGGradient(colorsSpace: space, colors: [rgb(238, 146, 106), rgb(196, 92, 62)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(background, start: CGPoint(x: 50, y: 10), end: CGPoint(x: 50, y: 90), options: [])
    context.restoreGState()
    // White shield, same mark as the menu bar icon.
    let shield = CGMutablePath()
    shield.move(to: CGPoint(x: 27, y: 30))
    shield.addCurve(to: CGPoint(x: 50, y: 21), control1: CGPoint(x: 36, y: 29), control2: CGPoint(x: 44, y: 26))
    shield.addCurve(to: CGPoint(x: 73, y: 30), control1: CGPoint(x: 56, y: 26), control2: CGPoint(x: 64, y: 29))
    shield.addLine(to: CGPoint(x: 73, y: 48))
    shield.addCurve(to: CGPoint(x: 50, y: 81), control1: CGPoint(x: 73, y: 64), control2: CGPoint(x: 63, y: 75))
    shield.addCurve(to: CGPoint(x: 27, y: 48), control1: CGPoint(x: 37, y: 75), control2: CGPoint(x: 27, y: 64))
    shield.closeSubpath()
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -1 * scale), blur: 3 * scale, color: NSColor(srgbRed: 0.35, green: 0.1, blue: 0.02, alpha: 0.35).cgColor)
    context.addPath(shield)
    context.setFillColor(.white)
    context.fillPath()
    context.restoreGState()
    // "C" as an open ring, stroked with the brand orange.
    context.setStrokeColor(rgb(210, 104, 70))
    context.setLineWidth(7)
    context.setLineCap(.round)
    context.addArc(center: CGPoint(x: 50, y: 49), radius: 11.5, startAngle: .pi * 0.25, endAngle: .pi * 1.75, clockwise: false)
    context.strokePath()
    NSGraphicsContext.restoreGraphicsState()
    let data = bitmap.representation(using: .png, properties: [:])!
    var names: [String] = []
    if size <= 512 { names.append("icon_\(size)x\(size).png") }
    if size >= 32 { names.append("icon_\(size / 2)x\(size / 2)@2x.png") }
    for name in names { try data.write(to: directory.appendingPathComponent(name)) }
}
