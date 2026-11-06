import AppKit
import CoreGraphics

let side = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                        bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ rgb: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
            green: CGFloat((rgb >> 8) & 255) / 255,
            blue: CGFloat(rgb & 255) / 255, alpha: alpha)
}
func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
func fill(_ path: CGPath, _ rgb: UInt32, alpha: CGFloat = 1) {
    context.addPath(path)
    context.setFillColor(color(rgb, alpha: alpha))
    context.fillPath()
}
func gradient(_ path: CGPath, from: UInt32, to: UInt32, start: CGPoint, end: CGPoint) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    let blend = CGGradient(colorsSpace: space, colors: [color(from), color(to)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(blend, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}
func stripe(_ points: [CGPoint]) -> CGPath {
    let result = CGMutablePath()
    result.addLines(between: points)
    result.closeSubpath()
    return result
}

let bounds = CGRect(x: 72, y: 77, width: 880, height: 880)
let mask = CGPath(roundedRect: bounds, cornerWidth: 198, cornerHeight: 198, transform: nil)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -16), blur: 28, color: color(0x000000, alpha: 0.44))
fill(mask, 0x1c1c21)
context.restoreGState()
gradient(mask, from: 0x35353d, to: 0x0d0d13, start: point(179, 930), end: point(857, 158))
context.saveGState()
context.addPath(mask)
context.clip()

// The dark road shoulder follows the mark and gives the warm edge its contrast.
let road = CGMutablePath()
road.move(to: point(-26, 223))
road.addCurve(to: point(448, 368), control1: point(166, 144), control2: point(349, 216))
road.addCurve(to: point(798, 641), control1: point(552, 519), control2: point(608, 635))
road.addCurve(to: point(1120, 684), control1: point(919, 644), control2: point(1023, 644))
context.addPath(road)
context.setLineWidth(276)
context.setStrokeColor(color(0x07080c, alpha: 0.74))
context.strokePath()
context.addPath(road)
context.setLineWidth(4)
context.setLineDash(phase: 0, lengths: [24, 19])
context.setStrokeColor(color(0xa5a1a0, alpha: 0.16))
context.strokePath()
context.setLineDash(phase: 0, lengths: [])

// Two long, tapering strokes form a racing line across the curve.
let ribbon = CGMutablePath()
ribbon.move(to: point(61, 256))
ribbon.addCurve(to: point(397, 420), control1: point(212, 226), control2: point(318, 270))
ribbon.addCurve(to: point(625, 623), control1: point(457, 536), control2: point(515, 609))
ribbon.addLine(to: point(591, 536))
ribbon.addCurve(to: point(467, 364), control1: point(533, 499), control2: point(505, 437))
ribbon.addCurve(to: point(61, 256), control1: point(391, 220), control2: point(249, 172))
ribbon.closeSubpath()
gradient(ribbon, from: 0xffbd72, to: 0xe52f2d, start: point(579, 648), end: point(163, 244))

let tail = CGMutablePath()
tail.move(to: point(67, 214))
tail.addCurve(to: point(441, 288), control1: point(248, 144), control2: point(362, 161))
tail.addCurve(to: point(538, 421), control1: point(475, 345), control2: point(504, 389))
tail.addCurve(to: point(469, 250), control1: point(518, 353), control2: point(496, 294))
tail.addCurve(to: point(67, 214), control1: point(392, 119), control2: point(230, 144))
tail.closeSubpath()
fill(tail, 0xa91f2a, alpha: 0.85)

// Checkered corner. Each cell shares the same slanted perspective grid.
let top = [point(652, 718), point(722, 737), point(792, 748), point(860, 750)]
let bottom = [point(575, 528), point(651, 542), point(723, 551), point(793, 551)]
func grid(_ column: Int, _ row: Int) -> CGPoint {
    let t = CGFloat(row) / 3
    return point(top[column].x * (1 - t) + bottom[column].x * t,
                 top[column].y * (1 - t) + bottom[column].y * t)
}
for row in 0..<3 {
    for column in 0..<3 where (row + column).isMultiple(of: 2) {
        let cell = stripe([grid(column, row), grid(column + 1, row),
                           grid(column + 1, row + 1), grid(column, row + 1)])
        gradient(cell, from: 0xfff7e9, to: 0xe0c6ad, start: point(679, 780), end: point(679, 514))
    }
}

context.restoreGState()
context.addPath(mask)
context.setLineWidth(3)
context.setStrokeColor(color(0xaca4a9, alpha: 0.44))
context.strokePath()
let image = NSBitmapImageRep(cgImage: context.makeImage()!)
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try image.representation(using: .png, properties: [:])!.write(to: output)
