// Draws the app icons and writes the asset catalogs.
// Run from apple/: swift Tools/make-icons.swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024.0

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func linearGradient(_ ctx: CGContext, in path: CGPath, top: UInt32, bottom: UInt32, rect: CGRect) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [color(top), color(bottom)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.minY),
                           end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
    ctx.restoreGState()
}

/// Draws the icon. `mac` uses Apple's macOS grid (824pt rounded square with a shadow);
/// iOS icons are full-bleed squares that the system masks.
func drawIcon(mac: Bool) -> CGImage {
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Top-left origin, like the design coordinates below.
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: 1, y: -1)

    let tile = mac ? CGRect(x: 100, y: 100, width: 824, height: 824) : CGRect(x: 0, y: 0, width: size, height: size)
    let tilePath = mac
        ? CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
        : CGPath(rect: tile, transform: nil)

    if mac {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: color(0x000000, 0.35))
        ctx.addPath(tilePath)
        ctx.setFillColor(color(0x3A66F0))
        ctx.fillPath()
        ctx.restoreGState()
    }
    linearGradient(ctx, in: tilePath, top: 0x5E8DFF, bottom: 0x2A47D1, rect: tile)

    let s = tile.width, x0 = tile.minX, y0 = tile.minY
    func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
        CGRect(x: x0 + x * s, y: y0 + y * s, width: w * s, height: h * s)
    }

    // Monitor
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 0.012 * s), blur: 0.03 * s, color: color(0x0B1A5C, 0.35))
    let body = r(0.17, 0.22, 0.66, 0.44)
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: 0.055 * s, cornerHeight: 0.055 * s, transform: nil))
    ctx.addPath(CGPath(roundedRect: r(0.455, 0.655, 0.09, 0.09), cornerWidth: 0.01 * s, cornerHeight: 0.01 * s, transform: nil))
    ctx.addPath(CGPath(roundedRect: r(0.33, 0.735, 0.34, 0.045), cornerWidth: 0.0225 * s, cornerHeight: 0.0225 * s, transform: nil))
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    // Screen
    let screen = body.insetBy(dx: 0.035 * s, dy: 0.035 * s)
    linearGradient(ctx, in: CGPath(roundedRect: screen, cornerWidth: 0.025 * s, cornerHeight: 0.025 * s, transform: nil),
                   top: 0x1C2F86, bottom: 0x2F57DA, rect: screen)

    // Cursor arrow
    let u = 0.30 * s
    let tip = CGPoint(x: x0 + 0.47 * s, y: y0 + 0.33 * s)
    let points: [(Double, Double)] = [(0, 0), (0, 0.74), (0.18, 0.575), (0.305, 0.84), (0.415, 0.79), (0.29, 0.53), (0.52, 0.53)]
    let arrow = CGMutablePath()
    arrow.addLines(between: points.map { CGPoint(x: tip.x + $0.0 * u, y: tip.y + $0.1 * u) })
    arrow.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 0.01 * s), blur: 0.025 * s, color: color(0x000000, 0.4))
    ctx.addPath(arrow)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(arrow)
    ctx.setStrokeColor(color(0x13246E))
    ctx.setLineWidth(0.022 * s)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    return ctx.makeImage()!
}

func resized(_ image: CGImage, _ px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: px, height: px))
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

func writeCatalog(at dir: String, images: [[String: String]], files: [(String, CGImage)]) throws {
    let set = URL(fileURLWithPath: dir).appendingPathComponent("AppIcon.appiconset")
    try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    for (name, image) in files { writePNG(image, to: set.appendingPathComponent(name)) }
    let info = ["author": "xcode", "version": 1] as [String: Any]
    let contents = try JSONSerialization.data(withJSONObject: ["images": images, "info": info], options: [.prettyPrinted, .sortedKeys])
    try contents.write(to: set.appendingPathComponent("Contents.json"))
    let root = try JSONSerialization.data(withJSONObject: ["info": info], options: [.prettyPrinted, .sortedKeys])
    try root.write(to: URL(fileURLWithPath: dir).appendingPathComponent("Contents.json"))
}

// macOS: every size from 16pt to 512pt @1x/@2x.
let macIcon = drawIcon(mac: true)
var macImages: [[String: String]] = []
var macFiles: [(String, CGImage)] = []
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
        macImages.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
        macFiles.append((name, resized(macIcon, pt * scale)))
    }
}
try writeCatalog(at: "macOS/Assets.xcassets", images: macImages, files: macFiles)

// iOS: a single 1024px universal icon.
try writeCatalog(at: "iOS/Assets.xcassets",
                 images: [["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "icon_1024.png"]],
                 files: [("icon_1024.png", drawIcon(mac: false))])

// Preview for the website.
writePNG(resized(macIcon, 512), to: URL(fileURLWithPath: "../public/icon.png"))
print("Icons written.")
