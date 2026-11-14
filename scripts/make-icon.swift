// Draws the app icon: "vae." in white rounded strokes on a black rounded square, with a red dot.
// Usage: swift scripts/make-icon.swift OUT.png [size]
import AppKit

let out = CommandLine.arguments[1]
let size = CommandLine.arguments.count > 2 ? CGFloat(Double(CommandLine.arguments[2])!) : 1024
let k = size / 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: k, y: k)   // draw on a 1024 grid, y up

// macOS icon grid: an 824 pt rounded square centred on the canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil))
ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
ctx.fillPath()

let s: CGFloat = 42                 // stroke width
let h: CGFloat = 200                // x-height, outside of the strokes
let r = (h - s) / 2                 // bowl radius (centre line), vertical
let rx = 0.86 * r                   // bowls are a little narrower than tall
let gap: CGFloat = 0.6 * s
let vWidth: CGFloat = 140           // centre line
let dot: CGFloat = 1.18 * s
let total = (vWidth + s) + gap + (2 * rx + s) + gap + (2 * rx + s) + 0.35 * s + dot
var x = 512 - total / 2 - 8
let base: CGFloat = 512 - h / 2 - 10, top = base + h
let yT = top - s / 2, yB = base + s / 2, yM = (yT + yB) / 2

ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
ctx.setLineWidth(s)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

// v
x += s / 2
ctx.move(to: CGPoint(x: x, y: yT))
ctx.addLine(to: CGPoint(x: x + vWidth / 2, y: yB))
ctx.addLine(to: CGPoint(x: x + vWidth, y: yT))
ctx.strokePath()
x += vWidth + s / 2 + gap

// a: bowl and a stem on its right
let aC = CGPoint(x: x + s / 2 + rx, y: yM)
ctx.addEllipse(in: CGRect(x: aC.x - rx, y: aC.y - r, width: 2 * rx, height: 2 * r))
ctx.move(to: CGPoint(x: aC.x + rx, y: yT))
ctx.addLine(to: CGPoint(x: aC.x + rx, y: yB))
ctx.strokePath()
x += 2 * rx + s + gap

// e: bar across the middle, bowl open at the lower right
let eC = CGPoint(x: x + s / 2 + rx, y: yM)
let e = CGMutablePath()
let squeeze = CGAffineTransform(translationX: eC.x, y: eC.y).scaledBy(x: rx / r, y: 1)
e.move(to: CGPoint(x: -r, y: 0), transform: squeeze)
e.addLine(to: CGPoint(x: r, y: 0), transform: squeeze)
e.addArc(center: .zero, radius: r, startAngle: 0, endAngle: -.pi / 4, clockwise: false, transform: squeeze)
ctx.addPath(e)
ctx.strokePath()
x += 2 * rx + s + 0.35 * s

// red dot on the baseline
ctx.setFillColor(CGColor(srgbRed: 0.91, green: 0.28, blue: 0.24, alpha: 1))
ctx.fillEllipse(in: CGRect(x: x, y: base, width: dot, height: dot))

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
