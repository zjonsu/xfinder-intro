#!/usr/bin/env swift
// Draws the XFinder app icon — a macOS Finder–style rounded square with a
// two-tone (light/blue) split face, plus an "X" motif as the nose.
// Renders every iconset size to PNG; the companion bundle step runs `iconutil`.
import AppKit
import CoreGraphics

// MARK: - Palette
let lightTop = NSColor(srgbRed: 0.85, green: 0.93, blue: 1.00, alpha: 1).cgColor
let lightBot = NSColor(srgbRed: 0.63, green: 0.83, blue: 0.99, alpha: 1).cgColor
let blueTop  = NSColor(srgbRed: 0.30, green: 0.64, blue: 0.98, alpha: 1).cgColor
let blueBot  = NSColor(srgbRed: 0.10, green: 0.45, blue: 0.92, alpha: 1).cgColor
let navy     = NSColor(srgbRed: 0.05, green: 0.16, blue: 0.40, alpha: 1).cgColor

func makeIcon(_ px: Int) -> Data {
    let s = CGFloat(px)
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Rounded-square plate, inset to leave the standard macOS icon margin.
    let inset = s * 0.085
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.224
    let plate = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Soft drop shadow under the plate.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012),
                  blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.22).cgColor)
    ctx.addPath(plate); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
    ctx.restoreGState()

    // Clip everything to the plate.
    ctx.saveGState()
    ctx.addPath(plate); ctx.clip()

    // Left half — light blue.
    ctx.saveGState()
    ctx.clip(to: CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height))
    ctx.drawLinearGradient(CGGradient(colorsSpace: cs, colors: [lightTop, lightBot] as CFArray, locations: [0, 1])!,
                           start: CGPoint(x: rect.midX, y: rect.maxY),
                           end: CGPoint(x: rect.midX, y: rect.minY), options: [])
    ctx.restoreGState()

    // Right half — deeper blue.
    ctx.saveGState()
    ctx.clip(to: CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height))
    ctx.drawLinearGradient(CGGradient(colorsSpace: cs, colors: [blueTop, blueBot] as CFArray, locations: [0, 1])!,
                           start: CGPoint(x: rect.midX, y: rect.maxY),
                           end: CGPoint(x: rect.midX, y: rect.minY), options: [])
    ctx.restoreGState()

    // Subtle divider line down the middle.
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
    ctx.setLineWidth(max(1, s * 0.006))
    ctx.move(to: CGPoint(x: rect.midX, y: rect.minY))
    ctx.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
    ctx.strokePath()

    // Face geometry (CG origin is bottom-left, so "up" = larger y).
    let w = rect.width
    let cx = rect.midX
    let eyeY  = rect.minY + rect.height * 0.66
    let eyeDX = w * 0.135
    let eyeW  = w * 0.066
    let eyeH  = w * 0.150
    ctx.setFillColor(navy)
    for ex in [cx - eyeDX, cx + eyeDX] {
        let eye = CGRect(x: ex - eyeW / 2, y: eyeY - eyeH / 2, width: eyeW, height: eyeH)
        ctx.addPath(CGPath(roundedRect: eye, cornerWidth: eyeW / 2, cornerHeight: eyeW / 2, transform: nil))
    }
    ctx.fillPath()

    // "X" motif as the nose, centred between eyes and smile.
    let xY = rect.minY + rect.height * 0.455
    let xR = w * 0.085
    ctx.setStrokeColor(navy)
    ctx.setLineWidth(w * 0.040)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: cx - xR, y: xY + xR)); ctx.addLine(to: CGPoint(x: cx + xR, y: xY - xR))
    ctx.move(to: CGPoint(x: cx + xR, y: xY + xR)); ctx.addLine(to: CGPoint(x: cx - xR, y: xY - xR))
    ctx.strokePath()

    // Smile — bottom arc of a circle centred above the mouth.
    let smileR = w * 0.19
    let smileCY = rect.minY + rect.height * 0.40
    ctx.setLineWidth(w * 0.050)
    ctx.addArc(center: CGPoint(x: cx, y: smileCY), radius: smileR,
               startAngle: .pi * 1.18, endAngle: .pi * 1.82, clockwise: false)
    ctx.strokePath()

    // Glossy top highlight.
    ctx.saveGState()
    ctx.addPath(plate); ctx.clip()
    let gloss = CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
    ctx.clip(to: gloss)
    ctx.drawLinearGradient(CGGradient(colorsSpace: cs,
                                      colors: [NSColor.white.withAlphaComponent(0.18).cgColor,
                                               NSColor.white.withAlphaComponent(0.0).cgColor] as CFArray,
                                      locations: [0, 1])!,
                           start: CGPoint(x: rect.midX, y: rect.maxY),
                           end: CGPoint(x: rect.midX, y: rect.midY), options: [])
    ctx.restoreGState()

    ctx.restoreGState() // unclip plate

    let img = ctx.makeImage()!
    return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!
}

// MARK: - Write the iconset
let fm = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let setDir = root.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: setDir)
try! fm.createDirectory(at: setDir, withIntermediateDirectories: true)

let entries: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in entries {
    try! makeIcon(px).write(to: setDir.appendingPathComponent(name))
}
print("wrote \(setDir.path)")
