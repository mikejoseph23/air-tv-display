#!/usr/bin/env swift
// SPDX-License-Identifier: MIT
// Generate the DMG install-window background art (adapted from mac-resource-monitor's):
// a near-white window with a blue "drag →" arrow between the app icon (left) and the
// /Applications alias (right), the instruction text below, and a faint AirPlay-style
// motif (concentric arcs) echoing the app icon.
//
// Draws guidance ONLY — the icon slots are left empty; Finder paints the real
// app icon and /Applications alias on top at the coordinates make-dmg.sh
// positions them (150,185 and 450,185 in a 600x400 pt window).
//
// Emits two files so make-dmg.sh can fuse them into a HiDPI TIFF
// (tiffutil -cathidpicheck): background.png (600x400, 1x) and
// background@2x.png (1200x800, retina). Argument: output directory.
import AppKit

guard CommandLine.arguments.count == 2 else {
    fputs("usage: draw-dmg-background.swift <output-dir>\n", stderr)
    exit(2)
}
let outDir = CommandLine.arguments[1]

// Logical window (points). Must agree with make-dmg.sh's window + icon positions.
let W = 600, H = 400
let appCenter  = NSPoint(x: 150, y: 185)   // left slot  (Finder paints app icon)
let appsCenter = NSPoint(x: 450, y: 185)   // right slot (Finder paints /Applications)

// Palette keyed to the app icon (navy → blue gradient, light-blue accent).
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r/255, green: g/255, blue: b/255, alpha: a)
}
let bgTop    = rgb(248, 249, 252)     // near-white, faint cool tint
let bgBottom = rgb(228, 234, 245)
let arrowCol = rgb(51, 107, 217)      // the icon's gradient blue (0.20, 0.42, 0.85)
let textCol  = rgb(26, 41, 82)        // the icon's navy, legible on near-white
let motifCol = rgb(115, 191, 255)     // the icon's light-blue accent (drawn low-alpha)

func render(scale: Int) -> NSBitmapImageRep {
    let pw = W * scale, ph = H * scale
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 32)!
    let ctx = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    ctx.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

    let wf = CGFloat(W), hf = CGFloat(H)

    // Vertical gradient background.
    NSGradient(colors: [bgTop, bgBottom])!.draw(in: NSRect(x: 0, y: 0, width: wf, height: hf), angle: -90)

    // AppKit y grows upward; Finder positions are from the top. Convert.
    func flip(_ y: CGFloat) -> CGFloat { hf - y }

    // Faint AirPlay-style motif along the bottom: concentric arcs over a small triangle.
    let motifCenter = NSPoint(x: wf / 2, y: flip(372))
    for (i, r) in [CGFloat(14), 26, 38].enumerated() {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: motifCenter, radius: r, startAngle: 20, endAngle: 160)
        arc.lineWidth = 4
        arc.lineCapStyle = .round
        motifCol.withAlphaComponent(0.30 - CGFloat(i) * 0.06).setStroke()
        arc.stroke()
    }
    let tri = NSBezierPath()
    tri.move(to: NSPoint(x: motifCenter.x, y: motifCenter.y + 4))
    tri.line(to: NSPoint(x: motifCenter.x - 10, y: motifCenter.y - 10))
    tri.line(to: NSPoint(x: motifCenter.x + 10, y: motifCenter.y - 10))
    tri.close()
    motifCol.withAlphaComponent(0.30).setFill()
    tri.fill()

    // Arrow: app slot → Applications slot.
    let ay = flip(appCenter.y)
    let x0 = appCenter.x + 74          // just right of the app icon
    let x1 = appsCenter.x - 74         // just left of the alias
    let shaft = NSBezierPath()
    shaft.lineWidth = 9
    shaft.lineCapStyle = .round
    shaft.move(to: NSPoint(x: x0, y: ay))
    shaft.line(to: NSPoint(x: x1 - 16, y: ay))
    arrowCol.setStroke()
    shaft.stroke()
    let head = NSBezierPath()
    let headLen: CGFloat = 24, spread: CGFloat = 20
    head.move(to: NSPoint(x: x1, y: ay))
    head.line(to: NSPoint(x: x1 - headLen, y: ay + spread))
    head.line(to: NSPoint(x: x1 - headLen, y: ay - spread))
    head.close()
    arrowCol.setFill()
    head.fill()

    // Instruction text, centered, below the icon row (clear of Finder's labels).
    let instr = "Drag to Applications to install"
    let font = NSFont.systemFont(ofSize: 17, weight: .medium)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textCol]
    let size = (instr as NSString).size(withAttributes: attrs)
    (instr as NSString).draw(at: NSPoint(x: (wf - size.width)/2, y: flip(300) - size.height/2),
                             withAttributes: attrs)

    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

func write(_ bitmap: NSBitmapImageRep, to path: String) {
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        fputs("Failed to encode PNG: \(path)\n", stderr); exit(1)
    }
    try! data.write(to: URL(fileURLWithPath: path))
    fputs("wrote \(path)\n", stderr)
}

write(render(scale: 1), to: "\(outDir)/background.png")
write(render(scale: 2), to: "\(outDir)/background@2x.png")
