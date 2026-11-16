// Draws the app icon: a white printer on a blue rounded square.
// usage: swift Scripts/make-icon.swift <output.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r / 255, g / 255, b / 255, a])!
}
func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: radius, cornerHeight: radius, transform: nil)
}
func fill(_ path: CGPath, _ c: CGColor) {
    ctx.addPath(path); ctx.setFillColor(c); ctx.fillPath()
}

let blueTop = color(74, 158, 255), blueBottom = color(20, 92, 214), blueMid = color(40, 118, 232)
let white = color(255, 255, 255)

// Background tile (macOS icon grid: 824 pt square, centred, soft shadow).
let tile = rounded(100, 100, 824, 824, 186)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0, 0, 0, 0.3))
fill(tile, blueBottom)
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tile); ctx.clip()
ctx.drawLinearGradient(CGGradient(colorsSpace: space, colors: [blueTop, blueBottom] as CFArray, locations: [0, 1])!,
                       start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
ctx.restoreGState()

// Sheet feeding in at the top.
fill(rounded(362, 590, 300, 190, 18), color(255, 255, 255, 0.72))

// Printer body with a status light.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0, 30, 90, 0.28))
fill(rounded(242, 390, 540, 250, 48), white)
ctx.restoreGState()
fill(CGPath(ellipseIn: CGRect(x: 690, y: 558, width: 34, height: 34), transform: nil), blueMid)

// Output slot and the printed page coming out of it.
fill(rounded(322, 236, 380, 264, 22), blueMid)
fill(rounded(338, 252, 348, 232, 12), white)
for (y, w) in [(410, 252), (358, 252), (306, 160)] as [(CGFloat, CGFloat)] {
    fill(rounded(386, y, w, 20, 10), color(40, 118, 232, 0.55))
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(out.path)") }
