import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else { fatalError("Pass the output iconset directory.") }
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        let inset = Double(pixels) * 0.08
        let shape = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset), xRadius: Double(pixels) * 0.19, yRadius: Double(pixels) * 0.19)
        let gradient = NSGradient(starting: NSColor(red: 0.17, green: 0.57, blue: 1, alpha: 1), ending: NSColor(red: 0.16, green: 0.24, blue: 0.78, alpha: 1))!
        gradient.draw(in: shape, angle: -70)
        if let symbol = NSImage(systemSymbolName: "text.book.closed.fill", accessibilityDescription: "Scriv")?.withSymbolConfiguration(.init(pointSize: CGFloat(pixels) * 0.5, weight: .medium)) {
            let white = symbol.copy() as! NSImage
            white.lockFocus(); NSColor.white.set(); NSRect(origin: .zero, size: white.size).fill(using: .sourceAtop); white.unlockFocus()
            let symbolSize = CGFloat(pixels) * 0.57
            white.draw(in: NSRect(x: (CGFloat(pixels)-symbolSize)/2, y: (CGFloat(pixels)-symbolSize)/2, width: symbolSize, height: symbolSize))
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Unable to encode app icon.") }
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
