// Renders a placeholder 1024px app icon (charcoal gradient + rhombus) until real artwork exists.
// usage: xcrun swift scripts/placeholder-icon.swift <out.png>
import AppKit

let out = CommandLine.arguments.dropFirst().first ?? "icon-1024.png"
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
let inset: CGFloat = 100 // macOS icon grid: artwork sits inside a 824pt rounded square
let square = NSRect(x: inset, y: inset, width: 1024 - 2 * inset, height: 1024 - 2 * inset)
let path = NSBezierPath(roundedRect: square, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(red: 0.30, green: 0.36, blue: 0.44, alpha: 1), NSColor(red: 0.10, green: 0.13, blue: 0.18, alpha: 1)])!
    .draw(in: path, angle: -90)
let rhombus = NSBezierPath()
let c = NSPoint(x: 512, y: 512)
rhombus.move(to: NSPoint(x: c.x, y: c.y + 260))
rhombus.line(to: NSPoint(x: c.x + 200, y: c.y))
rhombus.line(to: NSPoint(x: c.x, y: c.y - 260))
rhombus.line(to: NSPoint(x: c.x - 200, y: c.y))
rhombus.close()
rhombus.lineWidth = 34
rhombus.lineJoinStyle = .round
NSColor(white: 1, alpha: 0.92).setStroke()
rhombus.stroke()
image.unlockFocus()
let tiff = image.tiffRepresentation!
let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
