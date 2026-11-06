// Draws the Daylit app icon: a white sun on a warm rounded square.
// Usage: swift draw.swift <out.png> <size> <mac|win> [flat]
// "mac" keeps Apple's icon margin and a soft shadow ("flat" drops it); "win" fills the square.
import AppKit

let args = CommandLine.arguments
let out = args[1], size = CGFloat(Double(args[2])!), mac = args[3] == "mac"
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let s = size / 1024
ctx.scaleBy(x: s, y: s)

// The tile: Apple's grid puts an 824-point shape inside a 1024 canvas.
let inset: CGFloat = mac ? 100 : 24
let tile = CGRect(x: inset, y: inset, width: 1024 - 2 * inset, height: 1024 - 2 * inset)
// A superellipse (|x|^5 + |y|^5 = 1), the smooth "squircle" corner Apple and Windows 11 icons use,
// instead of a plain rounded rectangle whose corners look pinched.
let path = CGMutablePath()
for i in 0...720 {
    let t = Double(i) / 720 * 2 * .pi, n = 5.0
    let x = pow(abs(cos(t)), 2 / n) * (cos(t) < 0 ? -1 : 1), y = pow(abs(sin(t)), 2 / n) * (sin(t) < 0 ? -1 : 1)
    let p = CGPoint(x: tile.midX + x * tile.width / 2, y: tile.midY + y * tile.height / 2)
    if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
}
path.closeSubpath()
let shadow = args.count > 4 ? args[4] != "flat" : true
if mac && shadow {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(path); ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
}
ctx.saveGState()
ctx.addPath(path); ctx.clip()
let colors = [CGColor(srgbRed: 1.00, green: 0.80, blue: 0.30, alpha: 1),   // top: warm yellow
              CGColor(srgbRed: 0.96, green: 0.45, blue: 0.13, alpha: 1)]   // bottom: orange
let grad = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
ctx.restoreGState()

// The sun, the same shape as the tray icon: a disc and eight rounded rays.
let c = CGPoint(x: 512, y: 512), k = tile.width / 824
ctx.setFillColor(CGColor(gray: 1, alpha: 1))
let r = 150 * k
ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
ctx.setLineWidth(62 * k); ctx.setLineCap(.round)
for i in 0..<8 {
    let a = Double(i) * .pi / 4
    ctx.move(to: CGPoint(x: c.x + cos(a) * 225 * k, y: c.y + sin(a) * 225 * k))
    ctx.addLine(to: CGPoint(x: c.x + cos(a) * 300 * k, y: c.y + sin(a) * 300 * k))
}
ctx.strokePath()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
