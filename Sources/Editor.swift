// Kadr — окно редактора: холст с пометками, масштаб, плавающая панель снизу.
import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

// MARK: - Окно и подложка

final class EditorWindow: NSWindow {
    weak var editor: EditorController?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let e = editor, !e.canvas.isEditingText, e.handleCommandKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) { editor?.escape() }
}

/// Держит документ по центру, когда он меньше видимой области.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return r }
        let f = doc.frame
        if r.width > f.width { r.origin.x = f.minX - (r.width - f.width) / 2 }
        if r.height > f.height { r.origin.y = f.minY - (r.height - f.height) / 2 }
        return r
    }
}

/// «Световой стол»: спокойная подложка с тонкой сеткой точек.
final class LightTableView: NSView {
    static let color = NSColor(name: nil) { ap in
        ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.105, green: 0.11, blue: 0.125, alpha: 1)
            : NSColor(srgbRed: 0.918, green: 0.925, blue: 0.94, alpha: 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        LightTableView.color.setFill()
        dirtyRect.fill()
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        let step: CGFloat = 16
        var y = (dirtyRect.minY / step).rounded(.down) * step
        while y <= dirtyRect.maxY {
            var x = (dirtyRect.minX / step).rounded(.down) * step
            while x <= dirtyRect.maxX {
                NSRect(x: x, y: y, width: 1.2, height: 1.2).fill()
                x += step
            }
            y += step
        }
    }
}

// MARK: - Контроллер

final class EditorController: NSWindowController, NSWindowDelegate {
    static var open: [EditorController] = []
    static var onAllClosed: (() -> Void)?

    let fileURL: URL
    let renderer: Renderer
    var state: DocState
    private var undoStack: [DocState] = []
    private var redoStack: [DocState] = []

    var tool: Tool = .arrow { didSet { refreshToolbar(); canvas.toolChanged() } }
    var colorIndex = 0 { didSet { refreshToolbar(); canvas.styleChanged(colorChanged: true) } }
    var widthIndex = 1 { didSet { refreshToolbar(); canvas.styleChanged(colorChanged: false) } }
    var color: NSColor { Palette.colors[colorIndex] }
    var k: CGFloat { renderer.pxPerPt }
    var widthPx: CGFloat { Palette.widthsPt[widthIndex] * k }
    var fontPx: CGFloat { Palette.fontPt[widthIndex] * k }

    private(set) var canvas: CanvasView!
    private var scroll: NSScrollView!
    private var toolButtons: [Tool: BarButton] = [:]
    private var swatches: [SwatchButton] = []
    private var widthButtons: [WidthButton] = []
    private var undoButton: BarButton!
    private var redoButton: BarButton!
    private let barStrip: CGFloat = 62
    private let pad: CGFloat = 28

    /// Редактор всегда впереди и с фокусом (в т.ч. при Stage Manager): активируем, выводим и повторяем, если не вышло.
    static func bringToFront(_ w: NSWindow?) {
        guard let w else { return }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
        // После выхода screencapture система может вернуть фокус прежней программе с задержкой — повторяем,
        // пока пользователь сам никуда не щёлкнул.
        for delay in [0.12, 0.3, 0.6, 1.0, 1.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard w.isVisible, !(NSApp.isActive && w.isKeyWindow), NSEvent.pressedMouseButtons == 0 else { return }
                NSApp.activate(ignoringOtherApps: true)
                w.makeKeyAndOrderFront(nil)
                w.orderFrontRegardless()
            }
        }
    }

    @discardableResult
    static func show(url: URL) -> EditorController? {
        if let existing = open.first(where: { $0.fileURL == url }) {
            bringToFront(existing.window)
            return existing
        }
        guard let img = ImageFiles.load(url) else {
            let a = NSAlert()
            a.messageText = "Не удалось открыть снимок"
            a.informativeText = url.path
            a.runModal()
            return nil
        }
        let ed = EditorController(url: url, image: img)
        open.append(ed)
        bringToFront(ed.window)
        ed.window?.makeFirstResponder(ed.canvas)
        return ed
    }

    init(url: URL, image: LoadedImage) {
        fileURL = url
        renderer = Renderer(base: image.cg, pxPerPt: image.pxPerPt)
        state = DocState(crop: renderer.fullRect)
        let win = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable],
                               backing: .buffered, defer: false)
        super.init(window: win)
        win.editor = self
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.isRestorable = false
        win.setAccessibilityIdentifier("kadr.editor")
        win.title = url.lastPathComponent
        win.representedURL = url
        win.titlebarAppearsTransparent = true
        win.backgroundColor = LightTableView.color
        win.tabbingMode = .disallowed
        buildUI(in: win)
        sizeWindowToFit()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI(in win: NSWindow) {
        let root = LightTableView()
        win.contentView = root

        canvas = CanvasView(editor: self)
        scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.05
        scroll.maxMagnification = 8
        let clip = CenteringClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = canvas
        root.addSubview(scroll)

        var items: [NSView] = []
        for t in Tool.allCases {
            let b = BarButton(symbol: t.symbol, tip: "\(t.title) (\(t.key))")
            b.onClick = { [weak self] in self?.tool = t }
            toolButtons[t] = b
            items.append(b)
        }
        items.append(BarSeparator())
        for (i, c) in Palette.colors.enumerated() {
            let s = SwatchButton(color: c, tip: "\(Palette.names[i]) (\(i + 1))")
            s.onClick = { [weak self] in self?.colorIndex = i }
            swatches.append(s)
            items.append(s)
        }
        items.append(BarSeparator())
        for (i, d) in [CGFloat(4), 7, 11].enumerated() {
            let w = WidthButton(dot: d, tip: "\(Palette.widthNames[i]) линия, размер текста")
            w.onClick = { [weak self] in self?.widthIndex = i }
            widthButtons.append(w)
            items.append(w)
        }
        items.append(BarSeparator())
        undoButton = BarButton(symbol: "arrow.uturn.backward", tip: "Отменить (⌘Z)")
        undoButton.onClick = { [weak self] in self?.undo() }
        redoButton = BarButton(symbol: "arrow.uturn.forward", tip: "Повторить (⌘⇧Z)")
        redoButton.onClick = { [weak self] in self?.redo() }
        items += [undoButton, redoButton, BarSeparator()]

        let ocr = BarButton(symbol: "text.viewfinder", tip: "Скопировать текст со снимка (T)")
        ocr.onClick = { [weak self] in self?.runOCR() }
        let shelf = BarButton(symbol: "tray.and.arrow.down", tip: "На полку (⌘D)")
        shelf.onClick = { [weak self] in self?.toShelf() }
        let pin = BarButton(symbol: "pin", tip: "Закрепить поверх окон (P)")
        pin.onClick = { [weak self] in self?.pin() }
        let saveAs = BarButton(symbol: "square.and.arrow.down.on.square", tip: "Сохранить как… (⌘⇧S)")
        saveAs.onClick = { [weak self] in self?.saveAs() }
        let save = BarButton(symbol: "square.and.arrow.down", tip: "Сохранить в файл снимка (⌘S)")
        save.onClick = { [weak self] in self?.save() }
        let close = BarButton(symbol: "xmark", tip: "Закрыть (Esc)")
        close.onClick = { [weak self] in self?.window?.performClose(nil) }
        let copy = BarButton(symbol: "doc.on.doc", tip: "Скопировать и закрыть (⌘C, ⌘↩)", title: "Копировать", prominent: true)
        copy.onClick = { [weak self] in self?.copyAndClose() }
        items += [ocr, shelf, pin, saveAs, save, BarSeparator(), close, copy]

        let bar = FloatingBar(items: items)
        root.addSubview(bar)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -barStrip),
            bar.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        let barW = bar.fittingSize.width
        win.contentMinSize = NSSize(width: barW + 24, height: 320)
        refreshToolbar()
    }

    private var docSize: NSSize { NSSize(width: state.crop.width / k, height: state.crop.height / k) }

    /// Окно по размеру снимка (не больше ~85% экрана), по центру экрана под курсором.
    private func sizeWindowToFit() {
        guard let win = window else { return }
        canvas.frame = NSRect(origin: .zero, size: docSize)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let titleH: CGFloat = 28
        let maxW = vis.width * 0.85, maxH = vis.height * 0.85
        let ds = docSize
        let mag = min(1, (maxW - pad * 2) / ds.width, (maxH - titleH - barStrip - pad * 2) / ds.height)
        let minW = min(win.contentMinSize.width, vis.width * 0.98)
        let w = max(minW, ds.width * mag + pad * 2)
        let h = max(win.contentMinSize.height, ds.height * mag + pad * 2 + barStrip)
        var frame = win.frameRect(forContentRect: NSRect(x: 0, y: 0, width: w, height: h))
        frame.origin = NSPoint(x: vis.midX - frame.width / 2, y: vis.midY - frame.height / 2)
        win.setFrame(frame, display: false)
        win.layoutIfNeeded()
        scroll.magnification = fitMagnification()
    }

    private func fitMagnification() -> CGFloat {
        let avail = scroll.contentSize
        let ds = docSize
        guard ds.width > 0, ds.height > 0 else { return 1 }
        return max(0.05, min(1, (avail.width - pad * 2) / ds.width, (avail.height - pad * 2) / ds.height))
    }

    func layoutAfterCropChange() {
        canvas.frame = NSRect(origin: .zero, size: docSize)
        scroll.magnification = fitMagnification()
        canvas.needsDisplay = true
    }

    func refreshToolbar() {
        for (t, b) in toolButtons { b.isSelected = (t == tool) }
        for (i, s) in swatches.enumerated() { s.isSelected = (i == colorIndex) }
        for (i, w) in widthButtons.enumerated() { w.isSelected = (i == widthIndex) }
        undoButton?.isEnabledButton = !undoStack.isEmpty
        redoButton?.isEnabledButton = !redoStack.isEmpty
    }

    // MARK: Правки и история

    func pushUndo() {
        undoStack.append(state)
        if undoStack.count > 300 { undoStack.removeFirst() }
        redoStack.removeAll()
        refreshToolbar()
    }

    func commit(_ change: (inout DocState) -> Void) {
        pushUndo()
        change(&state)
        canvas.needsDisplay = true
    }

    func undo() {
        canvas.commitTextIfNeeded()
        guard let prev = undoStack.popLast() else { NSSound.beep(); return }
        redoStack.append(state)
        apply(prev)
    }

    func redo() {
        guard let next = redoStack.popLast() else { NSSound.beep(); return }
        undoStack.append(state)
        apply(next)
    }

    private func apply(_ s: DocState) {
        let cropChanged = s.crop != state.crop
        state = s
        canvas.selectedID = nil
        if cropChanged { layoutAfterCropChange() }
        canvas.needsDisplay = true
        refreshToolbar()
    }

    // MARK: Клавиши

    func handleCommandKey(_ e: NSEvent) -> Bool {
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard f.contains(.command) else { return false }
        let shift = f.contains(.shift)
        switch Int(e.keyCode) {
        case kVK_ANSI_C where !shift, kVK_Return, kVK_ANSI_KeypadEnter: copyAndClose()
        case kVK_ANSI_S: shift ? saveAs() : save()
        case kVK_ANSI_Z: shift ? redo() : undo()
        case kVK_ANSI_Equal, kVK_ANSI_KeypadPlus: zoom(by: 1.25)
        case kVK_ANSI_Minus, kVK_ANSI_KeypadMinus: zoom(by: 0.8)
        case kVK_ANSI_0: scroll.animator().magnification = fitMagnification()
        case kVK_ANSI_1: scroll.animator().magnification = 1
        case kVK_ANSI_W: window?.performClose(nil)
        case kVK_ANSI_D: toShelf()
        default: return false
        }
        return true
    }

    private func zoom(by f: CGFloat) {
        let clip = scroll.contentView.bounds
        let m = max(scroll.minMagnification, min(scroll.maxMagnification, scroll.magnification * f))
        scroll.setMagnification(m, centeredAt: NSPoint(x: clip.midX, y: clip.midY))
    }

    func escape() {
        if canvas.cancelInteraction() { return }
        window?.performClose(nil)
    }

    // MARK: Действия

    func flattened() -> CGImage? {
        canvas.commitTextIfNeeded()
        return renderer.export(state)
    }

    func copyAndClose() {
        guard let img = flattened() else { return }
        ImageFiles.copyToClipboard(img, pxPerPt: k)
        window?.performClose(nil)
    }

    func save() {
        guard let img = flattened() else { return }
        if ImageFiles.write(img, to: fileURL, pxPerPt: k) {
            HUD.show("Сохранено", symbol: "square.and.arrow.down")
        } else {
            showError("Не удалось сохранить файл", fileURL.path)
        }
    }

    func saveAs() {
        guard let win = window, let img = flattened() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.directoryURL = fileURL.deletingLastPathComponent()
        panel.nameFieldStringValue = fileURL.deletingPathExtension().lastPathComponent + " — правка." + fileURL.pathExtension
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: win) { [weak self] resp in
            guard let self, resp == .OK, let url = panel.url else { return }
            if ImageFiles.write(img, to: url, pxPerPt: self.k) {
                HUD.show("Сохранено", symbol: "square.and.arrow.down")
            } else {
                self.showError("Не удалось сохранить файл", url.path)
            }
        }
    }

    /// Сводит пометки в PNG во временной папке полки и кладёт на переднюю (или новую) полку.
    func toShelf() {
        guard let img = flattened() else { return }
        let name = fileURL.deletingPathExtension().lastPathComponent + ".png"
        let url = ShelfStore.newDir().appendingPathComponent(name)
        guard ImageFiles.write(img, to: url, pxPerPt: k) else { showError("Не удалось подготовить файл", url.path); return }
        let f = window?.frame ?? .zero
        ShelfPanel.addToFrontmost([ShelfItem(file: url, temp: true)], near: NSPoint(x: f.maxX - 150, y: f.maxY - 140))
    }

    func pin() {
        guard let img = flattened() else { return }
        PinWindow.show(img, pxPerPt: k, near: window?.frame)
        window?.performClose(nil)
    }

    func runOCR() {
        guard let img = flattened() else { return }
        let rows = Prefs.keepTableRows
        DispatchQueue.global(qos: .userInitiated).async {
            let text = OCR.recognize(img, keepRows: rows)
            DispatchQueue.main.async { AppActions.deliverOCR(text) }
        }
    }

    private func showError(_ title: String, _ info: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        if let w = window { a.beginSheetModal(for: w) } else { a.runModal() }
    }

    func windowWillClose(_ notification: Notification) {
        EditorController.open.removeAll { $0 === self }
        if EditorController.open.isEmpty { EditorController.onAllClosed?() }
    }
}

// MARK: - Холст

final class CanvasView: NSView, NSTextFieldDelegate {
    unowned let ed: EditorController
    var selectedID: UUID? { didSet { needsDisplay = true } }
    private var drafting: Shape?
    private var cropDraft: (start: CGPoint, end: CGPoint)?
    private var moveStart: CGPoint?
    private var moveOriginal: Shape?
    private var moveDidPush = false
    private var textField: NSTextField?
    private var editingOriginal: Shape?
    private var endingText = false

    var isEditingText: Bool { textField != nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(editor: EditorController) {
        ed = editor
        super.init(frame: .zero)
        wantsLayer = true
        // Тень слоя с явным контуром — не пересчитывается при каждой перерисовке.
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.26
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -3)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layer?.shadowPath = CGPath(rect: CGRect(origin: .zero, size: newSize), transform: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var k: CGFloat { ed.k }
    private var crop: CGRect { ed.state.crop }

    func toPx(_ p: NSPoint) -> CGPoint { CGPoint(x: crop.minX + p.x * k, y: crop.minY + p.y * k) }
    func toView(_ p: CGPoint) -> NSPoint { NSPoint(x: (p.x - crop.minX) / k, y: (p.y - crop.minY) / k) }

    private func location(_ e: NSEvent) -> CGPoint { toPx(convert(e.locationInWindow, from: nil)) }

    // MARK: Отрисовка

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.scaleBy(x: 1 / k, y: 1 / k)
        ctx.translateBy(x: -crop.minX, y: -crop.minY)
        ctx.clip(to: crop)
        ctx.interpolationQuality = .high
        ed.renderer.drawBase(ctx)
        let hidden = editingOriginal?.id
        ed.renderer.draw(ed.state.shapes.filter { $0.id != hidden }, ctx)
        if let d = drafting { ed.renderer.draw(d, ctx) }

        let mag = max(enclosingScrollView?.magnification ?? 1, 0.05)
        let hair = k / mag // один экранный пункт в пикселях снимка
        if let id = selectedID, let s = ed.state.shapes.first(where: { $0.id == id }) {
            let r = s.bounds.insetBy(dx: -4 * hair, dy: -4 * hair)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1.5 * hair)
            ctx.setLineDash(phase: 0, lengths: [5 * hair, 3 * hair])
            ctx.stroke(r)
            ctx.setLineDash(phase: 0, lengths: [])
        }
        if let c = cropDraft {
            let r = rectFrom(c.start, c.end).intersection(crop)
            let outside = CGMutablePath()
            outside.addRect(crop)
            outside.addRect(r)
            ctx.addPath(outside)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
            ctx.fillPath(using: .evenOdd)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1 * hair)
            ctx.setLineDash(phase: 0, lengths: [4 * hair, 3 * hair])
            ctx.stroke(r)
            ctx.setLineDash(phase: 0, lengths: [])
            drawSizeLabel("\(Int(r.width)) × \(Int(r.height))", at: CGPoint(x: r.minX, y: r.maxY + 6 * hair), hair: hair, ctx: ctx)
        }
        ctx.restoreGState()
    }

    private func drawSizeLabel(_ s: String, at p: CGPoint, hair: CGFloat, ctx: CGContext) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11 * hair, weight: .medium),
                                                    .foregroundColor: NSColor.white]
        let sz = (s as NSString).size(withAttributes: attrs)
        let bg = CGRect(x: p.x, y: p.y, width: sz.width + 10 * hair, height: sz.height + 4 * hair)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
        ctx.addPath(CGPath(roundedRect: bg, cornerWidth: 5 * hair, cornerHeight: 5 * hair, transform: nil))
        ctx.fillPath()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        (s as NSString).draw(at: CGPoint(x: p.x + 5 * hair, y: p.y + 2 * hair), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func rectFrom(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    override func resetCursorRects() {
        switch ed.tool {
        case .select: addCursorRect(bounds, cursor: .arrow)
        case .text: addCursorRect(bounds, cursor: .iBeam)
        default: addCursorRect(bounds, cursor: .crosshair)
        }
    }

    func toolChanged() {
        commitTextIfNeeded()
        if ed.tool != .select { selectedID = nil }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    func styleChanged(colorChanged: Bool) {
        textField?.textColor = ed.color
        // Выделенная пометка перекрашивается выбранным цветом.
        if colorChanged, let id = selectedID, let i = ed.state.shapes.firstIndex(where: { $0.id == id }),
           ed.state.shapes[i].tool != .mosaic {
            ed.commit { $0.shapes[i].color = ed.color }
        }
    }

    /// Esc: сначала отменяет текущее действие; true — если было что отменять.
    func cancelInteraction() -> Bool {
        if textField != nil { cancelText(); return true }
        if drafting != nil || cropDraft != nil { drafting = nil; cropDraft = nil; needsDisplay = true; return true }
        if selectedID != nil { selectedID = nil; return true }
        return false
    }

    // MARK: Мышь

    private func topShape(at p: CGPoint) -> Shape? {
        let tol = 6 * k / max(enclosingScrollView?.magnification ?? 1, 0.05)
        return ed.state.shapes.last { $0.hitTest(p, tolerance: tol) }
    }

    override func mouseDown(with e: NSEvent) {
        let wasEditing = isEditingText
        if wasEditing { commitTextIfNeeded() }
        window?.makeFirstResponder(self)
        let p = location(e)
        switch ed.tool {
        case .select:
            let hit = topShape(at: p)
            selectedID = hit?.id
            if let hit, hit.tool == .text, e.clickCount == 2 { beginText(at: hit.points[0], existing: hit); return }
            moveStart = hit == nil ? nil : p
            moveOriginal = hit
            moveDidPush = false
        case .text:
            if wasEditing { return }
            if let hit = topShape(at: p), hit.tool == .text { beginText(at: hit.points[0], existing: hit) }
            else { beginText(at: p, existing: nil) }
        case .badge:
            let r = (10 + Palette.widthsPt[ed.widthIndex]) * k
            let s = Shape(tool: .badge, points: [p], color: ed.color, width: 0, number: ed.state.nextNumber, radius: r)
            ed.commit { $0.shapes.append(s); $0.nextNumber += 1 }
        case .crop:
            cropDraft = (p, p)
        case .pen, .marker:
            let w = ed.tool == .marker ? ed.widthPx * 3.5 : ed.widthPx
            drafting = Shape(tool: ed.tool, points: [p], color: ed.color, width: w)
        default:
            drafting = Shape(tool: ed.tool, points: [p, p], color: ed.color, width: ed.widthPx)
        }
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        var p = location(e)
        let shift = e.modifierFlags.contains(.shift)
        if ed.tool == .select, let start = moveStart, let orig = moveOriginal,
           let i = ed.state.shapes.firstIndex(where: { $0.id == orig.id }) {
            if !moveDidPush { ed.pushUndo(); moveDidPush = true }
            ed.state.shapes[i] = orig.moved(dx: p.x - start.x, dy: p.y - start.y)
            needsDisplay = true
            return
        }
        if var c = cropDraft {
            c.end = clamp(p)
            cropDraft = c
            needsDisplay = true
            return
        }
        guard var d = drafting else { return }
        switch d.tool {
        case .pen, .marker:
            if let last = d.points.last, hypot(p.x - last.x, p.y - last.y) >= 1.5 { d.points.append(p) }
        default:
            let a = d.points[0]
            if shift {
                if d.tool == .rect || d.tool == .oval || d.tool == .mosaic {
                    let side = max(abs(p.x - a.x), abs(p.y - a.y))
                    p = CGPoint(x: a.x + (p.x >= a.x ? side : -side), y: a.y + (p.y >= a.y ? side : -side))
                } else {
                    let ang = (atan2(p.y - a.y, p.x - a.x) / (.pi / 4)).rounded() * (.pi / 4)
                    let len = hypot(p.x - a.x, p.y - a.y)
                    p = CGPoint(x: a.x + cos(ang) * len, y: a.y + sin(ang) * len)
                }
            }
            if d.tool == .mosaic { p = clamp(p) }
            d.points[1] = p
        }
        drafting = d
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        moveStart = nil
        moveOriginal = nil
        if let c = cropDraft {
            cropDraft = nil
            let r = rectFrom(c.start, c.end).intersection(crop).integral
            if r.width >= 8 && r.height >= 8 {
                ed.commit { $0.crop = r }
                ed.layoutAfterCropChange()
            }
            needsDisplay = true
            return
        }
        guard let d = drafting else { return }
        drafting = nil
        let keep: Bool
        switch d.tool {
        case .pen, .marker: keep = true
        case .arrow, .line: keep = hypot(d.points[1].x - d.points[0].x, d.points[1].y - d.points[0].y) > 3 * k
        default: keep = d.rect.width > 2 * k && d.rect.height > 2 * k
        }
        if keep { ed.commit { $0.shapes.append(d) } }
        needsDisplay = true
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: max(crop.minX, min(crop.maxX, p.x)), y: max(crop.minY, min(crop.maxY, p.y)))
    }

    // MARK: Клавиатура

    private static let toolKeys: [Int: Tool] = [
        kVK_ANSI_V: .select, kVK_ANSI_A: .arrow, kVK_ANSI_L: .line, kVK_ANSI_R: .rect, kVK_ANSI_O: .oval,
        kVK_ANSI_F: .pen, kVK_ANSI_M: .marker, kVK_ANSI_X: .text, kVK_ANSI_B: .mosaic, kVK_ANSI_N: .badge,
        kVK_ANSI_C: .crop,
    ]
    private static let colorKeys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7]

    override func keyDown(with e: NSEvent) {
        let f = e.modifierFlags.intersection([.command, .control, .option])
        let code = Int(e.keyCode)
        if code == kVK_Escape { ed.escape(); return }
        if code == kVK_Delete || code == kVK_ForwardDelete {
            if let id = selectedID {
                ed.commit { $0.shapes.removeAll { $0.id == id } }
                selectedID = nil
            } else { NSSound.beep() }
            return
        }
        guard f.isEmpty else { super.keyDown(with: e); return }
        if let t = CanvasView.toolKeys[code] { ed.tool = t; return }
        if let i = CanvasView.colorKeys.firstIndex(of: code) { ed.colorIndex = i; return }
        switch code {
        case kVK_ANSI_T: ed.runOCR()
        case kVK_ANSI_P: ed.pin()
        default: super.keyDown(with: e)
        }
    }

    // MARK: Текст

    private func beginText(at px: CGPoint, existing: Shape?) {
        editingOriginal = existing
        let fontPx = existing?.fontSize ?? ed.fontPx
        let tf = NSTextField(string: existing?.text ?? "")
        tf.font = Shape.font(fontPx / k)
        tf.textColor = existing?.color ?? ed.color
        tf.isBordered = false
        tf.isBezeled = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.usesSingleLineMode = true
        tf.cell?.isScrollable = true
        tf.cell?.wraps = false
        tf.delegate = self
        tf.placeholderString = "Текст"
        let v = toView(px)
        tf.frame.origin = NSPoint(x: v.x - 2, y: v.y)
        addSubview(tf)
        textField = tf
        resizeField()
        window?.makeFirstResponder(tf)
        needsDisplay = true
    }

    private func resizeField() {
        guard let tf = textField else { return }
        let s = (tf.stringValue.isEmpty ? "Текст" : tf.stringValue) as NSString
        let sz = s.size(withAttributes: [.font: tf.font as Any])
        tf.setFrameSize(NSSize(width: ceil(sz.width) + 16, height: ceil(sz.height) + 2))
    }

    func controlTextDidChange(_ obj: Notification) { resizeField() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { commitTextIfNeeded(); return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { cancelText(); return true }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitTextIfNeeded() }

    func commitTextIfNeeded() {
        guard let tf = textField, !endingText else { return }
        endingText = true
        defer { endingText = false }
        let text = tf.stringValue
        let origin = toPx(NSPoint(x: tf.frame.minX + 2, y: tf.frame.minY))
        let fontPx = (tf.font?.pointSize ?? 16) * k
        let color = tf.textColor ?? ed.color
        textField = nil
        tf.removeFromSuperview()
        let original = editingOriginal
        editingOriginal = nil
        window?.makeFirstResponder(self)
        if let original {
            if text.isEmpty {
                ed.commit { $0.shapes.removeAll { $0.id == original.id } }
            } else if text != original.text || color != original.color {
                ed.commit { st in
                    if let i = st.shapes.firstIndex(where: { $0.id == original.id }) {
                        st.shapes[i].text = text
                        st.shapes[i].color = color
                    }
                }
            }
        } else if !text.trimmingCharacters(in: .whitespaces).isEmpty {
            let s = Shape(tool: .text, points: [origin], color: color, width: 0, text: text, fontSize: fontPx)
            ed.commit { $0.shapes.append(s) }
        }
        needsDisplay = true
    }

    private func cancelText() {
        guard let tf = textField else { return }
        endingText = true
        textField = nil
        tf.removeFromSuperview()
        editingOriginal = nil
        endingText = false
        window?.makeFirstResponder(self)
        needsDisplay = true
    }
}
