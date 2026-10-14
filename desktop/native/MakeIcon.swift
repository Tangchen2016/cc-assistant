import Cocoa

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let scale = CGFloat(size)
    let background = NSBezierPath(roundedRect: NSRect(x: scale * 0.07, y: scale * 0.07, width: scale * 0.86, height: scale * 0.86), xRadius: scale * 0.19, yRadius: scale * 0.19)
    NSColor(calibratedRed: 0.03, green: 0.48, blue: 0.47, alpha: 1).setFill(); background.fill()
    if let symbol = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: scale * 0.53, weight: .medium)) {
        let symbolSize = symbol.size
        let factor = scale * 0.57 / max(symbolSize.width, symbolSize.height)
        let rect = NSRect(x: (scale - symbolSize.width * factor) / 2, y: (scale - symbolSize.height * factor) / 2, width: symbolSize.width * factor, height: symbolSize.height * factor)
        symbol.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: symbolSize).fill(using: .sourceAtop)
        symbol.unlockFocus()
        symbol.draw(in: rect)
    }
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    let data = bitmap.representation(using: .png, properties: [:])!
    var names: [String] = []
    if size <= 512 { names.append("icon_\(size)x\(size).png") }
    if size >= 32 { names.append("icon_\(size / 2)x\(size / 2)@2x.png") }
    for name in names { try data.write(to: directory.appendingPathComponent(name)) }
}
