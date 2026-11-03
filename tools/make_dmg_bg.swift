// Фон окна установочного образа Kadr: спокойный «световой стол» с сеткой точек, как в редакторе,
// название, подзаголовок и стрелка от приложения к «Программам» цветом стрелки из иконки.
// Использование: make_dmg_bg <out-1x.png> <out-2x.png>
import AppKit

let W: CGFloat = 640, H: CGFloat = 420
let appCenter = NSPoint(x: 170, y: 220)   // координаты сверху-слева, как у Finder
let appsCenter = NSPoint(x: 470, y: 220)

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = g
    // Переворачиваем: дальше рисуем сверху вниз, как раскладывает Finder.
    let ctx = g.cgContext
    ctx.translateBy(x: 0, y: H)
    ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)

    let bg = NSGradient(colors: [NSColor(srgbRed: 0.965, green: 0.969, blue: 0.978, alpha: 1),
                                 NSColor(srgbRed: 0.905, green: 0.914, blue: 0.933, alpha: 1)])!
    bg.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 90)

    NSColor(srgbRed: 0.16, green: 0.18, blue: 0.23, alpha: 0.10).setFill()
    var y: CGFloat = 8
    while y < H { var x: CGFloat = 8; while x < W { NSRect(x: x, y: y, width: 1.4, height: 1.4).fill(); x += 16 }; y += 16 }

    let ink = NSColor(srgbRed: 0.13, green: 0.15, blue: 0.19, alpha: 1)
    let titleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 30, weight: .bold), .foregroundColor: ink, .kern: 0.5]
    let t = "Kadr" as NSString
    let ts = t.size(withAttributes: titleAttrs)
    t.draw(at: NSPoint(x: (W - ts.width) / 2, y: 34), withAttributes: titleAttrs)
    let subAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .regular),
                                                   .foregroundColor: ink.withAlphaComponent(0.62)]
    let sub = "Снимки, пометки, две полки и история буфера — из строки меню" as NSString
    let ss = sub.size(withAttributes: subAttrs)
    sub.draw(at: NSPoint(x: (W - ss.width) / 2, y: 74), withAttributes: subAttrs)

    // Стрелка «перетащите» между иконками.
    let red = NSColor(srgbRed: 1.0, green: 0.27, blue: 0.23, alpha: 0.9)
    let a = NSPoint(x: appCenter.x + 78, y: appCenter.y - 6)
    let b = NSPoint(x: appsCenter.x - 82, y: appsCenter.y - 6)
    let path = NSBezierPath()
    path.move(to: a)
    path.curve(to: b, controlPoint1: NSPoint(x: a.x + 50, y: a.y - 34), controlPoint2: NSPoint(x: b.x - 50, y: b.y - 34))
    path.lineWidth = 4
    path.lineCapStyle = .round
    red.setStroke()
    path.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: b.x + 4, y: b.y + 2))
    head.line(to: NSPoint(x: b.x - 14, y: b.y - 12))
    head.line(to: NSPoint(x: b.x - 12, y: b.y + 9))
    head.close()
    red.setFill()
    head.fill()

    let capAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                                   .foregroundColor: ink.withAlphaComponent(0.55)]
    let cap = "Перетащите Kadr в «Программы»" as NSString
    let cs = cap.size(withAttributes: capAttrs)
    cap.draw(at: NSPoint(x: (W - cs.width) / 2, y: appCenter.y + 22), withAttributes: capAttrs)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let args = CommandLine.arguments
guard args.count >= 3 else { print("использование: make_dmg_bg out.png out@2x.png"); exit(1) }
try! render(scale: 1).write(to: URL(fileURLWithPath: args[1]))
try! render(scale: 2).write(to: URL(fileURLWithPath: args[2]))
print("фон: \(args[1]), \(args[2])")
