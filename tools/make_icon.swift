// Рисует иконку Kadr (видоискатель + стрелка-пометка) и собирает Kadr.icns через iconutil.
// Использование: swift make_icon.swift <выходной.icns>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Kadr.icns"
let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Kadr-\(getpid()).iconset")
try? FileManager.default.removeItem(at: tmp)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s, y: s)

    // Подложка: скруглённый квадрат по сетке macOS (824 из 1024).
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor(srgbRed: 0.13, green: 0.15, blue: 0.19, alpha: 1).setFill()
    tilePath.fill()
    ctx.restoreGState()
    let grad = NSGradient(colors: [NSColor(srgbRed: 0.25, green: 0.29, blue: 0.36, alpha: 1),
                                   NSColor(srgbRed: 0.10, green: 0.11, blue: 0.14, alpha: 1)])!
    grad.draw(in: tilePath, angle: -90)

    // Уголки видоискателя.
    let frame = NSRect(x: 262, y: 262, width: 500, height: 500)
    let arm: CGFloat = 132
    let corners = NSBezierPath()
    corners.lineWidth = 46
    corners.lineCapStyle = .round
    corners.lineJoinStyle = .round
    let (x0, y0, x1, y1) = (frame.minX, frame.minY, frame.maxX, frame.maxY)
    corners.move(to: NSPoint(x: x0, y: y1 - arm)); corners.line(to: NSPoint(x: x0, y: y1)); corners.line(to: NSPoint(x: x0 + arm, y: y1))
    corners.move(to: NSPoint(x: x1 - arm, y: y1)); corners.line(to: NSPoint(x: x1, y: y1)); corners.line(to: NSPoint(x: x1, y: y1 - arm))
    corners.move(to: NSPoint(x: x1, y: y0 + arm)); corners.line(to: NSPoint(x: x1, y: y0)); corners.line(to: NSPoint(x: x1 - arm, y: y0))
    corners.move(to: NSPoint(x: x0 + arm, y: y0)); corners.line(to: NSPoint(x: x0, y: y0)); corners.line(to: NSPoint(x: x0, y: y0 + arm))
    NSColor(white: 0.96, alpha: 1).setStroke()
    corners.stroke()

    // Стрелка-пометка красным.
    let red = NSColor(srgbRed: 1.0, green: 0.27, blue: 0.23, alpha: 1)
    let a = NSPoint(x: 372, y: 372), b = NSPoint(x: 612, y: 612)
    let shaft = NSBezierPath()
    shaft.lineWidth = 44
    shaft.lineCapStyle = .round
    shaft.move(to: a); shaft.line(to: NSPoint(x: 560, y: 560))
    red.setStroke()
    shaft.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: b.x + 14, y: b.y + 14))
    head.line(to: NSPoint(x: b.x - 150, y: b.y - 22))
    head.line(to: NSPoint(x: b.x - 22, y: b.y - 150))
    head.close()
    head.lineJoinStyle = .round
    head.lineWidth = 18
    red.setFill()
    head.fill()
    head.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(String, Int)] = [
    ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
    ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024),
]
for (name, px) in sizes {
    try! render(px).write(to: tmp.appendingPathComponent("icon_\(name).png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", tmp.path, "-o", out]
try! p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: tmp)
if p.terminationStatus != 0 { exit(1) }
print("иконка: \(out)")
