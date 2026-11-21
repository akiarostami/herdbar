// Renders Resources/AppIcon.icns: a dark tile with a waveform of bars in Herdbar's three
// status colours (working blue, needs-you yellow, done green). Run through scripts/make-icon.sh.
import AppKit

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    let side = CGFloat(pixels)
    // The macOS icon shape: a rounded square inset from the canvas.
    let tile = CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: side * 0.1, dy: side * 0.1)
    let shape = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.width * 0.225, transform: nil)
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let background = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.17, green: 0.18, blue: 0.22, alpha: 1), CGColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(background, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    context.restoreGState()

    // Seven bars, tallest in the middle, coloured in three groups.
    let blue = CGColor(red: 0.20, green: 0.56, blue: 1.00, alpha: 1)
    let yellow = CGColor(red: 1.00, green: 0.80, blue: 0.10, alpha: 1)
    let green = CGColor(red: 0.20, green: 0.80, blue: 0.40, alpha: 1)
    let bars: [(CGFloat, CGColor)] = [(0.22, blue), (0.42, blue), (0.62, blue), (0.34, yellow), (0.54, yellow), (0.40, green), (0.24, green)]
    let barWidth = tile.width * 0.064
    let gap = tile.width * 0.046
    let total = CGFloat(bars.count) * barWidth + CGFloat(bars.count - 1) * gap
    var x = tile.midX - total / 2
    for (height, colour) in bars {
        let h = tile.height * height
        let rect = CGRect(x: x, y: tile.midY - h / 2, width: barWidth, height: h)
        context.setFillColor(colour)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
        context.fillPath()
        x += barWidth + gap
    }
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try render(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
