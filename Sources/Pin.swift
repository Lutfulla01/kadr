// Kadr — закреплённый снимок: окно без рамки поверх всех окон.
import AppKit

final class PinWindow: NSWindow {
    static var open: [PinWindow] = []

    let image: CGImage
    let pxPerPt: CGFloat
    private var zoom: CGFloat = 1
    private let naturalSize: NSSize

    static func show(_ img: CGImage, pxPerPt: CGFloat, near frame: NSRect?) {
        let p = PinWindow(image: img, pxPerPt: pxPerPt, near: frame)
        open.append(p)
        p.makeKeyAndOrderFront(nil)
    }

    private init(image: CGImage, pxPerPt: CGFloat, near frame: NSRect?) {
        self.image = image
        self.pxPerPt = pxPerPt
        let natural = NSSize(width: CGFloat(image.width) / pxPerPt, height: CGFloat(image.height) / pxPerPt)
        var size = natural
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let fit = min(1, vis.width * 0.6 / size.width, vis.height * 0.6 / size.height)
        size = NSSize(width: max(40, natural.width * fit), height: max(40, natural.height * fit))
        naturalSize = natural
        let center = frame.map { NSPoint(x: $0.midX, y: $0.midY) } ?? NSPoint(x: vis.midX, y: vis.midY)
        var rect = NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        rect.origin.x = max(vis.minX, min(vis.maxX - rect.width, rect.origin.x))
        rect.origin.y = max(vis.minY, min(vis.maxY - rect.height, rect.origin.y))
        super.init(contentRect: rect, styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        zoom = fit
        isReleasedWhenClosed = false
        isRestorable = false
        setAccessibilityIdentifier("kadr.pin")
        setAccessibilityTitle("Закреплённый снимок")
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        let v = PinView(image: image)
        v.wantsLayer = true
        v.layer?.cornerRadius = 6
        v.layer?.masksToBounds = true
        v.layer?.borderWidth = 0.5
        v.layer?.borderColor = NSColor.black.withAlphaComponent(0.25).cgColor
        contentView = v
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func close() {
        super.close()
        PinWindow.open.removeAll { $0 === self }
    }

    override func cancelOperation(_ sender: Any?) { close() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close(); return }
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if f.contains(.command) && event.keyCode == 8 { copyImage(); return } // ⌘C
        super.keyDown(with: event)
    }

    /// Масштаб вокруг точки под курсором.
    func setZoom(_ z: CGFloat, anchor: NSPoint? = nil) {
        let nz = max(0.1, min(6, z))
        let newSize = NSSize(width: max(40, naturalSize.width * nz), height: max(40, naturalSize.height * nz))
        let a = anchor ?? NSPoint(x: frame.midX, y: frame.midY)
        let fx = (a.x - frame.minX) / frame.width, fy = (a.y - frame.minY) / frame.height
        let r = NSRect(x: a.x - newSize.width * fx, y: a.y - newSize.height * fy, width: newSize.width, height: newSize.height)
        zoom = nz
        setFrame(r, display: true)
    }

    var currentZoom: CGFloat { zoom }

    func copyImage() {
        ImageFiles.copyToClipboard(image, pxPerPt: pxPerPt)
        HUD.show("Скопировано", symbol: "doc.on.doc")
    }

    func toShelf() {
        let url = ShelfStore.newDir().appendingPathComponent("Kadr \(ShelfStore.stamp()).png")
        guard ImageFiles.write(image, to: url, pxPerPt: pxPerPt) else { return }
        ShelfPanel.addToFrontmost([ShelfItem(file: url, temp: true)], near: NSPoint(x: frame.maxX, y: frame.maxY))
    }

    func saveImage() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.directoryURL = Prefs.saveFolder
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'в' HH.mm.ss"
        panel.nameFieldStringValue = "Kadr \(f.string(from: Date())).png"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            ImageFiles.write(image, to: url, pxPerPt: pxPerPt)
        }
    }
}

final class PinView: NSView {
    let image: CGImage
    init(image: CGImage) {
        self.image = image
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: bounds)
    }

    private var pin: PinWindow? { window as? PinWindow }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { window?.close(); return }
        window?.performDrag(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let pin else { return }
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 40 : event.scrollingDeltaY / 4
        if event.modifierFlags.contains(.option) {
            pin.alphaValue = max(0.15, min(1, pin.alphaValue + dy * 0.1))
            return
        }
        let anchor = NSEvent.mouseLocation
        pin.setZoom(pin.currentZoom * (1 + dy * 0.1), anchor: anchor)
    }

    override func magnify(with event: NSEvent) {
        guard let pin else { return }
        pin.setZoom(pin.currentZoom * (1 + event.magnification), anchor: NSEvent.mouseLocation)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        let items: [(String, String, Selector)] = [
            ("Копировать", "doc.on.doc", #selector(copyAction)),
            ("Сохранить…", "square.and.arrow.down", #selector(saveAction)),
            ("На полку", "tray.and.arrow.down", #selector(shelfAction)),
            ("Закрыть", "xmark", #selector(closeAction)),
        ]
        for (t, s, sel) in items {
            let it = NSMenuItem(title: t, action: sel, keyEquivalent: "")
            it.target = self
            it.image = NSImage(systemSymbolName: s, accessibilityDescription: nil)
            m.addItem(it)
            if t == "На полку" { m.addItem(.separator()) }
        }
        return m
    }

    @objc private func copyAction() { pin?.copyImage() }
    @objc private func saveAction() { pin?.saveImage() }
    @objc private func shelfAction() { pin?.toShelf() }
    @objc private func closeAction() { window?.close() }
}
