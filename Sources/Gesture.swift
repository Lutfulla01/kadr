import AppKit
import Carbon.HIToolbox

// MARK: - Касания тачпада (закрытый MultitouchSupport.framework, как в MiddleClick / Jitouch)

private typealias MTDeviceRef = UnsafeMutableRawPointer
private typealias MTContactCallback = @convention(c) (MTDeviceRef?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
private typealias FnCreateList = @convention(c) () -> Unmanaged<CFArray>?
private typealias FnRegister = @convention(c) (MTDeviceRef?, MTContactCallback?) -> Void
private typealias FnStart = @convention(c) (MTDeviceRef?, Int32) -> Void
private typealias FnStop = @convention(c) (MTDeviceRef?) -> Void

/// Чистая логика: кадр касаний → число пальцев, нажатие → решение. Проверяется на поддельных кадрах (--gesture-test).
enum GestureLogic {
    /// Размер структуры касания MultitouchSupport и смещение поля state.
    static let touchStride = 96
    static let stateOffset = 20
    /// 3 — палец опускается, 4 — касается.
    static let touchingStates: ClosedRange<Int32> = 3...4
    /// Кадр старше этого — пальцев уже нет (при касании кадры идут ~100 раз в секунду).
    static let maxFrameAge = 0.25

    /// Сколько пальцев касаются. Если поле state выглядит мусором (другая раскладка структуры) — берём n.
    static func touching(_ touches: UnsafeRawPointer?, count n: Int) -> (fingers: Int, layoutOK: Bool) {
        guard let touches, n > 0 else { return (0, true) }
        var c = 0
        for i in 0..<n {
            let st = touches.load(fromByteOffset: i * touchStride + stateOffset, as: Int32.self)
            if !(0...7).contains(st) { return (n, false) }
            if touchingStates.contains(st) { c += 1 }
        }
        return (c, true)
    }

    /// Нажатие тачпада переключает панель, если в этот момент касаются ровно 3 пальца.
    static func shouldToggle(fingers: Int, frameAge: Double) -> Bool {
        frameAge <= maxFrameAge && fingers == 3
    }
}

/// Последние кадры по устройствам (обновляются из потока MultitouchSupport).
private final class TouchState {
    static let shared = TouchState()
    private let lock = NSLock()
    private var byDevice: [UInt: (fingers: Int, raw: Int, at: CFTimeInterval)] = [:]
    private(set) var layoutWarned = false

    func update(_ dev: MTDeviceRef?, _ touches: UnsafeMutableRawPointer?, _ n: Int32) {
        let r = GestureLogic.touching(UnsafeRawPointer(touches), count: Int(n))
        let key = UInt(bitPattern: dev)
        lock.lock()
        byDevice[key] = (r.fingers, Int(n), CACurrentMediaTime())
        let warn = !r.layoutOK && !layoutWarned
        if warn { layoutWarned = true }
        lock.unlock()
        if warn { DispatchQueue.main.async { KadrLog.write("жест: незнакомая раскладка кадров тачпада — считаю все контакты") } }
    }

    /// Пальцы на самом «занятом» устройстве со свежим кадром.
    func current() -> (fingers: Int, raw: Int, age: Double) {
        let now = CACurrentMediaTime()
        lock.lock(); defer { lock.unlock() }
        var best = (fingers: 0, raw: 0, age: 99.0)
        for (_, v) in byDevice where now - v.at <= GestureLogic.maxFrameAge && v.fingers >= best.fingers {
            best = (v.fingers, v.raw, now - v.at)
        }
        return best
    }

    func reset() { lock.lock(); byDevice = [:]; lock.unlock() }
}

private let contactCallback: MTContactCallback = { dev, touches, n, _, _ in
    TouchState.shared.update(dev, touches, n)
    return 0
}

// MARK: - Жест «нажатие тремя пальцами»

/// Физическое нажатие тачпада тремя пальцами открывает и прячет панель истории.
/// Нажатие перехватывается (CGEventTap), чтобы под курсором ничего не щёлкнуло.
final class GestureTrigger {
    static let shared = GestureTrigger()

    private var handle: UnsafeMutableRawPointer?
    private var fnCreate: FnCreateList?, fnRegister: FnRegister?, fnUnregister: FnRegister?, fnStart: FnStart?, fnStop: FnStop?
    private var devices: CFArray?
    private(set) var deviceCount = 0
    private(set) var available = false     // MultitouchSupport загружен
    private var tap: CFMachPort?            // под lock: читается и с потока перехвата
    private var tapSource: CFRunLoopSource?
    private var tapLoop: CFRunLoop?
    private var swallowing = false          // только поток перехвата
    private let lock = NSLock()
    private var on = false                  // под lock: копия enabled для потока перехвата
    private var watchTimer: Timer?
    private var wakeObserver: Any?
    private var prefObserver: NSKeyValueObservation?
    private var enabled: Bool?
    private var togglesStore = 0
    var toggles: Int { lock.lock(); defer { lock.unlock() }; return togglesStore }

    var tapActive: Bool { currentTap().map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    /// Строка для настроек, если жест не работает (nil — всё в порядке или выключен).
    var problem: String? {
        guard Prefs.clipGesture else { return nil }
        if !available { return L("The gesture isn't available on this Mac (no MultitouchSupport). ⌥⇧V still works.") }
        if tap == nil { return L("The gesture needs Accessibility access for Kadr. Until then, use ⌥⇧V.") }
        if deviceCount == 0 { return L("No trackpad found. The gesture will work once one is connected.") }
        return nil
    }

    func start() {
        loadFramework()
        prefObserver = Prefs.d.observe(\.clipGesture, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.apply() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.enabled == true else { return }
            KadrLog.write("жест: после сна — переподключаю тачпады")
            self.restartDevices()
            self.ensureTap()
        }
        apply()
    }

    func apply() {
        let want = Prefs.clipGesture
        guard want != enabled else { return }
        enabled = want
        lock.lock(); on = want; lock.unlock()
        if want {
            restartDevices()
            ensureTap()
            watchTimer?.invalidate()
            // Подключили/отключили Magic Trackpad, отобрали доступ, система выключила перехват — чиним раз в 3 с.
            let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.watch() }
            t.tolerance = 1
            RunLoop.main.add(t, forMode: .common)
            watchTimer = t
            KadrLog.write("жест: включён — устройств \(deviceCount), перехват \(tap != nil ? "есть" : "нет доступа"), MultitouchSupport \(available ? "есть" : "нет")")
        } else {
            watchTimer?.invalidate(); watchTimer = nil
            stopDevices()
            removeTap()
            KadrLog.write("жест: выключен")
        }
    }

    // MARK: Устройства

    private func loadFramework() {
        guard handle == nil else { return }
        guard let h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY) else {
            KadrLog.write("жест: MultitouchSupport не загрузился — жест выключен, ⌥⇧V работает"); return
        }
        func sym<T>(_ name: String, _: T.Type) -> T? { dlsym(h, name).map { unsafeBitCast($0, to: T.self) } }
        fnCreate = sym("MTDeviceCreateList", FnCreateList.self)
        fnRegister = sym("MTRegisterContactFrameCallback", FnRegister.self)
        fnUnregister = sym("MTUnregisterContactFrameCallback", FnRegister.self)
        fnStart = sym("MTDeviceStart", FnStart.self)
        fnStop = sym("MTDeviceStop", FnStop.self)
        handle = h
        available = fnCreate != nil && fnRegister != nil && fnStart != nil
        if !available { KadrLog.write("жест: в MultitouchSupport нет нужных функций — жест выключен") }
    }

    private func listCount() -> Int {
        guard let fnCreate, let arr = fnCreate()?.takeRetainedValue() else { return 0 }
        return CFArrayGetCount(arr)
    }

    private func restartDevices() {
        stopDevices()
        guard available, let fnCreate, let fnRegister, let fnStart, let arr = fnCreate()?.takeRetainedValue() else { deviceCount = 0; return }
        let n = CFArrayGetCount(arr)
        for i in 0..<n {
            let dev = UnsafeMutableRawPointer(mutating: CFArrayGetValueAtIndex(arr, i))
            fnRegister(dev, contactCallback)
            fnStart(dev, 0)
        }
        devices = arr
        deviceCount = n
    }

    private func stopDevices() {
        if let arr = devices {
            for i in 0..<CFArrayGetCount(arr) {
                let dev = UnsafeMutableRawPointer(mutating: CFArrayGetValueAtIndex(arr, i))
                fnUnregister?(dev, contactCallback)
                fnStop?(dev)
            }
        }
        devices = nil
        deviceCount = 0
        TouchState.shared.reset()
    }

    private func watch() {
        guard enabled == true else { return }
        if available {
            let n = listCount()
            if n != deviceCount {
                KadrLog.write("жест: тачпадов было \(deviceCount), стало \(n) — переподключаю")
                restartDevices()
            }
        }
        ensureTap()
    }

    // MARK: Перехват нажатий

    /// Перехват живёт на своём потоке со своим run loop: на главном он ломал щелчки по окнам самого Kadr
    /// (mouseDown до панели не доходил). Колбэк только читает TouchState и решает; панель — на главном.
    private func ensureTap() {
        if let tap {
            if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true); KadrLog.write("жест: перехват был выключен системой — включил") }
            return
        }
        guard available else { return }
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue) | (1 << CGEventType.leftMouseDragged.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: CGEventMask(mask), callback: { _, type, event, _ in
            GestureTrigger.shared.handle(type, event)
        }, userInfo: nil) else { return }   // нет «Универсального доступа» — попробуем позже (watch)
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        let ready = DispatchSemaphore(value: 0)
        var loop: CFRunLoop?
        let th = Thread {
            loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, src, .commonModes)
            CGEvent.tapEnable(tap: t, enable: true)
            ready.signal()
            CFRunLoopRun()      // до CFRunLoopStop в removeTap
        }
        th.name = "kadr.gesture-tap"
        th.qualityOfService = .userInteractive
        th.start()
        _ = ready.wait(timeout: .now() + 2)
        lock.lock(); tap = t; lock.unlock()
        tapSource = src; tapLoop = loop
        KadrLog.write("жест: перехват нажатий включён (свой поток)")
    }

    private func removeTap() {
        lock.lock(); let t = tap; tap = nil; lock.unlock()
        if let t { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        if let tapLoop, let tapSource { CFRunLoopRemoveSource(tapLoop, tapSource, .commonModes); CFRunLoopStop(tapLoop) }
        tapSource = nil; tapLoop = nil
    }

    private func currentTap() -> CFMachPort? { lock.lock(); defer { lock.unlock() }; return tap }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let t = currentTap() { CGEvent.tapEnable(tap: t, enable: true) }
            DispatchQueue.main.async { KadrLog.write("жест: система выключила перехват (\(type == .tapDisabledByTimeout ? "таймаут" : "ввод")) — включил снова") }
            return Unmanaged.passUnretained(event)
        case .leftMouseDown:
            swallowing = false
            let t = TouchState.shared.current()
            // Обычный щелчок одним пальцем (или мышью) не трогаем и не пишем в журнал.
            guard t.fingers >= 2 || t.raw >= 3 else { return Unmanaged.passUnretained(event) }
            let pressure = event.getDoubleValueField(.mouseEventPressure)
            if press(fingers: t.fingers, raw: t.raw, age: t.age, pressure: pressure, source: "тачпад") {
                swallowing = true
                return nil
            }
            return Unmanaged.passUnretained(event)
        case .leftMouseDragged:
            return swallowing ? nil : Unmanaged.passUnretained(event)
        case .leftMouseUp:
            if swallowing { swallowing = false; return nil }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// Общий путь для настоящего жеста и проверки (--gesture-sim): решение, переключение, журнал.
    /// Возвращает true, если нажатие надо проглотить.
    @discardableResult
    func press(fingers: Int, raw: Int, age: Double, pressure: Double, source: String) -> Bool {
        lock.lock()
        let on = self.on
        let toggle = on && GestureLogic.shouldToggle(fingers: fingers, frameAge: age)
        if toggle { togglesStore += 1 }
        lock.unlock()
        if toggle {
            DispatchQueue.main.async {
                KadrLog.write(String(format: "жест (%@): пальцев %d (контактов %d), нажим %.2f, кадр %.0f мс назад, проглочено да",
                                     source, fingers, raw, pressure, age * 1000))
                GestureTrigger.shared.act()
            }
        } else {
            DispatchQueue.main.async {
                KadrLog.write(String(format: "жест (%@): пальцев %d (контактов %d), нажим %.2f, кадр %.0f мс назад, проглочено нет → %@",
                                     source, fingers, raw, pressure, age * 1000, on ? "не 3 пальца" : "жест выключен"))
            }
        }
        return toggle
    }

    // MARK: Что делает нажатие (главный поток)

    private(set) var copies = 0
    private(set) var lastDecision = ""
    private var checking = false        // идёт ⌘C-проверка — следующее нажатие подождёт

    /// Порядок: панель видна → спрятать; в программе выделен текст → копировать; иначе → открыть панель.
    func act() {
        if let p = ClipHistoryPanel.edgeIfCreated, p.isVisible {
            p.hide(returnFocus: false); decide("панель скрыта"); return
        }
        if checking { KadrLog.write("жест: пропущено — ещё жду ⌘C"); return }
        if SequentialPaster.busy { KadrLog.write("жест: пропущено — идёт вставка"); return }
        guard Prefs.clipGestureCopy, let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != getpid() else { openPanel(""); return }
        let name = app.localizedName ?? app.bundleIdentifier ?? "?"
        let t0 = CACurrentMediaTime()
        let sel = SelectionProbe.check(pid: app.processIdentifier)
        let ms = Int((CACurrentMediaTime() - t0) * 1000)
        switch sel {
        case .some:
            KadrLog.write("жест: копирую (AX) — \(name), выделение найдено за \(ms) мс")
            copy(name, via: "AX", fallback: false)
        case .empty:
            openPanel("выделения нет, AX \(ms) мс")
        case .secure:
            openPanel("поле пароля — macOS не даёт копировать")
        case .unknown(let why):
            KadrLog.write("жест: AX не отвечает про выделение (\(why), \(ms) мс) — проверяю ⌘C")
            copy(name, via: "⌘C-проверка", fallback: true)
        }
    }

    private func decide(_ d: String) { lastDecision = d }

    private func openPanel(_ why: String) {
        KadrLog.write("жест: панель" + (why.isEmpty ? "" : " (\(why))"))
        decide(GestureTrigger.showPanel() ? "панель открыта" : "панель не открылась")
    }

    /// ⌘C в программу впереди и ожидание смены буфера. fallback: не сменился → значит, выделения не было → панель.
    private func copy(_ app: String, via: String, fallback: Bool) {
        let pb = NSPasteboard.general
        let before = pb.changeCount
        checking = true
        decide("жду ⌘C (\(via))")
        SequentialPaster.postKey(CGKeyCode(kVK_ANSI_C), flags: .maskCommand)
        let t0 = CACurrentMediaTime()
        let limit = fallback ? 0.25 : 0.6
        func poll() {
            let dt = CACurrentMediaTime() - t0
            if pb.changeCount != before {
                checking = false
                copies += 1
                KadrLog.write(fallback ? "жест: копирую (⌘C-проверка) — \(app), буфер сменился за \(Int(dt * 1000)) мс"
                                       : "жест: скопировано — \(app), \(Int(dt * 1000)) мс")
                decide("скопировано (\(via))")
                HUD.show(L("Copied"), symbol: "doc.on.doc.fill", nearCursor: true)
                return
            }
            if dt >= limit {
                checking = false
                if fallback {
                    openPanel("⌘C ничего не скопировал за \(Int(limit * 1000)) мс")
                } else {
                    KadrLog.write("жест: выделение есть, но буфер не сменился — \(app)")
                    decide("не скопировано")
                    HUD.show(L("Couldn't copy"), symbol: "exclamationmark.triangle.fill", nearCursor: true)
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { poll() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { poll() }
    }

    /// Открыть панель на экране с курсором, на выбранной стороне. Возвращает «открыта».
    static func showPanel() -> Bool {
        if SequentialPaster.busy { return false }
        let m = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }) ?? NSScreen.main else { return false }
        ClipHistoryPanel.edge.showAtEdge(screen: screen, right: Prefs.clipEdgeSide != "left", sticky: true)
        return true
    }
}

/// Есть ли выделение в программе впереди — по доступности (AX), без трогания буфера.
enum SelectionProbe {
    enum Result { case some, empty, secure, unknown(String) }
    private static var manualTried = Set<pid_t>()

    private static func attr(_ e: AXUIElement, _ name: String) -> (CFTypeRef?, AXError) {
        var v: CFTypeRef?
        let r = AXUIElementCopyAttributeValue(e, name as CFString, &v)
        return (v, r)
    }

    private static func focused(_ app: AXUIElement) -> (AXUIElement?, AXError) {
        let (v, r) = attr(app, kAXFocusedUIElementAttribute)
        guard r == .success, let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return (nil, r) }
        return ((v as! AXUIElement), r)
    }

    static func check(pid: pid_t) -> Result {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)   // зависшая программа не держит Kadr
        var (el, err) = focused(app)
        if el == nil, !manualTried.contains(pid) {
            manualTried.insert(pid)
            // Electron строит дерево доступности только по просьбе (дёшево, один раз на процесс).
            if AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success {
                (el, err) = focused(app)
            }
        }
        guard let e = el else { return .unknown("нет фокуса, \(err.rawValue)") }
        AXUIElementSetMessagingTimeout(e, 0.25)
        let role = attr(e, kAXRoleAttribute).0 as? String ?? "?"
        let subrole = attr(e, kAXSubroleAttribute).0 as? String ?? ""
        if subrole == "AXSecureTextField" || role == "AXSecureTextField" { return .secure }
        let (sv, r1) = attr(e, kAXSelectedTextAttribute)
        if r1 == .success, let s = sv as? String { return s.isEmpty ? .empty : .some }
        let (rv, r2) = attr(e, kAXSelectedTextRangeAttribute)
        if r2 == .success, let rv, CFGetTypeID(rv) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(rv as! AXValue, .cfRange, &range) { return range.length > 0 ? .some : .empty }
        }
        return .unknown("\(role): выделение \(r1.rawValue)/\(r2.rawValue)")
    }
}

// MARK: - Проверка логики на поддельных кадрах

enum GestureSelfTest {
    static func run() -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print("\(cond ? "OK " : "НЕТ") \(name)"); if !cond { ok = false } }
        func frame(_ states: [Int32]) -> (Int, Bool) {
            let buf = UnsafeMutableRawPointer.allocate(byteCount: max(1, states.count) * GestureLogic.touchStride, alignment: 8)
            defer { buf.deallocate() }
            memset(buf, 0, max(1, states.count) * GestureLogic.touchStride)
            for (i, s) in states.enumerated() { buf.storeBytes(of: s, toByteOffset: i * GestureLogic.touchStride + GestureLogic.stateOffset, as: Int32.self) }
            let r = GestureLogic.touching(buf, count: states.count)
            return (r.fingers, r.layoutOK)
        }
        check("3 пальца касаются → 3", frame([4, 4, 4]) == (3, true))
        check("3 касаются + 1 отрывается → 3", frame([4, 4, 4, 5]) == (3, true))
        check("2 касаются + 1 опускается → 3", frame([4, 4, 3]) == (3, true))
        check("4 пальца → 4", frame([4, 4, 4, 4]) == (4, true))
        check("ладонь рядом (вне касания) не считается", frame([4, 4, 1, 7]) == (2, true))
        check("пустой кадр → 0", frame([]) == (0, true))
        check("мусор в state → считаем все контакты", frame([4, 99, 4]) == (3, false))
        check("3 пальца, свежий кадр → переключить", GestureLogic.shouldToggle(fingers: 3, frameAge: 0.01))
        check("2 пальца → нет", !GestureLogic.shouldToggle(fingers: 2, frameAge: 0.01))
        check("4 пальца → нет", !GestureLogic.shouldToggle(fingers: 4, frameAge: 0.01))
        check("1 палец/мышь → нет", !GestureLogic.shouldToggle(fingers: 1, frameAge: 0.01))
        check("3 пальца, но кадр старый (пальцы уже убраны) → нет", !GestureLogic.shouldToggle(fingers: 3, frameAge: 0.5))
        check("нет кадров (мышь, тачпад не трогали) → нет", !GestureLogic.shouldToggle(fingers: 0, frameAge: 99))
        return ok
    }
}
