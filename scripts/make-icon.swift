// SPDX-License-Identifier: MIT
// Draws the app icon (a display with an AirPlay triangle) at 1024 px into the PNG given as
// the first argument. Used by scripts/make-icon.sh; no external tools beyond AppKit.
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let size = 1024.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: 824 px rounded square centered in 1024.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let bg = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(calibratedRed: 0.10, green: 0.16, blue: 0.32, alpha: 1),
           ending: NSColor(calibratedRed: 0.20, green: 0.42, blue: 0.85, alpha: 1))!.draw(in: bg, angle: 90)

// Display bezel + screen.
let screen = NSRect(x: 220, y: 400, width: 584, height: 380)
NSColor(white: 0.95, alpha: 1).setFill()
NSBezierPath(roundedRect: screen.insetBy(dx: -22, dy: -22), xRadius: 36, yRadius: 36).fill()
NSColor(calibratedRed: 0.06, green: 0.08, blue: 0.14, alpha: 1).setFill()
NSBezierPath(roundedRect: screen, xRadius: 16, yRadius: 16).fill()

// AirPlay triangle rising out of the screen bottom.
let tri = NSBezierPath()
tri.move(to: NSPoint(x: 512, y: 560))
tri.line(to: NSPoint(x: 652, y: 250))
tri.line(to: NSPoint(x: 372, y: 250))
tri.close()
NSColor.white.setFill()
tri.fill()

// Waves on the screen.
NSColor(calibratedRed: 0.45, green: 0.75, blue: 1, alpha: 1).setStroke()
for (i, r) in [90.0, 160.0].enumerated() {
    let arc = NSBezierPath()
    arc.appendArc(withCenter: NSPoint(x: 512, y: 520), radius: r, startAngle: 35, endAngle: 145)
    arc.lineWidth = 30 - Double(i) * 6
    arc.lineCapStyle = .round
    arc.stroke()
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
