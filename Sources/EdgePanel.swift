import AppKit

/// Следит, не упёрся ли курсор во внешний край экрана, и выдвигает панель истории.
/// Главное — не выезжать самой: нужен именно упор с задержкой, без кнопок мыши,
/// без прокрутки, не на стыке с другим монитором, не в углах и не поверх полноэкранной программы.
final class EdgeTrigger {
    static let shared = EdgeTrigger()

    private var timer: Timer?
    private var dwellStart: CFTimeInterval?
    private var dwellY: CGFloat = 0
    /// После открытия, прокрутки или нажатия кнопки у края — ждём, пока курсор уйдёт от края.
    private var armed = false
    private var lastScroll: CFTimeInterval = 0
    private var scrollMonitor: Any?
    private var buttonMonitor: Any?
    /// Кнопки по событиям (вдобавок к pressedMouseButtons): перетаскивание и отпускание у края — не вызов.
    private var buttonDown = false
    private var buttonDownSeen: CFTimeInterval = 0
    private var lastDragEvent: CFTimeInterval = 0
    private var prefObserver: NSKeyValueObservation?
    private(set) var opens = 0
    private(set) var lastDwellMs = 0

    static let cornerMargin: CGFloat = 40      // углы — системные «активные углы» и переход между мониторами
    static let slideTolerance: CGFloat = 40    // скольжение вдоль края дальше этого — заново отсчитываем

    func start() {
        prefObserver = Prefs.d.observe(\.clipEdge, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.apply() }
        }
        apply()
    }

    private var enabled: Bool?
    private let debug = ProcessInfo.processInfo.environment["KADR_EDGE_DEBUG"] == "1"
    private var lastDebug: CFTimeInterval = 0

    func apply() {
        // KVO на UserDefaults приходит при любой внешней записи — действуем только при смене значения.
        let want = Prefs.clipEdge
        guard want != enabled else { return }
        enabled = want
        KadrLog.write("панель у края: \(want ? "включена" : "выключена")")
        if want {
            guard timer == nil else { return }
            armed = false
            let t = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in self?.tick() }
            t.tolerance = 0.01
            RunLoop.main.add(t, forMode: .common)
            timer = t
            if buttonMonitor == nil {
                buttonMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                                                             .rightMouseDown, .rightMouseUp, .rightMouseDragged, .otherMouseDragged]) { [weak self] e in
                    guard let self else { return }
                    let now = CACurrentMediaTime()
                    switch e.type {
                    case .leftMouseDown, .rightMouseDown: self.buttonDown = true; self.buttonDownSeen = now
                    case .leftMouseUp, .rightMouseUp: self.buttonDown = false; self.lastDragEvent = now
                    default: self.lastDragEvent = now
                    }
                }
            }
            if scrollMonitor == nil {
                scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
                    self?.lastScroll = CACurrentMediaTime()
                }
            }
        } else {
            timer?.invalidate(); timer = nil
            if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
            if let m = buttonMonitor { NSEvent.removeMonitor(m); buttonMonitor = nil }
            dwellStart = nil
            if ClipHistoryPanel.edgeIfCreated?.isVisible == true { ClipHistoryPanel.edge.hide() }
        }
    }

    /// Панель спряталась: снова сработаем только после ухода курсора от края.
    func panelHidden() { armed = false; dwellStart = nil }

    private func tick() {
        if ClipHistoryPanel.edgeIfCreated?.isVisible == true { dwellStart = nil; armed = false; return }
        let p = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) else { dwellStart = nil; return }
        let right = Prefs.clipEdgeSide != "left"
        let fr = screen.frame
        let atEdge = right ? p.x >= fr.maxX - 1 : p.x < fr.minX + 1
        guard atEdge else {
            dwellStart = nil
            if right ? p.x < fr.maxX - 12 : p.x > fr.minX + 12 { armed = true }
            return
        }
        let now = CACurrentMediaTime()
        if debug, dwellStart == nil, now - lastDebug > 0.5 {
            lastDebug = now
            KadrLog.write("панель у края [отладка]: у края, armed=\(armed) кнопки=\(NSEvent.pressedMouseButtons)/\(buttonDown) драг=\(Int((now - lastDragEvent) * 1000)) прокрутка=\(Int((now - lastScroll) * 1000)) внешний=\(EdgeTrigger.isOuterEdge(screen: screen, point: p, right: right)) x=\(p.x) y=\(p.y)")
        }
        guard armed else { return }
        // Перетаскивание (полка) или прокрутка у края — это не вызов панели.
        // Зависшее «нажато» (отпустили над окном Kadr) сбрасываем через 3 с.
        if buttonDown, NSEvent.pressedMouseButtons == 0, now - buttonDownSeen > 3 { buttonDown = false }
        if NSEvent.pressedMouseButtons != 0 || buttonDown || now - lastDragEvent < 0.4 || now - lastScroll < 0.5 {
            dwellStart = nil; armed = false; return
        }
        guard EdgeTrigger.isOuterEdge(screen: screen, point: p, right: right) else { dwellStart = nil; return }
        guard let start = dwellStart, abs(p.y - dwellY) <= EdgeTrigger.slideTolerance else {
            dwellStart = now; dwellY = p.y; return
        }
        guard now - start >= Prefs.clipEdgeDelay else { return }
        dwellStart = nil
        armed = false
        if let why = blockReason(screen) { KadrLog.write("панель у края: не открыта — \(why)"); return }
        opens += 1
        lastDwellMs = Int((now - start) * 1000)
        KadrLog.write("панель у края: открываю, упор \(lastDwellMs) мс")
        ClipHistoryPanel.edge.showAtEdge(screen: screen, right: right)
    }

    /// Край внешний: за ним нет другого монитора, курсор не в углу.
    static func isOuterEdge(screen: NSScreen, point p: NSPoint, right: Bool) -> Bool {
        let fr = screen.frame
        guard p.y > fr.minY + cornerMargin, p.y < fr.maxY - cornerMargin else { return false }
        let beyond = NSPoint(x: right ? fr.maxX + 2 : fr.minX - 2, y: p.y)
        // Другой монитор рядом по этой высоте (с запасом на углы) — это стык, не край.
        for s in NSScreen.screens where s != screen {
            let f = s.frame.insetBy(dx: -2, dy: -cornerMargin)
            if f.contains(beyond) { return false }
        }
        return true
    }

    private func blockReason(_ screen: NSScreen) -> String? {
        if !Prefs.clipEdge { return "выключено" }
        if SequentialPaster.busy { return "идёт вставка" }
        if CaptureService.shared.busy { return "идёт снимок" }
        if ClipHistoryPanel.shared.isVisible { return "открыто окно истории" }
        if EdgeTrigger.frontmostIsFullscreen(on: screen) { return "полноэкранная программа" }
        return nil
    }

    /// Окно текущей программы занимает весь экран (полноэкранный режим, видео, игры).
    static func frontmostIsFullscreen(on screen: NSScreen) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return false }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        let mainH = NSScreen.screens.first?.frame.height ?? 0
        let f = screen.frame
        let cg = CGRect(x: f.minX, y: mainH - f.maxY, width: f.width, height: f.height)
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bd) else { continue }
            if abs(r.minX - cg.minX) < 1, abs(r.minY - cg.minY) < 1, r.width >= cg.width - 1, r.height >= cg.height - 1 { return true }
        }
        return false
    }
}
