import AppKit
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let sizes: [(Int, String, String)] = [(16,"16x16","1x"),(32,"16x16","2x"),(32,"32x32","1x"),(64,"32x32","2x"),(128,"128x128","1x"),(256,"128x128","2x"),(256,"256x256","1x"),(512,"256x256","2x"),(512,"512x512","1x"),(1024,"512x512","2x")]
var entries: [[String: String]] = []
for (pixels, size, scale) in sizes {
    let filename = "bezel-\(size)-\(scale).png"
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let unit = CGFloat(pixels) / 1024
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: unit, y: unit)
    let base = NSBezierPath(roundedRect: NSRect(x: 84, y: 84, width: 856, height: 856), xRadius: 194, yRadius: 194)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 36
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.set()
    NSGradient(starting: NSColor(calibratedWhite: 1, alpha: 1), ending: NSColor(calibratedWhite: 0.88, alpha: 1))!.draw(in: base, angle: -90)
    NSShadow().set()
    NSColor.white.withAlphaComponent(0.8).setStroke()
    base.lineWidth = 4
    base.stroke()
    let display = NSBezierPath(roundedRect: NSRect(x: 192, y: 260, width: 640, height: 504), xRadius: 76, yRadius: 76)
    NSGradient(starting: NSColor(calibratedWhite: 0.12, alpha: 1), ending: NSColor(calibratedWhite: 0.03, alpha: 1))!.draw(in: display, angle: -90)
    NSColor(calibratedRed: 0.18, green: 0.50, blue: 0.95, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 222, y: 290, width: 580, height: 444), xRadius: 49, yRadius: 49).fill()
    NSColor(calibratedRed: 0.33, green: 0.70, blue: 1, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 249, y: 318, width: 250, height: 386), xRadius: 26, yRadius: 26).fill()
    NSColor.white.withAlphaComponent(0.16).setFill()
    NSBezierPath(roundedRect: NSRect(x: 519, y: 318, width: 254, height: 176), xRadius: 26, yRadius: 26).fill()
    NSBezierPath(roundedRect: NSRect(x: 519, y: 516, width: 254, height: 188), xRadius: 26, yRadius: 26).fill()
    NSColor(calibratedWhite: 0.06, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 397, y: 656, width: 230, height: 98), xRadius: 31, yRadius: 31).fill()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(filename))
    entries.append(["idiom":"mac", "size":size, "scale":scale, "filename":filename])
}
let manifest: [String: Any] = ["images": entries, "info": ["author":"xcode", "version":1]]
try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted,.sortedKeys]).write(to: destination.appendingPathComponent("Contents.json"))
