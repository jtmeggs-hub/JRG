// Renders the JRG app icon: the classic XRG globe-with-graph, redrawn in the
// "Midnight neon" Liquid Glass style. Usage:
//   swiftc -O make_icon.swift -o make_icon && ./make_icon <output.png> [size]
import AppKit
import CoreGraphics

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func gradient(_ colors: [CGColor], _ locs: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locs)!
}

let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "icon_1024.png"
let px = args.count > 2 ? Int(args[2])! : 1024
let S = CGFloat(px) / 1024.0   // draw in a 1024 design space, scaled

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: S, y: S)
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high

// --- Tile: macOS rounded-square body on the 1024 grid (824pt body, 100pt margin) ---
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

// soft drop shadow under the tile
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.45))
ctx.addPath(tilePath); ctx.setFillColor(rgb(0x0B1026)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
// midnight background
ctx.drawLinearGradient(gradient([rgb(0x1C1650), rgb(0x0B1026), rgb(0x060A1C)], [0, 0.55, 1]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// faint neon glows in the corners
ctx.drawRadialGradient(gradient([rgb(0x6C4BFF, 0.35), rgb(0x6C4BFF, 0)], [0, 1]),
                       startCenter: CGPoint(x: 230, y: 820), startRadius: 0,
                       endCenter: CGPoint(x: 230, y: 820), endRadius: 420, options: [])
ctx.drawRadialGradient(gradient([rgb(0x00E0FF, 0.22), rgb(0x00E0FF, 0)], [0, 1]),
                       startCenter: CGPoint(x: 820, y: 200), startRadius: 0,
                       endCenter: CGPoint(x: 820, y: 200), endRadius: 400, options: [])
// glass rim on the tile
ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 2, dy: 2), cornerWidth: 184, cornerHeight: 184, transform: nil))
ctx.setStrokeColor(rgb(0xFFFFFF, 0.14)); ctx.setLineWidth(3); ctx.strokePath()
ctx.restoreGState()

// --- Globe ---
let C = CGPoint(x: 512, y: 500)
let R: CGFloat = 300
let globe = CGPath(ellipseIn: CGRect(x: C.x - R, y: C.y - R, width: 2 * R, height: 2 * R), transform: nil)

// glow behind the globe
ctx.drawRadialGradient(gradient([rgb(0x2F7BFF, 0.35), rgb(0x2F7BFF, 0)], [0, 1]),
                       startCenter: C, startRadius: R * 0.8, endCenter: C, endRadius: R * 1.35, options: [])

ctx.saveGState()
ctx.addPath(globe); ctx.clip()

// deep night sky inside the globe
ctx.drawRadialGradient(gradient([rgb(0x24307A), rgb(0x111842), rgb(0x080C24)], [0, 0.6, 1]),
                       startCenter: CGPoint(x: C.x - 90, y: C.y + 110), startRadius: 0,
                       endCenter: C, endRadius: R, options: [])

// area graph: rises on the left, plateau with a dip, falls away to the right
let graph = CGMutablePath()
let pts: [CGPoint] = [
    CGPoint(x: 200, y: 360), CGPoint(x: 250, y: 470), CGPoint(x: 300, y: 590),
    CGPoint(x: 345, y: 650), CGPoint(x: 395, y: 615), CGPoint(x: 440, y: 640),
    CGPoint(x: 480, y: 600), CGPoint(x: 525, y: 520), CGPoint(x: 575, y: 430),
    CGPoint(x: 630, y: 360), CGPoint(x: 700, y: 300), CGPoint(x: 780, y: 250), CGPoint(x: 840, y: 230),
]
graph.move(to: CGPoint(x: 200, y: 150))
for p in pts { graph.addLine(to: p) }
graph.addLine(to: CGPoint(x: 840, y: 150))
graph.closeSubpath()
ctx.saveGState()
ctx.addPath(graph); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0x00E0FF, 0.95), rgb(0x2F7BFF, 0.85), rgb(0x6C4BFF, 0.75)], [0, 0.5, 1]),
                       start: CGPoint(x: 230, y: 620), end: CGPoint(x: 800, y: 220), options: [])
ctx.restoreGState()
// crisp edge along the top of the graph
let edge = CGMutablePath(); edge.addLines(between: pts)
ctx.addPath(edge); ctx.setStrokeColor(rgb(0x7FE9FF, 0.9)); ctx.setLineWidth(5)
ctx.setLineJoin(.round); ctx.setLineCap(.round); ctx.strokePath()

// globe grid: latitudes and longitudes
ctx.setStrokeColor(rgb(0xFFFFFF, 0.20)); ctx.setLineWidth(4)
for lat in [-0.5, 0.0, 0.5] as [CGFloat] {
    let y = C.y + lat * R
    let half = sqrt(max(0, R * R - (lat * R) * (lat * R)))
    ctx.addEllipse(in: CGRect(x: C.x - half, y: y - half * 0.16, width: 2 * half, height: half * 0.32))
}
ctx.strokePath()
for lon in [0.35, 0.72] as [CGFloat] {
    ctx.addEllipse(in: CGRect(x: C.x - R * lon, y: C.y - R, width: 2 * R * lon, height: 2 * R))
}
ctx.move(to: CGPoint(x: C.x, y: C.y - R)); ctx.addLine(to: CGPoint(x: C.x, y: C.y + R))
ctx.strokePath()

// neon wave sweeping across the globe
let wave = CGMutablePath()
for i in 0...120 {
    let t = CGFloat(i) / 120
    let x = C.x - R * 1.05 + t * 2.1 * R
    let y = C.y - 210 + t * 400 + sin(t * .pi * 2.0) * 70
    if i == 0 { wave.move(to: CGPoint(x: x, y: y)) } else { wave.addLine(to: CGPoint(x: x, y: y)) }
}
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 26, color: rgb(0x00F0C8, 0.9))
ctx.addPath(wave); ctx.setStrokeColor(rgb(0x00F0C8)); ctx.setLineWidth(16); ctx.setLineCap(.round); ctx.strokePath()
ctx.restoreGState()
ctx.addPath(wave); ctx.setStrokeColor(rgb(0xE8FFFB, 0.95)); ctx.setLineWidth(6); ctx.setLineCap(.round); ctx.strokePath()

// glass: darken the lower edge a touch for depth
ctx.drawRadialGradient(gradient([rgb(0x000000, 0), rgb(0x000000, 0.45)], [0.62, 1]),
                       startCenter: CGPoint(x: C.x - 40, y: C.y + 60), startRadius: 0,
                       endCenter: C, endRadius: R, options: [])
ctx.restoreGState()

// glass highlight across the top of the globe
ctx.saveGState()
let hl = CGPath(ellipseIn: CGRect(x: C.x - R * 0.78, y: C.y + R * 0.18, width: R * 1.56, height: R * 0.78), transform: nil)
ctx.addPath(globe); ctx.clip()
ctx.addPath(hl); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.55), rgb(0xFFFFFF, 0.03)], [0, 1]),
                       start: CGPoint(x: C.x, y: C.y + R), end: CGPoint(x: C.x, y: C.y + R * 0.2), options: [])
ctx.restoreGState()

// glass rim on the globe
ctx.addPath(globe); ctx.setStrokeColor(rgb(0xFFFFFF, 0.30)); ctx.setLineWidth(4); ctx.strokePath()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (\(px)px)")
