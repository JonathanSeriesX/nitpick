import CoreGraphics
// Generates app icons for the macOS and tvOS targets. Run: swift tools/make-icons.swift <repo-root>
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let fm = FileManager.default

func context(_ w: Int, _ h: Int) -> CGContext {
    CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func save(_ ctx: CGContext, _ url: URL) {
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let img = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

/// The mark: a greyscale step wheel (six wedges from near-black to white) with an amber centre dot.
func drawMark(_ ctx: CGContext, in rect: CGRect, background: Bool) {
    let cx = rect.midX
    let cy = rect.midY
    let radius = min(rect.width, rect.height) * 0.36
    if background {
        let colors = [rgb(0.10, 0.11, 0.14), rgb(0.05, 0.055, 0.07)] as CFArray
        let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.drawLinearGradient(grad, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
        ctx.restoreGState()
    }
    let steps = 8
    for i in 0..<steps {
        let v = 0.08 + 0.92 * Double(i) / Double(steps - 1)
        let a0 = CGFloat(Double(i) / Double(steps) * 2 * .pi + .pi / 2)
        let a1 = CGFloat(Double(i + 1) / Double(steps) * 2 * .pi + .pi / 2)
        ctx.setFillColor(rgb(v, v, v))
        ctx.move(to: CGPoint(x: cx, y: cy))
        ctx.addArc(center: CGPoint(x: cx, y: cy), radius: radius, startAngle: a0, endAngle: a1, clockwise: false)
        ctx.closePath()
        ctx.fillPath()
    }
    // gaps between wedges
    ctx.setStrokeColor(rgb(0.05, 0.055, 0.07))
    ctx.setLineWidth(radius * 0.035)
    for i in 0..<steps {
        let a = CGFloat(Double(i) / Double(steps) * 2 * .pi + .pi / 2)
        ctx.move(to: CGPoint(x: cx, y: cy))
        ctx.addLine(to: CGPoint(x: cx + cos(a) * radius, y: cy + sin(a) * radius))
    }
    ctx.strokePath()
    // inner dark ring + amber dot
    ctx.setFillColor(rgb(0.05, 0.055, 0.07))
    ctx.fillEllipse(in: CGRect(x: cx - radius * 0.34, y: cy - radius * 0.34, width: radius * 0.68, height: radius * 0.68))
    ctx.setFillColor(rgb(1.0, 0.62, 0.15))
    ctx.fillEllipse(in: CGRect(x: cx - radius * 0.2, y: cy - radius * 0.2, width: radius * 0.4, height: radius * 0.4))
}

func roundedRectPath(_ r: CGRect, _ cr: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: cr, cornerHeight: cr, transform: nil) }

// ---- macOS AppIcon (all classic sizes, squircle with 10% margin) ----
let macSet = root.appendingPathComponent("Apps/NitpickMac/Assets.xcassets/AppIcon.appiconset")
var macImages: [[String: String]] = []
for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let px = pt * scale
    let ctx = context(px, px)
    let margin = CGFloat(px) * 0.1
    let r = CGRect(x: margin, y: margin, width: CGFloat(px) - 2 * margin, height: CGFloat(px) - 2 * margin)
    ctx.saveGState()
    ctx.addPath(roundedRectPath(r, r.width * 0.225))
    ctx.clip()
    drawMark(ctx, in: r, background: true)
    ctx.restoreGState()
    let name = "icon_\(pt)x\(pt)@\(scale)x.png"
    save(ctx, macSet.appendingPathComponent(name))
    macImages.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(pt)x\(pt)"])
}
let macJSON: [String: Any] = ["images": macImages, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: macJSON, options: [.prettyPrinted, .sortedKeys]).write(
    to: macSet.appendingPathComponent("Contents.json"))
try! JSONSerialization.data(withJSONObject: ["info": ["author": "xcode", "version": 1]], options: [.prettyPrinted]).write(
    to: root.appendingPathComponent("Apps/NitpickMac/Assets.xcassets/Contents.json"))

// ---- tvOS brand assets ----
let tvAssets = root.appendingPathComponent("Apps/NitpickTV/Assets.xcassets")
let brand = tvAssets.appendingPathComponent("App Icon & Top Shelf Image.brandassets")
try? fm.createDirectory(at: brand, withIntermediateDirectories: true)
try! JSONSerialization.data(withJSONObject: ["info": ["author": "xcode", "version": 1]], options: [.prettyPrinted]).write(
    to: tvAssets.appendingPathComponent("Contents.json"))

func writeJSON(_ obj: Any, _ url: URL) {
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]).write(to: url)
}

/// Layered icon: back layer = background, middle = wheel, front = dot.
func writeImageStack(name: String, w: Int, h: Int, scales: [Int]) {
    let stack = brand.appendingPathComponent("\(name).imagestack")
    let layers = ["Front", "Middle", "Back"]
    writeJSON(
        ["info": ["author": "xcode", "version": 1], "layers": layers.map { ["filename": "\($0).imagestacklayer"] }],
        stack.appendingPathComponent("Contents.json"))
    for (li, layer) in layers.enumerated() {
        let layerDir = stack.appendingPathComponent("\(layer).imagestacklayer")
        writeJSON(["info": ["author": "xcode", "version": 1]], layerDir.appendingPathComponent("Contents.json"))
        let set = layerDir.appendingPathComponent("Content.imageset")
        var images: [[String: String]] = []
        for s in scales {
            let ctx = context(w * s, h * s)
            let rect = CGRect(x: 0, y: 0, width: w * s, height: h * s)
            let markRect = rect.insetBy(dx: rect.width * 0.2, dy: 0)
            switch layer {
            case "Back":
                let colors = [rgb(0.10, 0.11, 0.14), rgb(0.05, 0.055, 0.07)] as CFArray
                let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
                ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: rect.maxX, y: 0), options: [])
            case "Middle":
                drawMark(ctx, in: markRect, background: false)
                // knock out the centre so the dot layer sits alone in front
                ctx.setBlendMode(.clear)
                let r = min(markRect.width, markRect.height) * 0.36
                ctx.fillEllipse(in: CGRect(x: markRect.midX - r * 0.34, y: markRect.midY - r * 0.34, width: r * 0.68, height: r * 0.68))
                ctx.setBlendMode(.normal)
            default:
                let r = min(markRect.width, markRect.height) * 0.36
                ctx.setFillColor(rgb(1.0, 0.62, 0.15))
                ctx.fillEllipse(in: CGRect(x: markRect.midX - r * 0.2, y: markRect.midY - r * 0.2, width: r * 0.4, height: r * 0.4))
            }
            let fname = "\(layer)@\(s)x.png"
            save(ctx, set.appendingPathComponent(fname))
            images.append(["filename": fname, "idiom": "tv", "scale": "\(s)x"])
        }
        writeJSON(["images": images, "info": ["author": "xcode", "version": 1]], set.appendingPathComponent("Contents.json"))
    }
}

func writeTopShelf(name: String, w: Int, h: Int) {
    let set = brand.appendingPathComponent("\(name).imageset")
    var images: [[String: String]] = []
    for s in [1, 2] {
        let ctx = context(w * s, h * s)
        let rect = CGRect(x: 0, y: 0, width: w * s, height: h * s)
        drawMark(ctx, in: rect, background: true)
        let fname = "\(name.replacingOccurrences(of: " ", with: ""))@\(s)x.png"
        save(ctx, set.appendingPathComponent(fname))
        images.append(["filename": fname, "idiom": "tv", "scale": "\(s)x"])
    }
    writeJSON(["images": images, "info": ["author": "xcode", "version": 1]], set.appendingPathComponent("Contents.json"))
}

writeImageStack(name: "App Icon", w: 400, h: 240, scales: [1, 2])
writeImageStack(name: "App Icon - App Store", w: 1280, h: 768, scales: [1])
writeTopShelf(name: "Top Shelf Image", w: 1920, h: 720)
writeTopShelf(name: "Top Shelf Image Wide", w: 2320, h: 720)
writeJSON(
    [
        "assets": [
            ["filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"],
            ["filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"],
            ["filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"],
            ["filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"],
        ], "info": ["author": "xcode", "version": 1],
    ], brand.appendingPathComponent("Contents.json"))

print("icons written")
