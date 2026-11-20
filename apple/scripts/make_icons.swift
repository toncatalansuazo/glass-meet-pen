#!/usr/bin/env swift
// Generates the Glasspen Meet (macOS) and Glasspen Remote (iOS) app icons.
// Usage: make icons   (or, from the apple/ folder: swift scripts/make_icons.swift)
import AppKit
import CoreGraphics

func drawIcon(size: CGFloat, ctx: CGContext, macStyle: Bool, remote: Bool) {
    let full = CGRect(x: 0, y: 0, width: size, height: size)
    // macOS icons sit on a rounded square inset within the canvas; iOS icons are full-bleed (the OS masks them).
    let inset = macStyle ? size * 0.1 : 0
    let body = full.insetBy(dx: inset, dy: inset)
    let radius = macStyle ? body.width * 0.225 : 0

    ctx.saveGState()
    let bodyPath = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
    if macStyle {
        ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.01), blur: size * 0.03,
                      color: CGColor(gray: 0, alpha: 0.35))
    }
    ctx.addPath(bodyPath)
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let colors = remote
        ? [CGColor(srgbRed: 0.07, green: 0.55, blue: 0.95, alpha: 1), CGColor(srgbRed: 0.33, green: 0.20, blue: 0.85, alpha: 1)]
        : [CGColor(srgbRed: 0.40, green: 0.20, blue: 0.90, alpha: 1), CGColor(srgbRed: 0.95, green: 0.25, blue: 0.55, alpha: 1)]
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])

    let u = body.width / 100
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: body.minX + x * u, y: body.minY + y * u) }

    // Faint "screen" frame.
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.28))
    ctx.setLineWidth(3.2 * u)
    let screen = CGRect(x: body.minX + 16 * u, y: body.minY + 24 * u, width: 68 * u, height: 50 * u)
    ctx.addPath(CGPath(roundedRect: screen, cornerWidth: 6 * u, cornerHeight: 6 * u, transform: nil))
    ctx.strokePath()

    // Brush swoosh across the screen.
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.88, blue: 0.2, alpha: 1))
    ctx.setLineWidth(8 * u)
    ctx.move(to: p(24, 40))
    ctx.addCurve(to: p(52, 52), control1: p(32, 62), control2: p(42, 30))
    ctx.addCurve(to: p(76, 60), control1: p(60, 70), control2: p(70, 62))
    ctx.strokePath()

    if remote {
        // Phone silhouette in the bottom-right corner.
        let phone = CGRect(x: body.minX + 62 * u, y: body.minY + 8 * u, width: 26 * u, height: 44 * u)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.addPath(CGPath(roundedRect: phone, cornerWidth: 5 * u, cornerHeight: 5 * u, transform: nil))
        ctx.fillPath()
        ctx.setFillColor(colors[1])
        ctx.addPath(CGPath(roundedRect: phone.insetBy(dx: 2.5 * u, dy: 4 * u), cornerWidth: 3 * u, cornerHeight: 3 * u, transform: nil))
        ctx.fillPath()
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.88, blue: 0.2, alpha: 1))
        ctx.setLineWidth(3 * u)
        ctx.move(to: p(68, 20)); ctx.addCurve(to: p(82, 38), control1: p(74, 36), control2: p(76, 22)); ctx.strokePath()
    } else {
        // Brush tip dot.
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.addEllipse(in: CGRect(x: body.minX + 72 * u, y: body.minY + 55 * u, width: 9 * u, height: 9 * u))
        ctx.fillPath()
    }
    ctx.restoreGState()
}

func png(size: Int, macStyle: Bool, remote: Bool, to url: URL) {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: macStyle ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)!
    if !macStyle { ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: size, height: size)) }
    drawIcon(size: CGFloat(size), ctx: ctx, macStyle: macStyle, remote: remote)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let fm = FileManager.default

// macOS
let macSet = root.appendingPathComponent("ScreenBrush/Assets.xcassets/AppIcon.appiconset")
try fm.createDirectory(at: macSet, withIntermediateDirectories: true)
var macImages: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        png(size: base * scale, macStyle: true, remote: false, to: macSet.appendingPathComponent(name))
        macImages.append(["idiom": "mac", "size": "\(base)x\(base)", "scale": "\(scale)x", "filename": name])
    }
}
let macJSON = try JSONSerialization.data(withJSONObject: ["images": macImages, "info": ["version": 1, "author": "xcode"]], options: [.prettyPrinted, .sortedKeys])
try macJSON.write(to: macSet.appendingPathComponent("Contents.json"))

// iOS (single 1024 universal icon)
let iosSet = root.appendingPathComponent("ScreenBrushRemote/Assets.xcassets/AppIcon.appiconset")
try fm.createDirectory(at: iosSet, withIntermediateDirectories: true)
png(size: 1024, macStyle: false, remote: true, to: iosSet.appendingPathComponent("icon_1024.png"))
let iosJSON = try JSONSerialization.data(withJSONObject: [
    "images": [["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "icon_1024.png"]],
    "info": ["version": 1, "author": "xcode"],
], options: [.prettyPrinted, .sortedKeys])
try iosJSON.write(to: iosSet.appendingPathComponent("Contents.json"))

for dir in ["ScreenBrush/Assets.xcassets", "ScreenBrushRemote/Assets.xcassets"] {
    try #"{"info":{"version":1,"author":"xcode"}}"#.write(to: root.appendingPathComponent("\(dir)/Contents.json"), atomically: true, encoding: .utf8)
}
print("Icons written.")
