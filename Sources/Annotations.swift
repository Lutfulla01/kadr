// Kadr — модель пометок и их отрисовка. Один и тот же код рисует и на экране, и при экспорте.
// Все координаты — в пикселях исходного снимка, начало — левый верхний угол.
import AppKit
import CoreImage

enum Tool: String, CaseIterable {
    case select, arrow, line, rect, oval, pen, marker, text, mosaic, badge, crop

    var title: String {
        switch self {
        case .select: return "Выделение"
        case .arrow: return "Стрелка"
        case .line: return "Линия"
        case .rect: return "Прямоугольник"
        case .oval: return "Овал"
        case .pen: return "Ручка"
        case .marker: return "Маркер"
        case .text: return "Текст"
        case .mosaic: return "Мозаика"
        case .badge: return "Нумерация"
        case .crop: return "Обрезка"
        }
    }

    var key: String {
        switch self {
        case .select: return "V"
        case .arrow: return "A"
        case .line: return "L"
        case .rect: return "R"
        case .oval: return "O"
        case .pen: return "F"
        case .marker: return "M"
        case .text: return "X"
        case .mosaic: return "B"
        case .badge: return "N"
        case .crop: return "C"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rect: return "rectangle"
        case .oval: return "circle"
        case .pen: return "scribble"
        case .marker: return "highlighter"
        case .text: return "textformat"
        case .mosaic: return "checkerboard.rectangle"
        case .badge: return "1.circle"
        case .crop: return "crop"
        }
    }
}

struct Palette {
    static let colors: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1), // красный
        NSColor(srgbRed: 1.00, green: 0.58, blue: 0.00, alpha: 1), // оранжевый
        NSColor(srgbRed: 1.00, green: 0.82, blue: 0.04, alpha: 1), // жёлтый
        NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1), // зелёный
        NSColor(srgbRed: 0.04, green: 0.52, blue: 1.00, alpha: 1), // синий
        NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1), // чёрный
        NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1), // белый
    ]
    static let names = ["Красный", "Оранжевый", "Жёлтый", "Зелёный", "Синий", "Чёрный", "Белый"]
    /// Толщины линий в точках экрана (тонкая, средняя, толстая).
    static let widthsPt: [CGFloat] = [2, 4, 8]
    static let widthNames = ["Тонкая", "Средняя", "Толстая"]
    static let fontPt: [CGFloat] = [16, 22, 32]
}

struct Shape {
    var id = UUID()
    var tool: Tool
    var points: [CGPoint]
    var color: NSColor
    var width: CGFloat       // px
    var text: String = ""
    var fontSize: CGFloat = 0 // px
    var number: Int = 0
    var radius: CGFloat = 0   // px, для номерков

    var rect: CGRect {
        guard let a = points.first, let b = points.last else { return .zero }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    static func font(_ size: CGFloat) -> NSFont { .systemFont(ofSize: size, weight: .semibold) }

    var textAttributes: [NSAttributedString.Key: Any] {
        [.font: Shape.font(fontSize), .foregroundColor: color]
    }

    /// Прямоугольник, занимаемый пометкой (для выделения).
    var bounds: CGRect {
        switch tool {
        case .text:
            let s = (text as NSString).size(withAttributes: textAttributes)
            return CGRect(origin: points.first ?? .zero, size: s)
        case .badge:
            let c = points.first ?? .zero
            return CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)
        case .pen, .marker:
            let xs = points.map { $0.x }, ys = points.map { $0.y }
            guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return .zero }
            return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0).insetBy(dx: -width / 2, dy: -width / 2)
        default:
            return rect.insetBy(dx: -width / 2, dy: -width / 2)
        }
    }

    func hitTest(_ p: CGPoint, tolerance: CGFloat) -> Bool {
        switch tool {
        case .arrow, .line:
            guard let a = points.first, let b = points.last else { return false }
            return distance(p, a, b) <= tolerance + width / 2
        case .pen, .marker:
            for i in 1..<max(points.count, 1) where distance(p, points[i - 1], points[i]) <= tolerance + width / 2 { return true }
            return points.count == 1 && hypot(p.x - points[0].x, p.y - points[0].y) <= tolerance + width
        case .rect, .oval:
            let outer = rect.insetBy(dx: -tolerance - width, dy: -tolerance - width)
            let inner = rect.insetBy(dx: tolerance + width, dy: tolerance + width)
            return outer.contains(p) && (inner.isNull || inner.width <= 0 || inner.height <= 0 || !inner.contains(p))
        default:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        }
    }

    func moved(dx: CGFloat, dy: CGFloat) -> Shape {
        var s = self
        s.points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        return s
    }

    private func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 == 0 { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

struct DocState {
    var shapes: [Shape] = []
    var crop: CGRect
    var nextNumber = 1
}

final class Renderer {
    let base: CGImage
    let pxPerPt: CGFloat
    var fullRect: CGRect { CGRect(x: 0, y: 0, width: base.width, height: base.height) }

    private lazy var ciBase = CIImage(cgImage: base)
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private var mosaicCache: [String: CGImage] = [:]

    init(base: CGImage, pxPerPt: CGFloat) {
        self.base = base
        self.pxPerPt = pxPerPt
    }

    /// Рисует картинку в контексте с перевёрнутой осью Y (начало сверху).
    static func drawImage(_ img: CGImage, in r: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        ctx.restoreGState()
    }

    func drawBase(_ ctx: CGContext) {
        Renderer.drawImage(base, in: fullRect, ctx: ctx)
    }

    func draw(_ shapes: [Shape], _ ctx: CGContext) {
        for s in shapes { draw(s, ctx) }
    }

    func draw(_ s: Shape, _ ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(s.color.cgColor)
        ctx.setFillColor(s.color.cgColor)
        ctx.setLineWidth(s.width)
        switch s.tool {
        case .arrow:
            drawArrow(s, ctx)
        case .line:
            guard let a = s.points.first, let b = s.points.last else { return }
            ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
        case .rect:
            ctx.stroke(s.rect)
        case .oval:
            ctx.strokeEllipse(in: s.rect)
        case .pen:
            addSmoothPath(s.points, ctx); ctx.strokePath()
        case .marker:
            ctx.setBlendMode(.multiply)
            ctx.setStrokeColor(s.color.withAlphaComponent(0.42).cgColor)
            ctx.setLineCap(.square)
            addSmoothPath(s.points, ctx); ctx.strokePath()
        case .text:
            let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ns
            (s.text as NSString).draw(at: s.points.first ?? .zero, withAttributes: s.textAttributes)
            NSGraphicsContext.restoreGraphicsState()
        case .mosaic:
            let r = s.rect.intersection(fullRect).integral
            guard r.width >= 1, r.height >= 1, let img = mosaic(r) else { return }
            Renderer.drawImage(img, in: r, ctx: ctx)
        case .badge:
            drawBadge(s, ctx)
        case .select, .crop:
            break
        }
    }

    private func drawArrow(_ s: Shape, _ ctx: CGContext) {
        guard let a = s.points.first, let b = s.points.last else { return }
        let dist = hypot(b.x - a.x, b.y - a.y)
        guard dist > 0.5 else { return }
        let ang = atan2(b.y - a.y, b.x - a.x)
        let headLen = min(max(s.width * 3.6, 12 * pxPerPt), dist)
        let headHalf = headLen * 0.5
        let baseP = CGPoint(x: b.x - cos(ang) * headLen * 0.82, y: b.y - sin(ang) * headLen * 0.82)
        ctx.move(to: a); ctx.addLine(to: baseP); ctx.strokePath()
        let back = CGPoint(x: b.x - cos(ang) * headLen, y: b.y - sin(ang) * headLen)
        let px = -sin(ang) * headHalf, py = cos(ang) * headHalf
        ctx.move(to: b)
        ctx.addLine(to: CGPoint(x: back.x + px, y: back.y + py))
        ctx.addLine(to: baseP)
        ctx.addLine(to: CGPoint(x: back.x - px, y: back.y - py))
        ctx.closePath()
        ctx.setLineWidth(max(1, s.width * 0.35))
        ctx.drawPath(using: .fillStroke)
    }

    private func addSmoothPath(_ pts: [CGPoint], _ ctx: CGContext) {
        guard let first = pts.first else { return }
        ctx.move(to: first)
        if pts.count == 1 { ctx.addLine(to: first); return }
        if pts.count == 2 { ctx.addLine(to: pts[1]); return }
        for i in 1..<pts.count - 1 {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            ctx.addQuadCurve(to: mid, control: pts[i])
        }
        ctx.addLine(to: pts[pts.count - 1])
    }

    private func drawBadge(_ s: Shape, _ ctx: CGContext) {
        let c = s.points.first ?? .zero
        let r = s.radius
        let circle = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: r * 0.08), blur: r * 0.3,
                      color: NSColor.black.withAlphaComponent(0.3).cgColor)
        ctx.fillEllipse(in: circle)
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(max(1.5, r * 0.14))
        ctx.strokeEllipse(in: circle.insetBy(dx: r * 0.07, dy: r * 0.07))
        let textColor: NSColor = luminance(s.color) > 0.7 ? NSColor(white: 0.1, alpha: 1) : .white
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: r * (s.number > 9 ? 0.95 : 1.15), weight: .bold),
            .foregroundColor: textColor,
        ]
        let str = "\(s.number)" as NSString
        let sz = str.size(withAttributes: attrs)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        str.draw(at: CGPoint(x: c.x - sz.width / 2, y: c.y - sz.height / 2), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func luminance(_ c: NSColor) -> CGFloat {
        guard let s = c.usingColorSpace(.sRGB) else { return 0 }
        return 0.2126 * s.redComponent + 0.7152 * s.greenComponent + 0.0722 * s.blueComponent
    }

    /// Пикселизация участка исходного снимка (CIPixellate), r — в пикселях, начало сверху.
    func mosaic(_ r: CGRect) -> CGImage? {
        let key = "\(r.minX),\(r.minY),\(r.width),\(r.height)"
        if let c = mosaicCache[key] { return c }
        let block = max(6, (10 * pxPerPt).rounded())
        let H = CGFloat(base.height)
        let ciRect = CGRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height)
        guard let f = CIFilter(name: "CIPixellate"), let blur = CIFilter(name: "CIBoxBlur") else { return nil }
        // Сначала усредняем (размытие), иначе CIPixellate берёт один пиксель из блока и мозаика «рваная».
        blur.setValue(ciBase.clampedToExtent(), forKey: kCIInputImageKey)
        blur.setValue(min(100, block * 0.6), forKey: kCIInputRadiusKey)
        f.setValue(blur.outputImage ?? ciBase.clampedToExtent(), forKey: kCIInputImageKey)
        f.setValue(block, forKey: kCIInputScaleKey)
        f.setValue(CIVector(x: ciRect.minX, y: ciRect.maxY), forKey: kCIInputCenterKey)
        guard let out = f.outputImage,
              let img = ci.createCGImage(out, from: ciRect, format: .RGBA8,
                                         colorSpace: base.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        if mosaicCache.count > 64 { mosaicCache.removeAll() }
        mosaicCache[key] = img
        return img
    }

    /// Экспорт: снимок + пометки в исходном разрешении, с учётом обрезки.
    func export(_ st: DocState) -> CGImage? {
        let crop = st.crop.intersection(fullRect).integral
        let w = Int(crop.width), h = Int(crop.height)
        guard w > 0, h > 0 else { return nil }
        var space = base.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        if space.model != .rgb { space = CGColorSpace(name: CGColorSpace.sRGB)! }
        let make = { (cs: CGColorSpace) in
            CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let ctx = make(space) ?? make(CGColorSpace(name: CGColorSpace.sRGB)!) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -crop.minX, y: -crop.minY)
        ctx.interpolationQuality = .high
        drawBase(ctx)
        draw(st.shapes, ctx)
        return ctx.makeImage()
    }
}
