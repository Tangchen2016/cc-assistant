import AppKit
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let source = NSImage(contentsOf: root.appendingPathComponent("work/native-app-stage/AppIcon.iconset/icon_512x512@2x.png"))!
let image = source.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(red: 217 / 255, green: 119 / 255, blue: 87 / 255, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
context.draw(image, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
for folder in ["AppIcon.appiconset", "BrandIcon.imageset"] {
    let url = root.appendingPathComponent("ios/Resources/Assets.xcassets/\(folder)/AppIcon.png")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination))
}
