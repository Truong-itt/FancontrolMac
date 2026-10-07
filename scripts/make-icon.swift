// Draws the app icon (1024x1024 PNG). Run through scripts/make-icon.sh to produce Resources/AppIcon.icns.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size: CGFloat = 1024
let output = CommandLine.arguments[1]

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [r, g, b, a])!
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: nil)!
}

func polar(_ radius: CGFloat, _ degrees: CGFloat) -> CGPoint {
    let radians = degrees * .pi / 180
    return CGPoint(x: radius * cos(radians), y: radius * sin(radians))
}

// Background: rounded square on the macOS icon grid (824pt inside a 1024pt canvas) with a soft drop shadow.
let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
let platePath = CGPath(roundedRect: plate, cornerWidth: 186, cornerHeight: 186, transform: nil)

context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.35))
context.addPath(platePath)
context.setFillColor(color(0.08, 0.2, 0.42))
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(platePath)
context.clip()
context.drawLinearGradient(gradient([color(0.22, 0.62, 0.98), color(0.07, 0.23, 0.6)]),
                           start: CGPoint(x: plate.midX, y: plate.maxY), end: CGPoint(x: plate.midX, y: plate.minY),
                           options: [])
// A faint highlight in the upper half so the background is less flat.
context.drawRadialGradient(gradient([color(1, 1, 1, 0.22), color(1, 1, 1, 0)]),
                           startCenter: CGPoint(x: plate.midX, y: plate.maxY - 80), startRadius: 0,
                           endCenter: CGPoint(x: plate.midX, y: plate.maxY - 80), endRadius: 560, options: [])
context.restoreGState()

// Fan: outer ring, 7 curved blades, centre hub.
let bladeCount = 7
let hubRadius: CGFloat = 92
let bladeRadius: CGFloat = 282
let ringRadius: CGFloat = 322

context.saveGState()
context.translateBy(x: size / 2, y: size / 2)

context.setStrokeColor(color(1, 1, 1, 0.3))
context.setLineWidth(26)
context.strokeEllipse(in: CGRect(x: -ringRadius, y: -ringRadius, width: ringRadius * 2, height: ringRadius * 2))

context.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: color(0, 0.1, 0.3, 0.35))
for index in 0..<bladeCount {
    context.saveGState()
    context.rotate(by: CGFloat(index) * 2 * .pi / CGFloat(bladeCount))
    let blade = CGMutablePath()
    // Convex leading edge from hub to tip, the tip arc, then a concave trailing edge back to the hub.
    blade.move(to: polar(hubRadius * 0.7, -18))
    blade.addQuadCurve(to: polar(bladeRadius, 22), control: polar(bladeRadius * 0.72, -22))
    blade.addArc(center: .zero, radius: bladeRadius, startAngle: 22 * .pi / 180, endAngle: 58 * .pi / 180,
                 clockwise: false)
    blade.addQuadCurve(to: polar(hubRadius * 0.7, 34), control: polar(bladeRadius * 0.6, 42))
    blade.closeSubpath()
    context.addPath(blade)
    context.setFillColor(color(1, 1, 1, 0.94))
    context.fillPath()
    context.restoreGState()
}

context.setFillColor(color(1, 1, 1))
context.fillEllipse(in: CGRect(x: -hubRadius, y: -hubRadius, width: hubRadius * 2, height: hubRadius * 2))
context.setShadow(offset: .zero, blur: 0, color: nil)
context.setFillColor(color(0.12, 0.38, 0.8))
context.fillEllipse(in: CGRect(x: -34, y: -34, width: 68, height: 68))
context.restoreGState()

let image = context.makeImage()!
let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL,
                                                  UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    fputs("Could not write \(output)\n", stderr)
    exit(1)
}
