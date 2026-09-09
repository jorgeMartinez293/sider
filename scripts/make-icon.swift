#!/usr/bin/env swift
// Renders Resources/AppIcon.icns from code.
//
// The icon is drawn rather than exported from a design tool so it can be regenerated at any
// size, tweaked in a diff, and never goes missing from the repo as a binary nobody can edit.
// It reuses the panel's own idea: tilted cards fanned out from the left edge.
//
// Usage: swift scripts/make-icon.swift     (run from the project root)

import AppKit
import Foundation

let sizes = [16, 32, 64, 128, 256, 512, 1024]

func draw(size: Int) -> NSBitmapImageRep {
    let side = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icons sit in a rounded square inset from the canvas; ~10% all round and a
    // corner radius near 22% of the square is what the system icons use.
    let inset = side * 0.085
    let box = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let radius = box.width * 0.225
    let squircle = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)

    ctx.saveGState()
    squircle.addClip()
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.36, green: 0.30, blue: 0.86, alpha: 1),
        NSColor(calibratedRed: 0.16, green: 0.12, blue: 0.42, alpha: 1),
    ])!
    gradient.draw(in: box, angle: -68)

    // Three cards, fanned. Each is narrower and dimmer than the one in front of it, which is
    // what the perspective tilt does to the strip in the real panel.
    let cardHeight = box.height * 0.42
    let baseWidth = box.width * 0.40
    for i in 0..<3 {
        let step = CGFloat(i)
        let width = baseWidth * (1 - step * 0.14)
        let x = box.minX + box.width * 0.13 + step * box.width * 0.135
        let y = box.midY - cardHeight / 2 + step * box.height * 0.045
        let card = CGRect(x: x, y: y, width: width, height: cardHeight * (1 - step * 0.10))
        let path = NSBezierPath(roundedRect: card,
                                xRadius: card.width * 0.14, yRadius: card.width * 0.14)
        NSColor(calibratedWhite: 1, alpha: 0.94 - step * 0.30).setFill()
        path.fill()
    }

    // The edge the panel comes out of.
    let edge = CGRect(x: box.minX, y: box.minY, width: box.width * 0.055, height: box.height)
    NSColor(calibratedWhite: 1, alpha: 0.85).setFill()
    NSBezierPath(rect: edge).fill()

    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for size in sizes {
    let rep = draw(size: size)
    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    // iconutil wants icon_<pt>x<pt>.png and icon_<pt>x<pt>@2x.png. One render per pixel size
    // serves both names where they overlap (a 32px file is both 32pt@1x and 16pt@2x).
    var names: [String] = []
    names.append("icon_\(size)x\(size).png")
    if size >= 32 { names.append("icon_\(size / 2)x\(size / 2)@2x.png") }
    for name in names {
        try data.write(to: iconset.appendingPathComponent(name))
    }
}

let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try convert.run()
convert.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(convert.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
