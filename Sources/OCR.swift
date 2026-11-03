// Kadr — распознавание текста (Vision) и всплывающая подсказка HUD.
import AppKit
import Vision

enum OCR {
    /// Распознаёт текст (ru-RU + en-US, точный режим, языковая коррекция).
    /// keepRows: группирует фрагменты в строки по Y и соединяет колонки табуляцией.
    static func recognize(_ cg: CGImage, keepRows: Bool) -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        let wanted = ["ru-RU", "en-US"]
        if let supported = try? req.supportedRecognitionLanguages() {
            let langs = wanted.filter { supported.contains($0) }
            req.recognitionLanguages = langs.isEmpty ? ["en-US"] : langs
        } else {
            req.recognitionLanguages = wanted
        }
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do { try handler.perform([req]) } catch { return "" }
        let obs = (req.results ?? []).compactMap { o -> (CGRect, String)? in
            guard let s = o.topCandidates(1).first?.string, !s.isEmpty else { return nil }
            return (o.boundingBox, s)
        }
        if obs.isEmpty { return "" }
        if !keepRows {
            // Порядок сверху вниз, внутри строки слева направо.
            return groupRows(obs).map { $0.map { $0.1 }.joined(separator: " ") }.joined(separator: "\n")
        }
        return groupRows(obs).map { $0.map { $0.1 }.joined(separator: "\t") }.joined(separator: "\n")
    }

    /// Группировка по вертикали: фрагменты, чьи центры по Y ближе половины высоты строки, — одна строка.
    private static func groupRows(_ obs: [(CGRect, String)]) -> [[(CGRect, String)]] {
        let sorted = obs.sorted { $0.0.midY > $1.0.midY } // Vision: начало координат снизу
        let heights = sorted.map { $0.0.height }.sorted()
        let typical = heights[heights.count / 2]
        var rows: [[(CGRect, String)]] = []
        var rowY: [CGFloat] = []
        for o in sorted {
            if let last = rowY.last, abs(last - o.0.midY) < typical * 0.6 {
                rows[rows.count - 1].append(o)
                let r = rows[rows.count - 1]
                rowY[rowY.count - 1] = r.map { $0.0.midY }.reduce(0, +) / CGFloat(r.count)
            } else {
                rows.append([o])
                rowY.append(o.0.midY)
            }
        }
        return rows.map { $0.sorted { $0.0.minX < $1.0.minX } }
    }
}

extension OCR {
    /// Первое распознавание после запуска долго грузит модели Vision — прогреваем в фоне при запуске.
    static func warmUp() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let img = NSImage(size: NSSize(width: 240, height: 64), flipped: false) { r in
                NSColor.white.setFill(); r.fill()
                ("Kadr 123 Снимок" as NSString).draw(at: NSPoint(x: 10, y: 18), withAttributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black])
                return true
            }
            guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            DispatchQueue.global(qos: .utility).async {
                let t0 = Date()
                let text = recognize(cg, keepRows: false)
                KadrLog.write("прогрев распознавания: \(String(format: "%.1f", Date().timeIntervalSince(t0))) с, «\(text.replacingOccurrences(of: "\n", with: " "))»")
            }
        }
    }
}

// MARK: - HUD

final class HUD {
    private static var panel: NSPanel?
    private(set) static var shownCount = 0     // для проверок (StateDump)
    private(set) static var lastText = ""

    static func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// sticky — не исчезает сам (например, «Распознаю…»), его сменит следующая подсказка.
    /// nearCursor — маленькая подсказка у курсора (копирование жестом), держится ~0,8 с.
    static func show(_ text: String, symbol: String = "checkmark.circle.fill", sticky: Bool = false, nearCursor: Bool = false) {
        let sticky = sticky
        shownCount += 1; lastText = text
        panel?.orderOut(nil)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        icon.contentTintColor = .controlAccentColor
        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 18)
        let size = stack.fittingSize

        let fx = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = size.height / 2
        fx.layer?.masksToBounds = true
        stack.frame = fx.bounds
        fx.addSubview(stack)

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        var origin = NSPoint(x: vis.midX - size.width / 2, y: vis.minY + vis.height * 0.18)
        if nearCursor {
            origin = NSPoint(x: min(max(mouse.x + 14, vis.minX + 4), vis.maxX - size.width - 4),
                             y: min(max(mouse.y - size.height - 14, vis.minY + 4), vis.maxY - size.height - 4))
        }
        let p = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.contentView = fx
        p.alphaValue = 0
        p.orderFrontRegardless()
        panel = p
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.15
            p.animator().alphaValue = 1
        }, completionHandler: {
            DispatchQueue.main.asyncAfter(deadline: .now() + (sticky ? 90 : nearCursor ? 0.45 : 0.75)) {
                guard panel === p else { p.orderOut(nil); return }
                NSAnimationContext.runAnimationGroup({ c in
                    c.duration = 0.3
                    p.animator().alphaValue = 0
                }, completionHandler: {
                    p.orderOut(nil)
                    if panel === p { panel = nil }
                })
            }
        })
    }
}
