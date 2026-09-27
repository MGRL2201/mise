// Generates every app icon asset. Run from repo root: swift scripts/make-icons.swift
// Add a colour = add one line to `palettes`, rerun, list AppIcon-<Name> in
// ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES. First entry is the primary AppIcon.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// name: background, back card, middle card, front card, m stroke
let palettes: [(String, [String])] = [
    ("Latte", ["F3E9DC", "E3CDB4", "C9A27E", "7A4E2D", "FFFFFF"]),
    ("Espresso", ["2B1D14", "4A3326", "7A5640", "E8D5BF", "2B1D14"]),
    ("Mocha", ["EADBC8", "C8A58A", "9C6B4E", "4B2E20", "F3E9DC"]),
    ("Caramel", ["FFF4E6", "F5D3A8", "E0A96D", "A8652A", "FFFFFF"]),
    ("Cappuccino", ["D9BFA0", "EBD9C3", "F5EBDD", "FFFFFF", "6F4A2F"]),
    ("ColdBrew", ["1A1210", "3B2A22", "8B5E3C", "D9A066", "1A1210"]),
    ("Sky", ["E6F4FB", "B8E0F5", "7CC4EA", "2A8FCB", "FFFFFF"]),
    ("Aqua", ["E3F8F6", "AEEBE4", "5FD3C6", "13978A", "FFFFFF"]),
    ("Lagoon", ["14A3B8", "6FD0DD", "B5E9EF", "FFFFFF", "14A3B8"]),
    ("DeepSea", ["0B2540", "164A6E", "2E7FA8", "7FE0E8", "0B2540"]),
    ("Seafoam", ["F0FAF5", "CDEFE0", "8FD9BD", "2E8F74", "FFFFFF"]),
    ("Dusk", ["1C3F66", "3F6FA0", "86B7E0", "FFFFFF", "1C3F66"]),
]
// Glass: background gradient top/bottom, m stroke. Cards are translucent white.
let glass = ["FBF7F2", "E3CDB4", "7A4E2D"]
let cardAlpha = [0.4, 0.6, 0.8] // back → front, shared by .icon SVGs and preview

let assets = URL(fileURLWithPath: "mise/Assets.xcassets")
let cards: [CGPoint] = [CGPoint(x: 30, y: 22), CGPoint(x: 22, y: 30), CGPoint(x: 14, y: 38)] // back → front
let mPath = "M34 83 V65 Q34 57 43 57 Q52 57 52 65 V83 M52 65 Q52 57 61 57 Q70 57 70 65 V83"
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: String, _ alpha: CGFloat = 1) -> CGColor {
    let v = Int(hex, radix: 16)!
    return CGColor(colorSpace: srgb, components: [CGFloat(v >> 16 & 255) / 255, CGFloat(v >> 8 & 255) / 255, CGFloat(v & 255) / 255, alpha])!
}

func card(_ o: CGPoint) -> CGPath {
    CGPath(roundedRect: CGRect(x: o.x, y: o.y, width: 76, height: 64), cornerWidth: 10, cornerHeight: 10, transform: nil)
}

func m() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 34, y: 83)); p.addLine(to: CGPoint(x: 34, y: 65))
    p.addQuadCurve(to: CGPoint(x: 43, y: 57), control: CGPoint(x: 34, y: 57))
    p.addQuadCurve(to: CGPoint(x: 52, y: 65), control: CGPoint(x: 52, y: 57))
    p.addLine(to: CGPoint(x: 52, y: 83))
    p.move(to: CGPoint(x: 52, y: 65))
    p.addQuadCurve(to: CGPoint(x: 61, y: 57), control: CGPoint(x: 52, y: 57))
    p.addQuadCurve(to: CGPoint(x: 70, y: 65), control: CGPoint(x: 70, y: 57))
    p.addLine(to: CGPoint(x: 70, y: 83))
    return p
}

// Draws on the 120-unit design box, y down; `glassy` uses the Glass look.
func render(_ px: Int, _ c: [String], glassy: Bool = false) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: CGFloat(px) / 120, y: -CGFloat(px) / 120)
    if glassy {
        let g = CGGradient(colorsSpace: srgb, colors: [color(c[0]), color(c[1])] as CFArray, locations: nil)!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: 120), options: [])
        for (i, o) in cards.enumerated() {
            ctx.addPath(card(o)); ctx.setFillColor(color("FFFFFF", cardAlpha[i])); ctx.fillPath()
            ctx.addPath(card(o)); ctx.setStrokeColor(color("FFFFFF", 0.9)); ctx.setLineWidth(1.2); ctx.strokePath()
        }
    } else {
        ctx.setFillColor(color(c[0])); ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
        for (i, o) in cards.enumerated() { ctx.addPath(card(o)); ctx.setFillColor(color(c[i + 1])); ctx.fillPath() }
    }
    ctx.addPath(m()); ctx.setStrokeColor(color(glassy ? c[2] : c[4]))
    ctx.setLineWidth(7); ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.strokePath()
    return ctx.makeImage()!
}

func write(_ data: Data, _ url: URL) {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! data.write(to: url)
}

func png(_ img: CGImage, _ url: URL) {
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    precondition(CGImageDestinationFinalize(dest))
    write(data as Data, url)
}

func json(_ obj: Any, _ url: URL) {
    write(try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]), url)
}

let info = ["author": "xcode", "version": 1] as [String: Any]

func appIcon(_ name: String, _ img: CGImage, mac: Bool = false) {
    let dir = assets.appendingPathComponent("\(name).appiconset")
    png(img, dir.appendingPathComponent("\(name).png"))
    var images: [[String: String]] = [["filename": "\(name).png", "idiom": "universal", "platform": "ios", "size": "1024x1024"]]
    // actool derives every mac size from one 512@2x entry.
    if mac { images.append(["filename": "\(name).png", "idiom": "mac", "scale": "2x", "size": "512x512"]) }
    json(["images": images, "info": info], dir.appendingPathComponent("Contents.json"))
}

func preview(_ name: String, _ img: CGImage) {
    let dir = assets.appendingPathComponent("IconPreview-\(name).imageset")
    png(img, dir.appendingPathComponent("IconPreview-\(name).png"))
    json(["images": [["filename": "IconPreview-\(name).png", "idiom": "universal"]], "info": info],
         dir.appendingPathComponent("Contents.json"))
}

for (i, (name, c)) in palettes.enumerated() {
    appIcon(i == 0 ? "AppIcon" : "AppIcon-\(name)", render(1024, c), mac: i == 0)
    preview(name, render(180, c))
}

// Glass: Icon Composer bundle, one SVG layer per card + the m, Liquid Glass applied by the system.
let icon = URL(fileURLWithPath: "mise/AppIcon-Glass.icon")
func svg(_ body: String) -> Data {
    Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1024\" height=\"1024\" viewBox=\"0 0 120 120\">\(body)</svg>\n".utf8)
}
for (i, o) in cards.enumerated() {
    write(svg("<rect x=\"\(Int(o.x))\" y=\"\(Int(o.y))\" width=\"76\" height=\"64\" rx=\"10\" fill=\"#FFFFFF\" fill-opacity=\"\(cardAlpha[i])\"/>"),
          icon.appendingPathComponent("Assets/card\(i).svg"))
}
write(svg("<path d=\"\(mPath)\" fill=\"none\" stroke=\"#\(glass[2])\" stroke-width=\"7\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"),
      icon.appendingPathComponent("Assets/m.svg"))
func srgbString(_ hex: String) -> String {
    let v = Int(hex, radix: 16)!
    return "srgb:" + [v >> 16 & 255, v >> 8 & 255, v & 255].map { String(format: "%.5f", Double($0) / 255) }.joined(separator: ",") + ",1.00000"
}
json([
    "fill": ["automatic-gradient": srgbString(glass[0])],
    "groups": [
        ["layers": [["image-name": "m.svg", "name": "m", "glass": false]], "shadow": ["kind": "neutral", "opacity": 0.5]],
        ["layers": (0..<3).reversed().map { ["image-name": "card\($0).svg", "name": "card\($0)"] },
         "shadow": ["kind": "neutral", "opacity": 0.5], "translucency": ["enabled": true, "value": 0.5]],
    ],
    "supported-platforms": ["squares": "shared"],
], icon.appendingPathComponent("icon.json"))
preview("Glass", render(180, glass, glassy: true))
