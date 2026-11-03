// Kadr — «Полка»: временное место для перетаскивания файлов, картинок, текста и ссылок между программами.
import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

// MARK: - Элемент

final class ShelfItem {
    enum Kind { case file, link }

    let id = UUID()
    let kind: Kind
    let url: URL
    let title: String
    let isTemp: Bool
    var thumbnail: NSImage?

    init(file: URL, temp: Bool) {
        kind = .file
        url = file
        title = file.lastPathComponent
        isTemp = temp
    }

    init(link: URL, title: String?) {
        kind = .link
        url = link
        let t = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = t.isEmpty ? (link.host ?? link.absoluteString) : t
        isTemp = false
    }

    private var type: UTType? { UTType(filenameExtension: url.pathExtension) }
    var isImage: Bool { kind == .file && (type?.conforms(to: .image) ?? false) }
    var isText: Bool { kind == .file && (type?.conforms(to: .plainText) ?? false) }
    var isDirectory: Bool { kind == .file && ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) }
    var byteSize: Int64 { Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }

    var detail: String {
        if kind == .link { return url.host ?? url.absoluteString }
        if isDirectory { return "Папка" }
        return ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }

    /// Что кладётся в буфер перетаскивания: ссылка на файл (+ текст для текстовых заметок) или веб-ссылка.
    func pasteboardWriter() -> NSPasteboardWriting {
        if isText, isTemp, let s = try? String(contentsOf: url, encoding: .utf8) {
            let pi = NSPasteboardItem()
            pi.setString(url.absoluteString, forType: .fileURL)
            pi.setString(s, forType: .string)
            return pi
        }
        return url as NSURL
    }

    func loadThumbnail(_ done: @escaping () -> Void) {
        if kind == .link {
            thumbnail = ShelfItem.linkTile
            done()
            return
        }
        thumbnail = NSWorkspace.shared.icon(forFile: url.path)
        done()
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 128, height: 128), scale: 2,
                                               representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            guard let rep else { return }
            let img = rep.nsImage
            DispatchQueue.main.async {
                self?.thumbnail = img
                done()
            }
        }
    }

    static let linkTile: NSImage = NSImage(size: NSSize(width: 128, height: 128), flipped: false) { r in
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: r.insetBy(dx: 8, dy: 8), xRadius: 26, yRadius: 26).fill()
        let cfg = NSImage.SymbolConfiguration(pointSize: 54, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        if let sym = NSImage(systemSymbolName: "link", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            let s = sym.size
            sym.draw(in: NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height))
        }
        return true
    }
}

// MARK: - Временные файлы полки

enum ShelfStore {
    static let root = Profile.name != nil ? Profile.dataDir.appendingPathComponent("Shelf", isDirectory: true)
        : FileManager.default.temporaryDirectory.appendingPathComponent("KadrShelf", isDirectory: true)
    private static let promiseQueue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        return q
    }()

    static func newDir() -> URL {
        let d = root.appendingPathComponent(String(UUID().uuidString.prefix(8)), isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'в' HH.mm.ss"
        return f.string(from: Date())
    }

    static func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\\n\r\t")
        let cleaned = s.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return String(cleaned.prefix(60))
    }

    static func write(_ data: Data, name: String) -> URL? {
        let url = newDir().appendingPathComponent(name)
        return (try? data.write(to: url, options: .atomic)) != nil ? url : nil
    }

    /// Удаляет файлы полки старше суток (вызывается при запуске).
    static func cleanup() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let border = Date().addingTimeInterval(-86400)
        for d in dirs {
            let m = (try? d.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if m < border { try? fm.removeItem(at: d) }
        }
    }

    static var readableTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .URL, .png, .tiff, .string, NSPasteboard.PasteboardType("public.jpeg")]
            + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    /// Разбирает перетаскивание/буфер: файлы → обещанные файлы → картинка → ссылка → текст.
    @discardableResult
    static func receive(_ pb: NSPasteboard, add: @escaping ([ShelfItem]) -> Void) -> Bool {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            add(urls.map { ShelfItem(file: $0, temp: false) })
            return true
        }
        if let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !promises.isEmpty {
            for r in promises {
                r.receivePromisedFiles(atDestination: newDir(), options: [:], operationQueue: promiseQueue) { url, error in
                    guard error == nil else { return }
                    DispatchQueue.main.async { add([ShelfItem(file: url, temp: true)]) }
                }
            }
            return true
        }
        if let png = pb.data(forType: .png), let url = write(png, name: "Изображение \(stamp()).png") {
            add([ShelfItem(file: url, temp: true)])
            return true
        }
        if let jpg = pb.data(forType: NSPasteboard.PasteboardType("public.jpeg")),
           let url = write(jpg, name: "Изображение \(stamp()).jpg") {
            add([ShelfItem(file: url, temp: true)])
            return true
        }
        if let img = (pb.readObjects(forClasses: [NSImage.self]) as? [NSImage])?.first,
           let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]),
           let url = write(png, name: "Изображение \(stamp()).png") {
            add([ShelfItem(file: url, temp: true)])
            return true
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL] {
            let web = urls.filter { !$0.isFileURL }
            if !web.isEmpty {
                let name = pb.string(forType: NSPasteboard.PasteboardType("public.url-name"))
                add(web.map { ShelfItem(link: $0, title: web.count == 1 ? name : nil) })
                return true
            }
        }
        if let s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            if !s.contains(where: { $0.isWhitespace }), let u = URL(string: s), let sch = u.scheme,
               ["http", "https"].contains(sch.lowercased()) {
                add([ShelfItem(link: u, title: nil)])
                return true
            }
            let firstLine = s.split(separator: "\n").first.map(String.init) ?? "Текст"
            var name = sanitize(firstLine)
            if name.isEmpty { name = "Текст \(stamp())" }
            if let url = write(Data(s.utf8), name: name + ".txt") {
                add([ShelfItem(file: url, temp: true)])
                return true
            }
        }
        return false
    }
}

func russianPlural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let n10 = n % 10, n100 = n % 100
    if n10 == 1 && n100 != 11 { return one }
    if (2...4).contains(n10) && !(12...14).contains(n100) { return few }
    return many
}

// MARK: - Окно полки

final class ShelfPanel: NSPanel {
    static var all: [ShelfPanel] = []
    static var onAllClosed: (() -> Void)?

    private(set) var items: [ShelfItem] = []
    var expanded = false
    var selectedID: UUID? { didSet { shelfView.refreshSelection() } }
    var openedByShake = false
    private var shelfView: ShelfView!

    static let collapsedSize = NSSize(width: 244, height: 222)
    static let stackCenterFromTop: CGFloat = 81

    /// Новая полка; center — точка экрана, куда встанет середина стопки (под курсор).
    @discardableResult
    static func open(items: [ShelfItem] = [], center: NSPoint? = nil) -> ShelfPanel {
        let c = center ?? NSEvent.mouseLocation
        let size = collapsedSize
        var rect = NSRect(x: c.x - size.width / 2, y: c.y + stackCenterFromTop - size.height,
                          width: size.width, height: size.height)
        let screen = NSScreen.screens.first { NSMouseInRect(c, $0.frame, false) } ?? NSScreen.main
        if let vis = screen?.visibleFrame {
            rect.origin.x = max(vis.minX + 4, min(vis.maxX - rect.width - 4, rect.origin.x))
            rect.origin.y = max(vis.minY + 4, min(vis.maxY - rect.height - 4, rect.origin.y))
        }
        let p = ShelfPanel(contentRect: rect)
        all.append(p)
        p.add(items)
        p.orderFrontRegardless()
        return p
    }

    /// Добавляет в последнюю полку, а если полок нет — в новую.
    static func addToFrontmost(_ items: [ShelfItem], near center: NSPoint?) {
        if let p = all.last {
            p.add(items)
            p.orderFrontRegardless()
        } else {
            open(items: items, center: center)
        }
    }

    static func panel(at point: NSPoint) -> ShelfPanel? {
        all.first { $0.isVisible && NSMouseInRect(point, $0.frame, false) }
    }

    private init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        isRestorable = false
        setAccessibilityIdentifier("kadr.shelf")
        setAccessibilityTitle("Полка")
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        shelfView = ShelfView(panel: self)
        contentView = shelfView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        if expanded { setExpanded(false) } else { close() }
    }

    override func keyDown(with event: NSEvent) {
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch Int(event.keyCode) {
        case 53: cancelOperation(nil)
        case 51, 117: removeItem()
        case 8 where f.contains(.command): copyItems()
        case 49: openItems() // Пробел — открыть
        default: super.keyDown(with: event)
        }
    }

    override func close() {
        super.close()
        ShakeMonitor.shared.noteShelfClosed()
        ShelfPanel.all.removeAll { $0 === self }
        if ShelfPanel.all.isEmpty { ShelfPanel.onAllClosed?() }
    }

    // MARK: Содержимое

    func add(_ new: [ShelfItem]) {
        guard !new.isEmpty else { return }
        let existing = Set(items.filter { $0.kind == .file }.map { $0.url.standardizedFileURL })
        let fresh = new.filter { $0.kind == .link || !existing.contains($0.url.standardizedFileURL) }
        items += fresh
        for it in fresh { it.loadThumbnail { [weak self] in self?.shelfView.reload() } }
        // Последняя полка, куда добавляли, — «передняя».
        ShelfPanel.all.removeAll { $0 === self }
        ShelfPanel.all.append(self)
        shelfView.reload()
    }

    func remove(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
        if let s = selectedID, ids.contains(s) { selectedID = nil }
        if items.isEmpty { close(); return }
        if items.count < 2 && expanded { setExpanded(false) }
        resizeForContent()
        shelfView.reload()
    }

    /// Цель действий: выбранная строка в развёрнутом виде, иначе вся полка.
    var targets: [ShelfItem] {
        if expanded, let s = selectedID, let it = items.first(where: { $0.id == s }) { return [it] }
        return items
    }

    func setExpanded(_ e: Bool) {
        guard e != expanded, !(e && items.count < 2) else { return }
        expanded = e
        if !e { selectedID = nil }
        resizeForContent()
        shelfView.reload()
    }

    private func resizeForContent() {
        let size: NSSize
        if expanded {
            let listH = min(CGFloat(items.count) * ShelfView.rowH, 308)
            size = NSSize(width: 300, height: ShelfView.headerH + listH + ShelfView.barArea)
        } else {
            size = ShelfPanel.collapsedSize
        }
        var r = frame
        r.origin.y = r.maxY - size.height
        r.origin.x += (r.width - size.width) / 2
        r.size = size
        setFrame(r, display: true, animate: false)
        invalidateShadow()
    }

    // MARK: Действия

    func openItems() {
        for it in targets { NSWorkspace.shared.open(it.url) }
    }

    func revealItems() {
        let files = targets.filter { $0.kind == .file }.map { $0.url }
        if files.isEmpty { NSSound.beep(); return }
        NSWorkspace.shared.activateFileViewerSelecting(files)
    }

    func copyItems() {
        let t = targets
        guard !t.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(t.map { $0.url as NSURL })
        if t.count == 1, let it = t.first {
            if it.isImage, let img = NSImage(contentsOf: it.url) {
                if let tiff = img.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
                if it.url.pathExtension.lowercased() == "png", let d = try? Data(contentsOf: it.url) { pb.setData(d, forType: .png) }
            } else if it.isText, let s = try? String(contentsOf: it.url, encoding: .utf8) {
                pb.setString(s, forType: .string)
            } else if it.kind == .link {
                pb.setString(it.url.absoluteString, forType: .string)
            }
        }
        HUD.show("Скопировано", symbol: "doc.on.doc")
    }

    func share(from view: NSView, rect: NSRect? = nil) {
        let urls = targets.map { $0.url }
        guard !urls.isEmpty else { return }
        let picker = NSSharingServicePicker(items: urls)
        picker.show(relativeTo: rect ?? view.bounds, of: view, preferredEdge: .minY)
    }

    func removeItem() {
        if expanded, let s = selectedID { remove([s]); return }
        if let last = items.last { remove([last.id]) }
    }

    func clearAll() {
        items.removeAll()
        close()
    }

    /// Перетаскивание закончилось: убрать унесённое, если так настроено.
    func dragEnded(ids: Set<UUID>, operation: NSDragOperation) {
        guard operation != [], Prefs.shelfRemoveAfterDrag else { return }
        remove(ids)
    }

    func forceActionBar() { shelfView.setBarVisible(true, animated: false, sticky: true) }
}

// MARK: - Содержимое окна

final class ShelfView: NSVisualEffectView {
    static let rowH: CGFloat = 44
    static let headerH: CGFloat = 40
    static let barArea: CGFloat = 52

    unowned let panel: ShelfPanel
    private let stack: ShelfStackView
    private let caption = NSTextField(labelWithString: "")
    private let subcaption = NSTextField(labelWithString: "")
    private let header = NSView()
    private let backButton: BarButton
    private let headerTitle = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let list = ShelfListView()
    private let bar = NSStackView()
    private var shareButton: BarButton!
    private var barSticky = false
    private var dropHighlight = false { didSet { updateBorder() } }

    override var isFlipped: Bool { true }

    init(panel: ShelfPanel) {
        self.panel = panel
        stack = ShelfStackView(panel: panel)
        backButton = BarButton(symbol: "chevron.left", tip: "Свернуть (Esc)")
        super.init(frame: NSRect(origin: .zero, size: ShelfPanel.collapsedSize))
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.masksToBounds = true
        updateBorder()

        addSubview(stack)
        for (l, size, weight, color) in [(caption, CGFloat(12.5), NSFont.Weight.semibold, NSColor.labelColor),
                                         (subcaption, CGFloat(11), NSFont.Weight.regular, NSColor.secondaryLabelColor)] {
            l.font = .systemFont(ofSize: size, weight: weight)
            l.textColor = color
            l.alignment = .center
            l.lineBreakMode = .byTruncatingMiddle
            addSubview(l)
        }

        backButton.translatesAutoresizingMaskIntoConstraints = true
        backButton.onClick = { [weak panel] in panel?.setExpanded(false) }
        headerTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        header.addSubview(backButton)
        header.addSubview(headerTitle)
        addSubview(header)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = list
        addSubview(scroll)

        let actions: [(String, String, (ShelfPanel) -> Void)] = [
            ("arrow.up.forward.app", "Открыть (Пробел)", { $0.openItems() }),
            ("folder", "Показать в Finder", { $0.revealItems() }),
            ("doc.on.doc", "Копировать (⌘C)", { $0.copyItems() }),
            ("square.and.arrow.up", "Поделиться", { _ in }),
            ("minus.circle", "Убрать элемент (Delete)", { $0.removeItem() }),
            ("trash", "Очистить полку", { $0.clearAll() }),
            ("xmark", "Закрыть (Esc)", { $0.close() }),
        ]
        bar.orientation = .horizontal
        bar.spacing = 2
        bar.edgeInsets = NSEdgeInsets(top: 3, left: 3, bottom: 3, right: 3)
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 11
        for (sym, tip, act) in actions {
            let b = BarButton(symbol: sym, tip: tip)
            if sym == "square.and.arrow.up" {
                shareButton = b
                b.onClick = { [weak self, weak b] in
                    guard let self, let b else { return }
                    self.panel.share(from: b)
                }
            } else {
                b.onClick = { [weak panel] in if let panel { act(panel) } }
            }
            bar.addArrangedSubview(b)
        }
        bar.alphaValue = 0
        addSubview(bar)

        registerForDraggedTypes(ShelfStore.readableTypes)
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateBorder() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderWidth = dropHighlight ? 2 : 0.5
            layer?.borderColor = (dropHighlight ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
            bar.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    func reload() {
        let items = panel.items
        if items.isEmpty {
            caption.stringValue = "Пустая полка"
            subcaption.stringValue = "файлы, картинки, текст, ссылки"
        } else if items.count == 1, let it = items.first {
            caption.stringValue = it.title
            subcaption.stringValue = it.detail
        } else {
            let allFiles = items.allSatisfy { $0.kind == .file }
            let noun = allFiles ? russianPlural(items.count, "файл", "файла", "файлов")
                                : russianPlural(items.count, "элемент", "элемента", "элементов")
            caption.stringValue = "\(items.count) \(noun)"
            let total = items.filter { $0.kind == .file && !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.byteSize }
            subcaption.stringValue = total > 0 ? ByteCountFormatter.string(fromByteCount: total, countStyle: .file) : ""
        }
        headerTitle.stringValue = caption.stringValue
        stack.needsDisplay = true
        list.rebuild(panel: panel)
        needsLayout = true
    }

    func refreshSelection() { list.refreshSelection(panel.selectedID) }

    override func layout() {
        super.layout()
        let W = bounds.width, H = bounds.height
        let barSize = bar.fittingSize
        bar.frame = NSRect(x: (W - barSize.width) / 2, y: H - barSize.height - 8, width: barSize.width, height: barSize.height)
        let exp = panel.expanded
        stack.isHidden = exp
        caption.isHidden = exp
        subcaption.isHidden = exp || bar.alphaValue > 0.5
        header.isHidden = !exp
        scroll.isHidden = !exp
        if exp {
            header.frame = NSRect(x: 0, y: 0, width: W, height: ShelfView.headerH)
            backButton.frame = NSRect(x: 8, y: 6, width: 30, height: 30)
            headerTitle.frame = NSRect(x: 42, y: 12, width: W - 54, height: 18)
            scroll.frame = NSRect(x: 6, y: ShelfView.headerH, width: W - 12, height: H - ShelfView.headerH - ShelfView.barArea)
            list.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: list.contentHeight)
        } else {
            stack.frame = NSRect(x: 0, y: 10, width: W, height: 142)
            caption.frame = NSRect(x: 14, y: 156, width: W - 28, height: 18)
            subcaption.frame = NSRect(x: 14, y: 175, width: W - 28, height: 16)
        }
    }

    // MARK: Наведение и панель действий

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { setBarVisible(true, animated: true) }
    override func mouseExited(with event: NSEvent) { setBarVisible(false, animated: true) }

    func setBarVisible(_ v: Bool, animated: Bool, sticky: Bool = false) {
        if sticky { barSticky = true }
        let show = v || barSticky
        let target: CGFloat = (show && !panel.items.isEmpty) ? 1 : 0
        if animated {
            NSAnimationContext.runAnimationGroup { c in
                c.duration = 0.15
                bar.animator().alphaValue = target
            }
        } else {
            bar.alphaValue = target
        }
        subcaption.isHidden = panel.expanded || target > 0.5
    }

    // MARK: Меню по правой кнопке

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        guard !panel.items.isEmpty else {
            m.addItem(menuItem("Закрыть", "xmark") { $0.close() })
            return m
        }
        m.addItem(menuItem("Открыть", "arrow.up.forward.app") { $0.openItems() })
        m.addItem(menuItem("Показать в Finder", "folder") { $0.revealItems() })
        m.addItem(menuItem("Копировать", "doc.on.doc") { $0.copyItems() })
        let share = NSSharingServicePicker(items: panel.targets.map { $0.url }).standardShareMenuItem
        m.addItem(share)
        m.addItem(.separator())
        m.addItem(menuItem("Убрать элемент", "minus.circle") { $0.removeItem() })
        m.addItem(menuItem("Очистить полку", "trash") { $0.clearAll() })
        m.addItem(.separator())
        if panel.items.count > 1 {
            if panel.expanded {
                m.addItem(menuItem("Свернуть", "rectangle.compress.vertical") { $0.setExpanded(false) })
            } else {
                m.addItem(menuItem("Развернуть список", "list.bullet") { $0.setExpanded(true) })
            }
        }
        m.addItem(menuItem("Закрыть", "xmark") { $0.close() })
        return m
    }

    private func menuItem(_ title: String, _ symbol: String, _ act: @escaping (ShelfPanel) -> Void) -> NSMenuItem {
        let it = ClosureMenuItem(title: title) { [weak panel] in if let panel { act(panel) } }
        it.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return it
    }

    // MARK: Приём перетаскивания

    private func isOwnDrag(_ info: NSDraggingInfo) -> Bool {
        (info.draggingSource as? NSView)?.window === panel
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if isOwnDrag(sender) { return [] }
        dropHighlight = true
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isOwnDrag(sender) ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { dropHighlight = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHighlight = false
        if isOwnDrag(sender) { return false }
        return ShelfStore.receive(sender.draggingPasteboard) { [weak panel] items in panel?.add(items) }
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) { dropHighlight = false }
}

/// Пункт меню с замыканием.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

// MARK: - Перетаскивание наружу

/// Источник перетаскивания: запоминает, какие элементы унесли.
final class ShelfDragSource: NSObject, NSDraggingSource {
    weak var panel: ShelfPanel?
    var ids: Set<UUID> = []

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Только копия: иначе Finder создаёт псевдоним на временный файл полки (он удаляется через сутки).
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        panel?.dragEnded(ids: ids, operation: operation)
    }

    static func begin(from view: NSView, items: [ShelfItem], event: NSEvent, source: ShelfDragSource) {
        guard !items.isEmpty else { return }
        source.ids = Set(items.map { $0.id })
        let p = view.convert(event.locationInWindow, from: nil)
        let s: CGFloat = 64
        var dragItems: [NSDraggingItem] = []
        for (i, it) in items.enumerated() {
            let di = NSDraggingItem(pasteboardWriter: it.pasteboardWriter())
            let off = CGFloat(min(i, 4)) * 5
            let img = it.thumbnail ?? NSWorkspace.shared.icon(forFile: it.url.path)
            di.setDraggingFrame(NSRect(x: p.x - s / 2 + off, y: p.y - s / 2 + off, width: s, height: s), contents: img)
            dragItems.append(di)
        }
        let session = view.beginDraggingSession(with: dragItems, event: event, source: source)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }
}

/// Свёрнутая полка: стопка миниатюр. Тянуть — унести всё, щелчок — развернуть список.
final class ShelfStackView: NSView {
    unowned let panel: ShelfPanel
    private let dragSource = ShelfDragSource()
    private var downEvent: NSEvent?
    private var dragging = false

    init(panel: ShelfPanel) {
        self.panel = panel
        super.init(frame: .zero)
        dragSource.panel = panel
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { panel.items.isEmpty }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let items = panel.items
        let c = NSPoint(x: bounds.midX, y: bounds.midY + 2)
        if items.isEmpty {
            let r = NSRect(x: c.x - 60, y: c.y - 56, width: 120, height: 112)
            let p = NSBezierPath(roundedRect: r, xRadius: 16, yRadius: 16)
            p.lineWidth = 1.5
            p.setLineDash([6, 4], count: 2, phase: 0)
            NSColor.secondaryLabelColor.withAlphaComponent(0.6).setStroke()
            p.stroke()
            let cfg = NSImage.SymbolConfiguration(pointSize: 30, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor]))
            if let sym = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
                let s = sym.size
                sym.draw(in: NSRect(x: c.x - s.width / 2, y: c.y - s.height / 2 - 10, width: s.width, height: s.height))
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                                        .foregroundColor: NSColor.secondaryLabelColor]
            let t = "Перетащите сюда" as NSString
            let ts = t.size(withAttributes: attrs)
            t.draw(at: NSPoint(x: c.x - ts.width / 2, y: c.y + 20), withAttributes: attrs)
            return
        }
        let shown = Array(items.suffix(3))
        let box: CGFloat = 104
        let layout: [(CGFloat, CGFloat)] = [(0, 0), (-12, -7), (12, 7)] // (сдвиг X, угол) — верхняя, вторая, третья
        for (depth, it) in shown.reversed().enumerated().reversed() {
            let (dx, ang) = layout[min(depth, 2)]
            guard let img = it.thumbnail else { continue }
            NSGraphicsContext.saveGraphicsState()
            let t = NSAffineTransform()
            t.translateX(by: c.x + dx, yBy: c.y + CGFloat(depth) * 3)
            t.rotate(byDegrees: ang)
            t.concat()
            let s = img.size
            let k = min(box / max(s.width, 1), box / max(s.height, 1))
            let r = NSRect(x: -s.width * k / 2, y: -s.height * k / 2, width: s.width * k, height: s.height * k)
            let sh = NSShadow()
            sh.shadowBlurRadius = 6
            sh.shadowOffset = NSSize(width: 0, height: -2)
            sh.shadowColor = NSColor.black.withAlphaComponent(0.28)
            sh.set()
            img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        if items.count > 1 {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold),
                                                        .foregroundColor: NSColor.white]
            let t = "\(items.count)" as NSString
            let ts = t.size(withAttributes: attrs)
            let w = max(22, ts.width + 12)
            let r = NSRect(x: c.x + 46, y: c.y - 62, width: w, height: 22)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: r, xRadius: 11, yRadius: 11).fill()
            t.draw(at: NSPoint(x: r.midX - ts.width / 2, y: r.midY - ts.height / 2), withAttributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if panel.items.isEmpty { super.mouseDown(with: event); return }
        downEvent = event
        dragging = false
        if event.clickCount == 2 && panel.items.count == 1 { panel.openItems() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent, !dragging else { return }
        let a = down.locationInWindow, b = event.locationInWindow
        guard hypot(b.x - a.x, b.y - a.y) > 3 else { return }
        dragging = true
        ShelfDragSource.begin(from: self, items: panel.items, event: down, source: dragSource)
    }

    override func mouseUp(with event: NSEvent) {
        defer { downEvent = nil }
        if !dragging, event.clickCount == 1, panel.items.count > 1 { panel.setExpanded(true) }
    }
}

/// Развёрнутая полка: список строк.
final class ShelfListView: NSView {
    private var rows: [ShelfRowView] = []
    override var isFlipped: Bool { true }
    var contentHeight: CGFloat { CGFloat(rows.count) * ShelfView.rowH }

    func rebuild(panel: ShelfPanel) {
        rows.forEach { $0.removeFromSuperview() }
        rows = panel.items.map { ShelfRowView(item: $0, panel: panel) }
        rows.forEach(addSubview)
        needsLayout = true
        refreshSelection(panel.selectedID)
    }

    override func layout() {
        super.layout()
        for (i, r) in rows.enumerated() {
            r.frame = NSRect(x: 0, y: CGFloat(i) * ShelfView.rowH, width: bounds.width, height: ShelfView.rowH)
        }
    }

    func refreshSelection(_ id: UUID?) { for r in rows { r.isSelected = (r.item.id == id) } }
}

final class ShelfRowView: NSView {
    let item: ShelfItem
    unowned let panel: ShelfPanel
    var isSelected = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }
    private let thumb = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let dragSource = ShelfDragSource()
    private var downEvent: NSEvent?
    private var dragging = false

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(item: ShelfItem, panel: ShelfPanel) {
        self.item = item
        self.panel = panel
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("kadr.shelf.row")
        setAccessibilityLabel(item.title)
        dragSource.panel = panel
        thumb.image = item.thumbnail
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.frame = NSRect(x: 8, y: 6, width: 32, height: 32)
        name.stringValue = item.title
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingMiddle
        detail.stringValue = item.detail
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        toolTip = item.kind == .file ? item.url.path : item.url.absoluteString
        [thumb, name, detail].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        name.frame = NSRect(x: 48, y: 5, width: bounds.width - 56, height: 17)
        detail.frame = NSRect(x: 48, y: 23, width: bounds.width - 56, height: 15)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 2, dy: 2)
        let p = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        if isSelected { NSColor.controlAccentColor.withAlphaComponent(0.2).setFill(); p.fill() }
        else if hovering { NSColor.labelColor.withAlphaComponent(0.07).setFill(); p.fill() }
    }

    override func mouseDown(with event: NSEvent) {
        downEvent = event
        dragging = false
        panel.selectedID = item.id
        if event.clickCount == 2 { NSWorkspace.shared.open(item.url) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent, !dragging else { return }
        let a = down.locationInWindow, b = event.locationInWindow
        guard hypot(b.x - a.x, b.y - a.y) > 3 else { return }
        dragging = true
        ShelfDragSource.begin(from: self, items: [item], event: down, source: dragSource)
    }

    override func mouseUp(with event: NSEvent) { downEvent = nil }

    override func menu(for event: NSEvent) -> NSMenu? {
        panel.selectedID = item.id
        return enclosingShelfView?.menu(for: event)
    }

    private var enclosingShelfView: ShelfView? {
        var v = superview
        while let s = v { if let sv = s as? ShelfView { return sv }; v = s.superview }
        return nil
    }
}
