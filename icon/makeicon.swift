import AppKit

// Mekong app icon: same construction as the Crocus icon (rounded dark tile,
// soft radial glow, layered gradient forms) in river blues, with three
// meandering bands of light for the river.

let S: CGFloat = 1024

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

/// A horizontal ribbon that meanders: centre line y(x) = base + amp·sin(…),
/// thickness tapering towards both ends.
func ribbon(baseY: CGFloat, amp: CGFloat, phase: CGFloat, thickness: CGFloat,
            from x0: CGFloat, to x1: CGFloat) -> NSBezierPath {
    let steps = 120
    var top: [NSPoint] = [], bottom: [NSPoint] = []
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let x = x0 + (x1 - x0) * t
        let y = baseY + amp * sin(t * .pi * 2.2 + phase)
        let taper = sin(t * .pi)
        let h = thickness * (0.03 + 0.97 * taper) / 2
        top.append(NSPoint(x: x, y: y + h))
        bottom.append(NSPoint(x: x, y: y - h))
    }
    let p = NSBezierPath()
    p.move(to: top[0])
    top.dropFirst().forEach { p.line(to: $0) }
    bottom.reversed().forEach { p.line(to: $0) }
    p.close()
    return p
}

func fillGradient(_ path: NSBezierPath, _ c1: NSColor, _ c2: NSColor, angle: CGFloat = 0) {
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(starting: c1, ending: c2)!.draw(in: path.bounds, angle: angle)
    NSGraphicsContext.restoreGraphicsState()
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let inset: CGFloat = 70
let tileRect = NSRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
let tile = NSBezierPath(roundedRect: tileRect, xRadius: 200, yRadius: 200)
fillGradient(tile, color(0.09, 0.13, 0.20), color(0.03, 0.05, 0.08), angle: 90)

NSGraphicsContext.saveGraphicsState()
tile.addClip()
NSGradient(colors: [color(0.30, 0.62, 0.85, 0.30), color(0.30, 0.62, 0.85, 0.0)])!
    .draw(in: tileRect, relativeCenterPosition: NSPoint(x: 0, y: 0.0))

// Back to front: darker, wider bands behind; the brightest current in front.
let bands: [(y: CGFloat, amp: CGFloat, phase: CGFloat, th: CGFloat, c1: NSColor, c2: NSColor)] = [
    (612, 46, 0.6, 70, color(0.16, 0.36, 0.56), color(0.22, 0.48, 0.70)),
    (512, 58, 2.2, 96, color(0.26, 0.56, 0.78), color(0.42, 0.74, 0.90)),
    (408, 46, 3.9, 70, color(0.55, 0.86, 0.96), color(0.80, 0.95, 1.00)),
]
for b in bands {
    fillGradient(ribbon(baseY: b.y, amp: b.amp, phase: b.phase, thickness: b.th, from: 190, to: 834),
                 b.c1, b.c2)
}
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.restoreGraphicsState()

let outURL = URL(fileURLWithPath: CommandLine.arguments[1])
try! rep.representation(using: .png, properties: [:])!.write(to: outURL)
print("wrote \(outURL.path)")
