// Kadr — значок в строке меню, меню, сценарии снимков.
import AppKit
import ServiceManagement

enum AppActions {
    /// Распознанный текст → буфер обмена + короткая подсказка.
    static func deliverOCR(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty {
            HUD.show("Текст не найден", symbol: "text.magnifyingglass")
            return
        }
        ImageFiles.copyText(t)
        if Prefs.showHUD { HUD.show("Текст скопирован", symbol: "doc.on.clipboard") }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let editOnly: URL?
    let shelfTest: (files: [URL], expand: Bool, actions: Bool)?
    private var permissionAlertShown = false

    init(editOnly: URL?, shelfTest: (files: [URL], expand: Bool, actions: Bool)? = nil) {
        self.editOnly = editOnly
        self.shelfTest = shelfTest
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Только тестовый профиль: снимки интерфейса в светлой/тёмной теме без смены системной настройки.
        if Profile.name != nil, let a = ProcessInfo.processInfo.environment["KADR_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: a == "light" ? .aqua : .darkAqua)
        }
        Prefs.registerDefaults()
        Prefs.d.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        // Однократно: встряхивание без перетаскивания выключено по умолчанию (могло включиться тестовой сборкой).
        if !Prefs.d.bool(forKey: "migratedIdleShakeOff1") {
            Prefs.d.set(false, forKey: "idleShakeEnabled")
            Prefs.d.set(true, forKey: "migratedIdleShakeOff1")
        }
        installMainMenu()
        if let url = editOnly {
            // Тестовый режим: только редактор, без значка и горячих клавиш.
            EditorController.onAllClosed = { NSApp.terminate(nil) }
            if EditorController.show(url: url) == nil { NSApp.terminate(nil) }
            return
        }
        if CommandLine.arguments.contains("--text-shelf") {
            TextShelfPanel.shared.show(at: nil)
            if CommandLine.arguments.contains("--pinned") { TextShelfPanel.shared.pinned = true }
            return
        }
        if let t = shelfTest {
            // Тестовый режим: только полка с файлами, по центру экрана.
            ShelfPanel.onAllClosed = { NSApp.terminate(nil) }
            let vis = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let p = ShelfPanel.open(items: t.files.map { ShelfItem(file: $0, temp: false) },
                                    center: NSPoint(x: vis.midX, y: vis.midY))
            if t.expand { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { p.setExpanded(true) } }
            if t.actions { p.forceActionBar() }
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // У профиля своё имя для состояния значка — не делит его с настоящим Kadr.
        if let p = Profile.name { statusItem.autosaveName = "KadrProfile-\(p)" }
        if let b = statusItem.button {
            let img = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Kadr")
            img?.isTemplate = true
            b.image = img
            b.toolTip = Profile.name.map { "Kadr — профиль \($0)" } ?? "Kadr — снимки экрана"
            b.setAccessibilityIdentifier("kadr.statusItem")
        }
        applyStatusItemVisibility()
        statusObserver = Prefs.d.observe(\.showStatusItem, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self, Prefs.showStatusItem != self.lastShowStatusItem else { return }
                self.applyStatusItemVisibility()
            }
        }
        // Повторный запуск того же профиля (или настоящего Kadr из терминала) открывает настройки здесь.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("uz.lutfulla.kadr.reopen"),
                                                            object: Profile.name ?? "main", queue: .main) { [weak self] _ in
            self?.openSettings()
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        HotkeyCenter.shared.onAction = { [weak self] a in self?.perform(a) }
        HotkeyCenter.shared.reload()

        ShelfStore.cleanup()
        ShakeMonitor.shared.onShake = { p in
            guard ShelfPanel.panel(at: p) == nil, !NSMouseInRect(p, TextShelfPanel.shared.frame, false) || !TextShelfPanel.shared.isVisible else { return }
            // Только текст (без файлов, картинок, ссылок) — открываем текстовую полку.
            let types = Set(NSPasteboard(name: .drag).types ?? [])
            let rich: Set<NSPasteboard.PasteboardType> = [.fileURL, .URL, .png, .tiff, NSPasteboard.PasteboardType("public.jpeg")]
            let promises = Set(NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
            if types.contains(.string) && types.isDisjoint(with: rich) && types.isDisjoint(with: promises) {
                TextShelfPanel.shared.show(at: p)
            } else {
                ShelfPanel.open(center: p).openedByShake = true
            }
        }
        ShakeMonitor.shared.onIdleShake = { p in TextShelfPanel.shared.toggle(at: p) }
        ShakeMonitor.shared.onDragEnded = {
            // Полка от встряхивания, в которую ничего не бросили, убирается сама.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                for s in ShelfPanel.all where s.openedByShake && s.items.isEmpty { s.close() }
            }
        }
        ShakeMonitor.shared.start()
        ClipMonitor.shared.start()
        EdgeTrigger.shared.start()
        GestureTrigger.shared.start()
        // Проверка жеста без тачпада — только у тестового профиля: тот же путь решения и переключения.
        if let prof = Profile.name {
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name("uz.lutfulla.kadr.gesture-sim"), object: nil, queue: .main) { n in
                guard let o = n.object as? String, o.hasPrefix(prof + ":"), let f = Int(o.dropFirst(prof.count + 1)) else { return }
                GestureTrigger.shared.press(fingers: f, raw: f, age: 0.01, pressure: 1, source: "проверка")
            }
        }
        // kill / выход из системы: дописать отложенный индекс истории.
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { ClipStore.shared.flush(); ClipStore.clearViewDir(); exit(0) }
        term.resume()
        termSource = term
        RuntimeState.start()
        OCR.warmUp()

        // Тестовый профиль не трогает автозапуск настоящего Kadr.
        if Profile.name == nil && !Prefs.d.bool(forKey: "loginItemInitialized") {
            Prefs.d.set(true, forKey: "loginItemInitialized")
            try? SMAppService.mainApp.register()
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private var lastShowStatusItem: Bool?
    private var statusObserver: NSKeyValueObservation?
    private var termSource: DispatchSourceSignal?

    /// «Показывать значок в строке меню» (по умолчанию да). KADR_HIDE_STATUS_ITEM=1 прячет значок профиля для фоновых проверок.
    func applyStatusItemVisibility() {
        guard let item = statusItem else { return }
        lastShowStatusItem = Prefs.showStatusItem
        let hideForTests = Profile.name != nil && ProcessInfo.processInfo.environment["KADR_HIDE_STATUS_ITEM"] == "1"
        item.isVisible = Prefs.showStatusItem && !hideForTests
        KadrLog.write("значок в строке меню: \(item.isVisible ? "показан" : "скрыт")")
    }

    func applicationWillTerminate(_ notification: Notification) {
        ClipStore.shared.flush()
        ClipStore.clearViewDir()
        RuntimeState.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if editOnly == nil { openSettings() }
        return false
    }

    /// Невидимое главное меню нужно, чтобы в поле текста работали ⌘C/⌘V/⌘Z.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Выйти из Kadr", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Правка")
        edit.addItem(withTitle: "Отменить", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Повторить", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Выбрать все", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    // MARK: Меню

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for a in HotkeyAction.captureCases {
            let it = item(a.title, symbol: a.symbol, action: #selector(menuCapture(_:)))
            it.representedObject = a.rawValue
            if let spec = Prefs.hotkey(a), !spec.menuKeyEquivalent.isEmpty {
                it.keyEquivalent = spec.menuKeyEquivalent
                it.keyEquivalentModifierMask = spec.modifiers
            }
            menu.addItem(it)
        }
        menu.addItem(item("Запись экрана", symbol: "record.circle", action: #selector(openRecording)))
        menu.addItem(.separator())
        let shelf = item(HotkeyAction.shelf.title, symbol: HotkeyAction.shelf.symbol, action: #selector(newShelf))
        if let spec = Prefs.hotkey(.shelf), !spec.menuKeyEquivalent.isEmpty {
            shelf.keyEquivalent = spec.menuKeyEquivalent
            shelf.keyEquivalentModifierMask = spec.modifiers
        }
        menu.addItem(shelf)
        let textShelf = item(HotkeyAction.textShelf.title, symbol: HotkeyAction.textShelf.symbol, action: #selector(toggleTextShelf))
        if let spec = Prefs.hotkey(.textShelf), !spec.menuKeyEquivalent.isEmpty {
            textShelf.keyEquivalent = spec.menuKeyEquivalent
            textShelf.keyEquivalentModifierMask = spec.modifiers
        }
        menu.addItem(textShelf)
        menu.addItem(item("Текст с экрана на текстовую полку", symbol: "text.viewfinder", action: #selector(ocrToTextShelf)))
        menu.addItem(.separator())
        let clip = item(HotkeyAction.clipboard.title, symbol: HotkeyAction.clipboard.symbol, action: #selector(toggleClipHistory))
        if let spec = Prefs.hotkey(.clipboard), !spec.menuKeyEquivalent.isEmpty {
            clip.keyEquivalent = spec.menuKeyEquivalent
            clip.keyEquivalentModifierMask = spec.modifiers
        }
        menu.addItem(clip)
        let pause = item("Пауза записи", symbol: "pause.circle", action: #selector(toggleClipPause))
        pause.state = ClipMonitor.shared.paused ? .on : .off
        menu.addItem(pause)
        menu.addItem(.separator())

        let histItem = item("История", symbol: "clock.arrow.circlepath", action: nil)
        let hist = NSMenu()
        hist.autoenablesItems = false
        let files = Prefs.history.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if files.isEmpty {
            let empty = NSMenuItem(title: "Пока пусто", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            hist.addItem(empty)
        } else {
            for url in files {
                let name = url.deletingPathExtension().lastPathComponent
                let title = name.hasPrefix("Kadr ") ? String(name.dropFirst(5)) : name
                let it = NSMenuItem(title: title, action: #selector(openHistory(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = url
                it.image = ImageFiles.thumbnail(url, maxPixel: 64)
                hist.addItem(it)
            }
            hist.addItem(.separator())
            hist.addItem(item("Очистить историю", symbol: "trash", action: #selector(clearHistory)))
        }
        histItem.submenu = hist
        menu.addItem(histItem)
        menu.addItem(item("Открыть папку", symbol: "folder", action: #selector(openFolder)))
        menu.addItem(.separator())
        let settings = item("Настройки…", symbol: "gearshape", action: #selector(openSettings))
        settings.keyEquivalent = ","
        menu.addItem(settings)
        let quit = item("Выйти", symbol: "power", action: #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func item(_ title: String, symbol: String, action: Selector?) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        it.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return it
    }

    @objc private func menuCapture(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let a = HotkeyAction(rawValue: raw) else { return }
        // Дать меню закрыться, чтобы оно не попало в снимок.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.perform(a) }
    }

    @objc private func openRecording() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.screenshot.launcher") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    @objc private func openHistory(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        EditorController.show(url: url)
    }

    @objc private func clearHistory() { Prefs.history = [] }

    @objc private func newShelf() { ShelfPanel.open() }

    @objc private func toggleClipHistory() {
        // Дать меню закрыться, затем открыть у курсора.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { ClipHistoryPanel.shared.toggle() }
    }

    @objc private func toggleClipPause() { ClipMonitor.shared.paused.toggle() }

    @objc private func toggleTextShelf() {
        let p = NSEvent.mouseLocation
        // Из меню курсор у верхнего края — показываем ниже, по центру экрана.
        let vis = NSScreen.main?.visibleFrame ?? .zero
        TextShelfPanel.shared.isVisible ? TextShelfPanel.shared.hide() : TextShelfPanel.shared.show(at: NSPoint(x: p.x, y: min(p.y, vis.maxY - 40)))
    }

    @objc private func ocrToTextShelf() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.capture(.area, ocr: true, toTextShelf: true) }
    }

    @objc private func openFolder() {
        let f = Prefs.saveFolder
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        NSWorkspace.shared.open(f)
    }

    @objc func openSettings() {
        SettingsWindowController.show(onHotkeysChanged: {})
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Снимки

    func perform(_ a: HotkeyAction) {
        switch a {
        case .area: capture(.area, ocr: false)
        case .window: capture(.window, ocr: false)
        case .screen: capture(.screen, ocr: false)
        case .ocr: capture(.area, ocr: true)
        case .shelf: ShelfPanel.open()
        case .textShelf: TextShelfPanel.shared.toggle(at: NSEvent.mouseLocation)
        case .clipboard: ClipHistoryPanel.shared.toggle()
        }
    }

    private func capture(_ mode: CaptureMode, ocr: Bool, toTextShelf: Bool = false) {
        guard ensurePermission() else { return }
        CaptureService.shared.run(mode) { [weak self] result in
            guard let self else { return }
            switch result {
            case .cancelled:
                return
            case .noPermission:
                self.showPermissionAlert()
            case .ok(let tmp):
                if ocr { self.finishOCR(tmp, toTextShelf: toTextShelf) } else { self.finishCapture(tmp) }
            }
        }
    }

    private func finishOCR(_ tmp: URL, toTextShelf: Bool = false) {
        guard let img = ImageFiles.load(tmp) else {
            KadrLog.write("распознавание: снимок не читается")
            try? FileManager.default.removeItem(at: tmp)
            return
        }
        let rows = Prefs.keepTableRows
        HUD.show("Распознаю…", symbol: "text.viewfinder", sticky: true)
        let t0 = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let text = OCR.recognize(img.cg, keepRows: rows)
            try? FileManager.default.removeItem(at: tmp)
            DispatchQueue.main.async {
                KadrLog.write("распознавание: \(img.cg.width)×\(img.cg.height), \(text.count) симв., \(String(format: "%.2f", Date().timeIntervalSince(t0))) с")
                HUD.hide()
                AppActions.deliverOCR(text)
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if toTextShelf && !t.isEmpty {
                    TextShelfPanel.shared.add([t])
                    if !TextShelfPanel.shared.isVisible { TextShelfPanel.shared.show(at: NSEvent.mouseLocation) }
                }
            }
        }
    }

    private func finishCapture(_ tmp: URL) {
        guard let img = ImageFiles.load(tmp) else { return }
        ImageFiles.copyToClipboard(img.cg, pxPerPt: img.pxPerPt)
        guard let saved = CaptureService.save(temp: tmp) else {
            let a = NSAlert()
            a.messageText = "Не удалось сохранить снимок"
            a.informativeText = "Снимок уже в буфере обмена. Проверьте папку сохранения в настройках: \(Prefs.saveFolder.path)"
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
            return
        }
        Prefs.addToHistory(saved)
        if Prefs.openEditor { EditorController.show(url: saved) }
    }

    /// Нет разрешения «Запись экрана»: в первый раз — системный запрос, потом — одно понятное окно.
    private func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if !Prefs.d.bool(forKey: "askedScreenCapture") {
            Prefs.d.set(true, forKey: "askedScreenCapture")
            if CGRequestScreenCaptureAccess() { return true }
            return false
        }
        showPermissionAlert()
        return false
    }

    private func showPermissionAlert() {
        guard !permissionAlertShown else { return }
        permissionAlertShown = true
        defer { permissionAlertShown = false }
        let a = NSAlert()
        a.alertStyle = .informational
        a.messageText = "Kadr нужно разрешение «Запись экрана»"
        a.informativeText = "Откройте Системные настройки → Конфиденциальность и безопасность → Запись экрана и системного звука, включите Kadr, затем перезапустите Kadr."
        a.addButton(withTitle: "Открыть настройки")
        a.addButton(withTitle: "Не сейчас")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
