// Kadr — «Текстовая полка»: постоянный набор фрагментов текста. Щелчок копирует, перетаскивание уносит текст,
// отмеченные фрагменты можно вставить по очереди в активное поле. Идея — из более раннего проекта автора, Textover.
import AppKit
import ApplicationServices
import Carbon.HIToolbox

struct Snippet: Codable, Equatable {
    var id = UUID()
    var text: String
    var selected = false

    var title: String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? text
    }

    var preview: String {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.dropFirst().joined(separator: " · ")
    }
}

enum TextShelfStore {
    /// Для тестов можно подменить файл (KADR_TEXTSHELF_STORE).
    static var url: URL = {
        if let p = ProcessInfo.processInfo.environment["KADR_TEXTSHELF_STORE"], !p.isEmpty { return URL(fileURLWithPath: p) }
        return Profile.dataDir.appendingPathComponent("text-shelf.json")
    }()

    static func load() -> [Snippet] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Snippet].self, from: d)) ?? []
    }

    static func save(_ s: [Snippet]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        if let d = try? enc.encode(s) { try? d.write(to: url, options: .atomic) }
    }

    static func split(_ s: String, paragraphs: Bool) -> [String] {
        let norm = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let parts: [String]
        if paragraphs {
            parts = norm.components(separatedBy: "\n").reduce(into: [String]()) { acc, line in
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    if acc.last != "" { acc.append("") }
                } else if acc.isEmpty || acc.last == "" {
                    if acc.last == "" { acc.removeLast() }
                    acc.append(line)
                } else {
                    acc[acc.count - 1] += "\n" + line
                }
            }
        } else {
            parts = norm.components(separatedBy: "\n")
        }
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

extension NSPasteboard.PasteboardType {
    static let kadrSnippet = NSPasteboard.PasteboardType("uz.lutfulla.kadr.snippet")
}

// MARK: - Окно

final class TextShelfPanel: NSPanel {
    static let shared = TextShelfPanel()

    var snippets: [Snippet] = TextShelfStore.load() {
        didSet {
            TextShelfStore.save(snippets)
            loadedShelfView?.reload()
        }
    }
    var pinned: Bool {
        get { Prefs.d.bool(forKey: "textShelfPinned") }
        set { Prefs.d.set(newValue, forKey: "textShelfPinned"); loadedShelfView?.refreshPin(); restartTimer() }
    }
    private(set) var pasting = false
    var editing = false { didSet { restartTimer() } }
    private var hideTimer: Timer?
    /// Вид полки строится по требованию и выгружается через releaseDelay после скрытия
    /// (слои CoreAnimation и строки); заметки хранятся в панели, так что пересборка ничего не теряет.
    private var loadedShelfView: TextShelfView?
    private var shelfView: TextShelfView {
        if let v = loadedShelfView { return v }
        let v = TextShelfView(panel: self)
        loadedShelfView = v
        contentView = v
        if !isVisible { scheduleRelease() } else { v.reload() }
        return v
    }
    static let releaseDelay = 10.0
    private var releaseWork: DispatchWorkItem?

    private func scheduleRelease() {
        releaseWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.releaseView() }
        releaseWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + TextShelfPanel.releaseDelay, execute: w)
    }

    private func releaseView() {
        releaseWork = nil
        guard let v = loadedShelfView, !isVisible else { return }
        if SequentialPaster.busy { scheduleRelease(); return }
        v.endEditing()
        makeFirstResponder(nil)
        contentView = nil
        loadedShelfView = nil
        MemoryRelief.soon()
    }
    private var undoSnapshot: [Snippet]?

    static let size = NSSize(width: 360, height: 420)

    private init() {
        super.init(contentRect: NSRect(origin: .zero, size: TextShelfPanel.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        isRestorable = false
        setAccessibilityIdentifier("kadr.textShelf")
        setAccessibilityTitle(L("Text Shelf"))
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        _ = shelfView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { hide() }

    // MARK: Показ и автоскрытие

    func toggle(at p: NSPoint) {
        if isVisible { hide() } else { show(at: p) }
    }

    /// p — точка экрана, куда встанет верх списка (под курсор).
    func show(at p: NSPoint?) {
        let c = p ?? NSEvent.mouseLocation
        var r = NSRect(x: c.x - frame.width / 2, y: c.y + 70 - frame.height, width: frame.width, height: frame.height)
        let screen = NSScreen.screens.first { NSMouseInRect(c, $0.frame, false) } ?? NSScreen.main
        if let vis = screen?.visibleFrame {
            r.origin.x = max(vis.minX + 4, min(vis.maxX - r.width - 4, r.origin.x))
            r.origin.y = max(vis.minY + 4, min(vis.maxY - r.height - 4, r.origin.y))
        }
        releaseWork?.cancel(); releaseWork = nil
        setFrame(r, display: true)
        shelfView.reload()
        orderFrontRegardless()
        restartTimer()
    }

    func hide() {
        ShakeMonitor.shared.noteShelfClosed()
        hideTimer?.invalidate()
        hideTimer = nil
        loadedShelfView?.endEditing()
        orderOut(nil)
        scheduleRelease()
    }

    /// Любое действие пользователя продлевает показ.
    private var lastAutoHide = Prefs.textShelfAutoHide
    private var prefsObserver: NSKeyValueObservation?

    /// Смена «Скрывать без действий» действует сразу, а не после следующего действия на полке.
    func observeAutoHidePref() {
        guard prefsObserver == nil else { return }
        prefsObserver = Prefs.d.observe(\.textShelfAutoHide, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self, Prefs.textShelfAutoHide != self.lastAutoHide else { return }
                self.restartTimer()
            }
        }
    }

    func restartTimer() {
        observeAutoHidePref()
        lastAutoHide = Prefs.textShelfAutoHide
        hideTimer?.invalidate()
        hideTimer = nil
        let secs = Prefs.textShelfAutoHide
        guard isVisible, secs > 0, !pinned else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(secs), repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.editing || self.pasting || NSMouseInRect(NSEvent.mouseLocation, self.frame, false) {
                self.restartTimer()
            } else {
                self.hide()
            }
        }
    }

    // MARK: Содержимое

    func add(_ texts: [String], at index: Int? = nil) {
        let new = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.map { Snippet(text: $0) }
        guard !new.isEmpty else { return }
        var s = snippets
        let i = max(0, min(index ?? s.count, s.count))
        s.insert(contentsOf: new, at: i)
        snippets = s
        restartTimer()
    }

    func move(id: UUID, to index: Int) {
        guard let from = snippets.firstIndex(where: { $0.id == id }) else { return }
        var s = snippets
        let item = s.remove(at: from)
        let to = max(0, min(index > from ? index - 1 : index, s.count))
        s.insert(item, at: to)
        if s != snippets { snippets = s }
    }

    func copy(_ sn: Snippet) {
        ImageFiles.copyText(sn.text)
        restartTimer()
    }

    func importClipboard() {
        guard let s = NSPasteboard.general.string(forType: .string), !s.isEmpty else {
            shelfView.note(L("No text on the clipboard")); return
        }
        let parts = TextShelfStore.split(s, paragraphs: Prefs.importByParagraphs)
        add(parts)
        shelfView.note(Lf("Added %d %@", parts.count, Lp(parts.count, "snippet", "snippets")))
    }

    func addClipboardAsOne() {
        guard let s = NSPasteboard.general.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            shelfView.note(L("No text on the clipboard")); return
        }
        add([s])
        shelfView.note(L("Added as one snippet"))
    }

    func toggleSelectAll() {
        let all = !snippets.allSatisfy { $0.selected }
        snippets = snippets.map { var x = $0; x.selected = all; return x }
        restartTimer()
    }

    var selectedTexts: [String] { snippets.filter { $0.selected }.map { $0.text } }

    func joinSelected() {
        let t = selectedTexts
        guard !t.isEmpty else { shelfView.note(L("Select snippets with the circles on the left")); return }
        ImageFiles.copyText(t.joined(separator: "\n"))
        shelfView.note(Lf("Copied %d %@ as one", t.count, Lp(t.count, "snippet", "snippets")))
    }

    func clearAll() {
        guard !snippets.isEmpty else { return }
        undoSnapshot = snippets
        snippets = []
        shelfView.note(L("Shelf cleared"), button: (L("Restore"), { [weak self] in
            guard let self, let s = self.undoSnapshot else { return }
            self.snippets = s
            self.undoSnapshot = nil
            self.shelfView.note(L("Restored"))
        }), duration: 6)
    }

    func delete(_ id: UUID) {
        snippets.removeAll { $0.id == id }
        restartTimer()
    }

    func update(_ id: UUID, text: String) {
        guard let i = snippets.firstIndex(where: { $0.id == id }) else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { snippets.remove(at: i) } else if snippets[i].text != t { snippets[i].text = t }
    }

    func setSelected(_ id: UUID, _ v: Bool) {
        guard let i = snippets.firstIndex(where: { $0.id == id }) else { return }
        snippets[i].selected = v
        restartTimer()
    }

    // MARK: Вставка по очереди

    func pasteSelected() {
        let texts = selectedTexts
        guard !texts.isEmpty else { shelfView.note(L("Select snippets with the circles on the left")); return }
        guard !pasting, !SequentialPaster.busy else { return }
        guard SequentialPaster.ensureAccess() else {
            shelfView.note(L("To paste for you, Kadr needs Accessibility access"),
                           button: (L("Open"), { SequentialPaster.openAccessibilitySettings() }), duration: 10)
            return
        }
        pasting = true
        // Фокус должен остаться у программы, куда вставляем.
        let target = isKeyWindow ? NSWorkspace.shared.frontmostApplication : nil
        let writers: [(NSPasteboard) -> Void] = texts.map { t in { pb in pb.setString(t, forType: .string) } }
        SequentialPaster.run(writers, separator: Prefs.pasteSeparator, restore: true, activate: target) { [weak self] in
            self?.pasting = false
            self?.shelfView.note(Lf("Pasted %d %@", texts.count, Lp(texts.count, "snippet", "snippets")))
            self?.restartTimer()
        }
    }

    static func postKey(_ key: CGKeyCode, flags: CGEventFlags) { SequentialPaster.postKey(key, flags: flags) }
}

// MARK: - Содержимое окна

final class TextShelfView: NSVisualEffectView, NSTextFieldDelegate {
    static let rowH: CGFloat = 50
    unowned let panel: TextShelfPanel
    private let title = NSTextField(labelWithString: L("Text Shelf"))
    private let count = NSTextField(labelWithString: "")
    private let pinButton = BarButton(symbol: "pin", tip: L("Keep Shelf Open"))
    private let closeButton = BarButton(symbol: "xmark", tip: L("Hide (Esc)"))
    private let scroll = NSScrollView()
    let list = TextListView()
    private let empty = NSTextField(labelWithString: L("Drop text here\nor click Import Clipboard"))
    private let noteLabel = NSTextField(labelWithString: "")
    private let noteButton = NSButton(title: "", target: nil, action: nil)
    private var noteAction: (() -> Void)?
    private var noteTimer: Timer?
    private let bar = NSStackView()
    private var editField: NSTextField?
    private var editingID: UUID?
    private var dropHighlight = false { didSet { updateBorder() } }

    override var isFlipped: Bool { true }

    init(panel: TextShelfPanel) {
        self.panel = panel
        super.init(frame: NSRect(origin: .zero, size: TextShelfPanel.size))
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.masksToBounds = true

        title.font = .systemFont(ofSize: 13, weight: .semibold)
        count.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        count.textColor = .secondaryLabelColor
        pinButton.translatesAutoresizingMaskIntoConstraints = true
        closeButton.translatesAutoresizingMaskIntoConstraints = true
        pinButton.onClick = { [weak panel] in panel?.pinned.toggle() }
        closeButton.onClick = { [weak panel] in panel?.hide() }
        [title, count, pinButton, closeButton].forEach(addSubview)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = list
        addSubview(scroll)
        empty.alignment = .center
        empty.textColor = .secondaryLabelColor
        empty.font = .systemFont(ofSize: 12)
        empty.maximumNumberOfLines = 2
        addSubview(empty)

        noteLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.lineBreakMode = .byTruncatingTail
        noteButton.bezelStyle = .inline
        noteButton.controlSize = .small
        noteButton.target = self
        noteButton.action = #selector(noteButtonPressed)
        noteButton.isHidden = true
        addSubview(noteLabel)
        addSubview(noteButton)

        let items: [NSView] = [
            button("doc.on.clipboard", L("Import Clipboard: one snippet per line (by paragraph in Settings)")) { $0.importClipboard() },
            button("plus.square.on.square", L("Add Clipboard as One Snippet")) { $0.addClipboardAsOne() },
            BarSeparator(),
            button("checklist", L("Select All / Deselect All")) { $0.toggleSelectAll() },
            button("arrow.triangle.merge", L("Merge Selected and Copy")) { $0.joinSelected() },
            button("trash", L("Clear Shelf")) { $0.clearAll() },
            BarSeparator(),
            {
                let b = BarButton(symbol: "keyboard", tip: L("Paste selected snippets one by one into the active field"), title: L("Paste"), prominent: true)
                b.onClick = { [weak panel] in panel?.pasteSelected() }
                return b
            }(),
        ]
        bar.orientation = .horizontal
        bar.spacing = 2
        items.forEach { bar.addArrangedSubview($0) }
        addSubview(bar)

        registerForDraggedTypes([.kadrSnippet, .string, .URL])
        refreshPin()
        updateBorder()
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func button(_ sym: String, _ tip: String, _ act: @escaping (TextShelfPanel) -> Void) -> BarButton {
        let b = BarButton(symbol: sym, tip: tip)
        b.onClick = { [weak panel] in if let panel { act(panel) } }
        return b
    }

    private func updateBorder() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderWidth = dropHighlight ? 2 : 0.5
            layer?.borderColor = (dropHighlight ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    func refreshPin() {
        pinButton.setSymbol(panel.pinned ? "pin.fill" : "pin")
        pinButton.isSelected = panel.pinned
        pinButton.toolTip = panel.pinned ? L("Pinned: stays open") : L("Keep Shelf Open")
    }

    func reload() {
        let n = panel.snippets.count
        count.stringValue = n > 0 ? "\(n)" : ""
        empty.isHidden = n > 0
        list.rebuild(panel: panel, view: self)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let W = bounds.width, H = bounds.height
        title.sizeToFit()
        title.frame.origin = NSPoint(x: 16, y: 14)
        count.sizeToFit()
        count.frame.origin = NSPoint(x: title.frame.maxX + 6, y: 15)
        closeButton.frame = NSRect(x: W - 38, y: 8, width: 30, height: 30)
        pinButton.frame = NSRect(x: W - 70, y: 8, width: 30, height: 30)
        let barSize = bar.fittingSize
        bar.frame = NSRect(x: (W - barSize.width) / 2, y: H - barSize.height - 10, width: barSize.width, height: barSize.height)
        let noteY = bar.frame.minY - 24
        noteButton.sizeToFit()
        let nb = noteButton.isHidden ? 0 : noteButton.frame.width + 6
        noteLabel.frame = NSRect(x: 16, y: noteY + 3, width: W - 32 - nb, height: 16)
        noteButton.frame.origin = NSPoint(x: W - 16 - noteButton.frame.width, y: noteY)
        scroll.frame = NSRect(x: 6, y: 44, width: W - 12, height: noteY - 48)
        list.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(list.contentHeight, scroll.contentSize.height))
        empty.frame = NSRect(x: 20, y: scroll.frame.midY - 18, width: W - 40, height: 36)
    }

    // MARK: Подсказка внизу (без всплывающих окон)

    func note(_ text: String, button: (String, () -> Void)? = nil, duration: TimeInterval = 2.5) {
        noteTimer?.invalidate()
        noteLabel.stringValue = text
        noteAction = button?.1
        noteButton.title = button?.0 ?? ""
        noteButton.isHidden = button == nil
        needsLayout = true
        noteTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.noteLabel.stringValue = ""
            self?.noteButton.isHidden = true
            self?.noteAction = nil
        }
        panel.restartTimer()
    }

    @objc private func noteButtonPressed() {
        noteAction?()
    }

    // MARK: Наведение

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { panel.restartTimer() }
    override func mouseMoved(with event: NSEvent) { panel.restartTimer() }

    // MARK: Правка на месте

    func beginEditing(_ sn: Snippet, in row: NSView) {
        endEditing()
        let f = NSTextField(string: sn.text)
        f.font = .systemFont(ofSize: 13)
        f.isBordered = true
        f.bezelStyle = .roundedBezel
        f.focusRingType = .default
        f.usesSingleLineMode = false
        f.cell?.wraps = true
        f.cell?.isScrollable = false
        f.lineBreakMode = .byWordWrapping
        f.delegate = self
        f.toolTip = L("Return to save, ⌥Return for a new line, Esc to cancel")
        f.frame = row.convert(row.bounds.insetBy(dx: 4, dy: 3), to: list)
        list.addSubview(f)
        editField = f
        editingID = sn.id
        panel.editing = true
        panel.makeKey()
        panel.makeFirstResponder(f)
    }

    func endEditing(commit: Bool = true) {
        guard let f = editField, let id = editingID else { return }
        editField = nil
        editingID = nil
        let text = f.stringValue
        f.delegate = nil
        f.removeFromSuperview()
        panel.editing = false
        if commit { panel.update(id, text: text) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { endEditing(); return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { endEditing(commit: false); return true }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) { endEditing() }

    // MARK: Приём перетаскивания (снаружи — новый фрагмент, изнутри — перестановка)

    private func insertionIndex(_ info: NSDraggingInfo) -> Int {
        let p = list.convert(info.draggingLocation, from: nil)
        return max(0, min(panel.snippets.count, Int((p.y / TextShelfView.rowH).rounded())))
    }

    private func isInternal(_ info: NSDraggingInfo) -> Bool {
        info.draggingPasteboard.types?.contains(.kadrSnippet) == true && (info.draggingSource as? NSView)?.window === panel
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        panel.restartTimer()
        list.dropIndex = insertionIndex(sender)
        if isInternal(sender) { return .move }
        dropHighlight = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropHighlight = false
        list.dropIndex = nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHighlight = false
        let idx = insertionIndex(sender)
        list.dropIndex = nil
        let pb = sender.draggingPasteboard
        if isInternal(sender), let s = pb.string(forType: .kadrSnippet), let id = UUID(uuidString: s) {
            panel.move(id: id, to: idx)
            return true
        }
        if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            panel.add([s], at: idx)
            return true
        }
        if let u = (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.first {
            panel.add([u.isFileURL ? u.path : u.absoluteString], at: idx)
            return true
        }
        return false
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        dropHighlight = false
        list.dropIndex = nil
    }
}

final class TextListView: NSView {
    private var rows: [TextRowView] = []
    var dropIndex: Int? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    var contentHeight: CGFloat { CGFloat(rows.count) * TextShelfView.rowH }

    func rebuild(panel: TextShelfPanel, view: TextShelfView) {
        rows.forEach { $0.removeFromSuperview() }
        rows = panel.snippets.map { TextRowView(snippet: $0, panel: panel, shelfView: view) }
        rows.forEach(addSubview)
        needsLayout = true
    }

    // Ширину строк задаём явно: автоподгонка от нулевой ширины раздувает их.
    override func layout() {
        super.layout()
        for (i, r) in rows.enumerated() {
            r.frame = NSRect(x: 0, y: CGFloat(i) * TextShelfView.rowH, width: bounds.width, height: TextShelfView.rowH)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let i = dropIndex else { return }
        let y = CGFloat(i) * TextShelfView.rowH
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: 10, y: y - 1.5, width: bounds.width - 20, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
    }
}

final class TextRowView: NSView, NSDraggingSource {
    let snippet: Snippet
    unowned let panel: TextShelfPanel
    unowned let shelfView: TextShelfView
    private let check: BarButton
    private let del: BarButton
    private let titleLabel = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(labelWithString: "")
    private var hovering = false { didSet { needsDisplay = true; del.alphaValue = hovering ? 1 : 0 } }
    private var downEvent: NSEvent?
    private var dragging = false

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(snippet: Snippet, panel: TextShelfPanel, shelfView: TextShelfView) {
        self.snippet = snippet
        self.panel = panel
        self.shelfView = shelfView
        check = BarButton(symbol: snippet.selected ? "checkmark.circle.fill" : "circle",
                          tip: snippet.selected ? L("Deselect") : L("Select for Pasting"))
        del = BarButton(symbol: "trash", tip: L("Delete Snippet"))
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("kadr.textShelf.row")
        setAccessibilityLabel(snippet.title)
        check.translatesAutoresizingMaskIntoConstraints = true
        check.isSelected = snippet.selected
        check.frame = NSRect(x: 6, y: 10, width: 30, height: 30)
        let id = snippet.id, sel = snippet.selected
        check.onClick = { [weak panel] in panel?.setSelected(id, !sel) }
        del.translatesAutoresizingMaskIntoConstraints = true
        del.frame = NSRect(x: 300, y: 10, width: 30, height: 30)
        del.alphaValue = 0
        del.onClick = { [weak panel] in panel?.delete(id) }
        titleLabel.stringValue = snippet.title
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        previewLabel.stringValue = snippet.preview.isEmpty ? "\(snippet.text.count) " + Lp(snippet.text.count, "character", "characters") : snippet.preview
        previewLabel.font = .systemFont(ofSize: 11)
        previewLabel.textColor = .secondaryLabelColor
        previewLabel.lineBreakMode = .byTruncatingTail
        toolTip = String(snippet.text.prefix(400))
        [check, titleLabel, previewLabel, del].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let W = bounds.width
        del.frame = NSRect(x: W - 38, y: 10, width: 30, height: 30)
        titleLabel.frame = NSRect(x: 40, y: 8, width: W - 84, height: 17)
        previewLabel.frame = NSRect(x: 40, y: 26, width: W - 84, height: 15)
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
        if hovering {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 9, yRadius: 9).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        downEvent = event
        dragging = false
        if event.clickCount == 2 { shelfView.beginEditing(snippet, in: self) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent, !dragging else { return }
        let a = down.locationInWindow, b = event.locationInWindow
        guard hypot(b.x - a.x, b.y - a.y) > 3 else { return }
        dragging = true
        let pi = NSPasteboardItem()
        pi.setString(snippet.text, forType: .string)
        pi.setString(snippet.id.uuidString, forType: .kadrSnippet)
        let di = NSDraggingItem(pasteboardWriter: pi)
        di.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [di], event: down, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { downEvent = nil }
        guard !dragging, event.clickCount == 1 else { return }
        panel.copy(snippet)
        flashCopied()
    }

    private func flashCopied() {
        let old = previewLabel.stringValue
        previewLabel.stringValue = L("Copied")
        previewLabel.textColor = .controlAccentColor
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            self?.previewLabel.stringValue = old
            self?.previewLabel.textColor = .secondaryLabelColor
        }
    }

    private func snapshot() -> NSImage {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return NSImage() }
        cacheDisplay(in: bounds, to: rep)
        let img = NSImage(size: bounds.size)
        img.addRepresentation(rep)
        return img
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : .copy
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        let sn = snippet
        let items: [(String, String, () -> Void)] = [
            (L("Copy"), "doc.on.doc", { [weak self] in self?.panel.copy(sn) }),
            (L("Edit Snippet"), "pencil", { [weak self] in if let self { self.shelfView.beginEditing(sn, in: self) } }),
            (sn.selected ? L("Deselect") : L("Select Snippet"), sn.selected ? "circle" : "checkmark.circle", { [weak self] in self?.panel.setSelected(sn.id, !sn.selected) }),
            (L("Delete"), "trash", { [weak self] in self?.panel.delete(sn.id) }),
        ]
        for (t, s, a) in items {
            let it = ClosureMenuItem(title: t, handler: a)
            it.image = NSImage(systemSymbolName: s, accessibilityDescription: nil)
            m.addItem(it)
        }
        return m
    }
}
