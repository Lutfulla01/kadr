import AppKit
import Carbon.HIToolbox

// MARK: - Касания тачпада (закрытый MultitouchSupport.framework, как в MiddleClick / Jitouch)

private typealias MTDeviceRef = UnsafeMutableRawPointer
private typealias MTContactCallback = @convention(c) (MTDeviceRef?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
private typealias FnCreateList = @convention(c) () -> Unmanaged<CFArray>?
private typealias FnRegister = @convention(c) (MTDeviceRef?, MTContactCallback?) -> Void
private typealias FnStart = @convention(c) (MTDeviceRef?, Int32) -> Void
private typealias FnStop = @convention(c) (MTDeviceRef?) -> Void

/// Чистая логика: лента кадров касаний → пальцы у нажатия → решение. Проверяется на поддельной ленте (--gesture-test).
/// Пальцы опускаются не разом (длина разная), поэтому считаем разные контакты за короткое окно вокруг щелчка,
/// а не один последний кадр. Опоздавший третий палец macOS видит как щелчок двумя — правую кнопку.
enum GestureLogic {
    /// Структура касания MultitouchSupport (MTTouch): шаг 96 байт; identifier @16, state @20, size @48.
    static let touchStride = 96
    static let idOffset = 16
    static let stateOffset = 20
    static let sizeOffset = 48
    /// Состояния MT: 0 нет, 1 вошёл в зону, 2 над поверхностью, 3 опускается, 4 касается, 5 отрывается, 6 оторвался, 7 ушёл.
    static let touchStates: ClosedRange<Int32> = 3...5
    /// Ещё у поверхности (2 — мигание лёгкого пальца). 6 — уже оторвался, 7/0 — ушёл: не считаем.
    static let presentStates: ClosedRange<Int32> = 1...5
    /// Кадр старше этого — пальцев уже нет (при касании кадры идут ~100 раз в секунду).
    static let maxFrameAge = 0.25
    /// Третий палец мог коснуться раньше щелчка (и не оторваться)…
    static let before = 0.10
    /// …или позже: при ровно двух пальцах держим нажатие до maxWait, опрашивая каждые pollStep.
    static let maxWait = 0.09
    static let pollStep = 0.004
    /// Контакт ещё есть, если был в кадре не раньше чем за столько до последнего кадра.
    static let presentSlack = 0.025
    /// Большой палец / ладонь: лежит дольше restAge и крупнее остальных в palmRatio раз — не в счёт.
    static let restAge = 0.5
    static let palmRatio: Float = 1.6
    /// 3 пальца; 4 — три и лежащий палец (нажатие четырьмя у macOS ничего не значит). 5 и больше — нет.
    static let toggleRange = 3...4
    static let historyKeep = 0.7
    static let maxFrames = 160

    struct Contact { var id: Int32; var state: Int32; var size: Float }
    struct Frame { var t: Double; var contacts: [Contact]; var layoutOK = true }

    struct Count {
        var fingers = 0         // засчитанные пальцы без большого пальца / ладони
        var counted = 0         // все засчитанные контакты
        var palm = false
        var contacts = 0        // в последнем кадре, любые состояния
        var age = 99.0          // последний кадр, с назад
        var layoutOK = true
        var lastTouch: Double?  // когда коснулся последний из пальцев
        var sizes: [Float] = []
    }

    struct Decision {
        var count = Count()
        var atPress = 0
        var peak = 0
        var waited: Double?     // сколько держали нажатие, ожидая 3-й палец
        var click = 0.0
        var toggle: Bool { count.counted <= toggleRange.upperBound && toggleRange.contains(count.fingers) }
        /// Обычный щелчок одним пальцем или мышью: не трогаем и не пишем в журнал.
        var quiet: Bool { peak < 2 && count.contacts < 3 }
    }

    /// Контакты кадра. Если state или identifier выглядят мусором (другая раскладка структуры) — все n контактов как касания.
    static func contacts(_ touches: UnsafeRawPointer?, count n: Int) -> (contacts: [Contact], layoutOK: Bool) {
        guard let touches, n > 0 else { return ([], true) }
        var out: [Contact] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let base = i * touchStride
            let st = touches.load(fromByteOffset: base + stateOffset, as: Int32.self)
            let id = touches.load(fromByteOffset: base + idOffset, as: Int32.self)
            guard (0...7).contains(st), (0...4095).contains(id), !out.contains(where: { $0.id == id }) else {
                return ((0..<n).map { Contact(id: Int32($0), state: 4, size: 0) }, false)
            }
            let sz = touches.load(fromByteOffset: base + sizeOffset, as: Float.self)
            out.append(Contact(id: id, state: st, size: sz.isFinite && sz > 0 && sz < 100 ? sz : 0))
        }
        return (out, true)
    }

    /// Пальцы нажатия в момент now по ленте одного тачпада: контакт считается, если касался (3…5) в окне
    /// [щелчок − before, now] и ещё есть (был в недавнем кадре, последнее состояние 1…5).
    static func count(_ frames: [Frame], click tc: Double, now: Double) -> Count {
        var r = Count()
        var end = frames.count
        while end > 0, frames[end - 1].t > now { end -= 1 }
        guard end > 0 else { return r }
        let last = frames[end - 1]
        r.age = now - last.t
        guard r.age <= maxFrameAge else { return r }
        r.contacts = last.contacts.count
        r.layoutOK = last.layoutOK
        struct Track { var id: Int32; var state: Int32; var seen: Double; var run: Double; var touch: Double?; var inWindow = false; var size: Float = 0 }
        var tracks: [Track] = []
        var prev: [Contact] = []
        let lo = tc - before
        for f in frames[0..<end] {
            for c in f.contacts {
                // Тот же контакт, если был в прошлом кадре и не уходил (7/0); иначе — новый, даже с тем же номером.
                let same = prev.contains { $0.id == c.id && $0.state != 7 && $0.state != 0 }
                let k = tracks.lastIndex { $0.id == c.id }
                var t = Track(id: c.id, state: c.state, seen: f.t, run: f.t)
                if same, let k { t = tracks[k] }
                t.state = c.state; t.seen = f.t
                if touchStates.contains(c.state) {
                    if t.touch == nil { t.touch = f.t }
                    if f.t >= lo { t.inWindow = true; t.size = max(t.size, c.size) }
                }
                if same, let k { tracks[k] = t } else { if let k { tracks.remove(at: k) }; tracks.append(t) }
            }
            prev = f.contacts
        }
        var fingers = tracks.filter { $0.inWindow && $0.seen >= last.t - presentSlack && presentStates.contains($0.state) }
        r.counted = fingers.count
        r.sizes = fingers.map(\.size)
        // Лежащий большой палец / ладонь: заметно крупнее остальных и лежит давно.
        if fingers.count >= 2, let big = fingers.indices.max(by: { fingers[$0].size < fingers[$1].size }) {
            let others = fingers.indices.filter { $0 != big }.map { fingers[$0].size }
            if let m = others.max(), others.allSatisfy({ $0 > 0 }),
               fingers[big].size >= palmRatio * m, fingers[big].run <= tc - restAge {
                fingers.remove(at: big)
                r.palm = true
            }
        }
        r.fingers = fingers.count
        r.lastTouch = fingers.compactMap(\.touch).max()
        return r
    }

    /// Самый «занятый» тачпад со свежим кадром.
    static func best(_ devices: [[Frame]], click tc: Double, now: Double) -> Count {
        var b = Count()
        for f in devices {
            let c = count(f, click: tc, now: now)
            if (c.fingers, c.counted, c.contacts, -c.age) > (b.fingers, b.counted, b.contacts, -b.age) { b = c }
        }
        return b
    }

    /// Решение у нажатия. sample — снимок лент всех тачпадов и текущее время, pause — шаг ожидания.
    /// Ждём только при ровно двух пальцах; щелчок одним пальцем и мышью (нет свежих кадров) проходят сразу.
    static func decide(click tc: Double, sample: () -> (now: Double, devices: [[Frame]]), pause: () -> Void) -> Decision {
        var d = Decision(click: tc)
        var s = sample()
        d.count = best(s.devices, click: tc, now: s.now)
        d.atPress = d.count.fingers
        d.peak = d.count.fingers
        if d.count.fingers == 2 {
            repeat {
                pause()
                s = sample()
                d.count = best(s.devices, click: tc, now: s.now)
                d.peak = max(d.peak, d.count.fingers)
            } while d.count.fingers == 2 && s.now - tc < maxWait
            d.waited = s.now - tc
        }
        return d
    }

    /// Строка журнала: одно нажатие — одна строка.
    static func describe(_ d: Decision, button: String, source: String, pressure: Double, swallowed: Bool, on: Bool) -> String {
        let c = d.count
        var s = "жест (\(source), \(button)): пальцев \(c.fingers) (при нажатии \(d.atPress), максимум \(d.peak))"
        if let w = d.waited {
            s += String(format: ", ждал 3-й палец %.0f мс — %@", w * 1000, c.fingers >= 3 ? "пришёл" : "не пришёл")
        }
        if let lt = c.lastTouch, c.fingers >= 2 {
            let ms = (lt - d.click) * 1000
            if ms >= 0 { s += String(format: ", последний коснулся через %.0f мс после щелчка", ms) }
            else if -ms < restAge * 1000 { s += String(format: ", последний коснулся за %.0f мс до щелчка", -ms) }
            else { s += ", все лежали заранее" }
        }
        if c.palm { s += ", большой палец/ладонь не в счёт" }
        s += ", контактов \(c.contacts)"
        if c.sizes.contains(where: { $0 > 0 }) { s += ", размеры " + c.sizes.map { String(format: "%.2f", $0) }.joined(separator: "/") }
        if !c.layoutOK { s += ", раскладка незнакомая" }
        s += String(format: ", нажим %.2f, ", pressure) + (c.age < 99 ? String(format: "кадр %.0f мс назад", c.age * 1000) : "кадров нет")
        if swallowed { return s + ", проглочено да" }
        let why = !on ? "жест выключен" : c.counted > toggleRange.upperBound ? "контактов \(c.counted), много" : "пальцев \(c.fingers)"
        return s + ", проглочено нет → " + why
    }
}

/// Короткая лента кадров по устройствам (пишется из потока MultitouchSupport, читается с потока перехвата).
private final class TouchState {
    static let shared = TouchState()
    private let lock = NSLock()
    private var byDevice: [UInt: [GestureLogic.Frame]] = [:]
    private var layoutWarned = false

    func update(_ dev: MTDeviceRef?, _ touches: UnsafeMutableRawPointer?, _ n: Int32) {
        let r = GestureLogic.contacts(UnsafeRawPointer(touches), count: Int(n))
        let now = CACurrentMediaTime()
        let key = UInt(bitPattern: dev)
        lock.lock()
        var h = byDevice.removeValue(forKey: key) ?? []
        h.append(GestureLogic.Frame(t: now, contacts: r.contacts, layoutOK: r.layoutOK))
        var drop = 0
        while drop < h.count - 1, h[drop].t < now - GestureLogic.historyKeep { drop += 1 }
        drop = max(drop, h.count - GestureLogic.maxFrames)
        if drop > 0 { h.removeFirst(drop) }
        byDevice[key] = h
        let warn = !r.layoutOK && !layoutWarned
        if warn { layoutWarned = true }
        lock.unlock()
        if warn { DispatchQueue.main.async { KadrLog.write("жест: незнакомая раскладка кадров тачпада — считаю все контакты") } }
    }

    func snapshot() -> (now: Double, devices: [[GestureLogic.Frame]]) {
        lock.lock(); defer { lock.unlock() }
        return (CACurrentMediaTime(), Array(byDevice.values))
    }

    func reset() { lock.lock(); byDevice = [:]; lock.unlock() }
}

private let contactCallback: MTContactCallback = { dev, touches, n, _, _ in
    TouchState.shared.update(dev, touches, n)
    return 0
}

// MARK: - Жест «нажатие тремя пальцами»

/// Физическое нажатие тачпада тремя пальцами открывает и прячет панель истории.
/// Нажатие перехватывается (CGEventTap), чтобы под курсором ничего не щёлкнуло. Слушаем и правую кнопку:
/// если третий палец опоздал, macOS видит щелчок двумя пальцами (правый) — его тоже глотаем, меню не откроется.
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
    private enum Held { case none, left, right }
    private var held = Held.none            // только поток перехвата: какое нажатие проглочено
    private let lock = NSLock()
    private var on = false                  // под lock: копия enabled для потока перехвата
    private var watchTimer: Timer?
    private var wakeObserver: Any?
    private var prefObserver: NSKeyValueObservation?
    private var enabled: Bool?
    private var dragOn = false              // в системе включено перетаскивание тремя пальцами
    private var togglesStore = 0
    var toggles: Int { lock.lock(); defer { lock.unlock() }; return togglesStore }

    var tapActive: Bool { currentTap().map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    /// Строка для настроек, если жест не работает (nil — всё в порядке или выключен).
    var problem: String? {
        guard Prefs.clipGesture else { return nil }
        if dragOn { return L("Three-finger drag is on in System Settings, so Kadr leaves three-finger presses to macOS. Use ⌥⇧V or the screen edge.") }
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
        let pref = Prefs.clipGesture
        if pref { dragOn = GestureTrigger.systemThreeFingerDrag() }
        let want = pref && !dragOn
        // Пока жест включён в настройках, раз в 3 с: тачпады, доступ, перехват и системное перетаскивание тремя пальцами.
        if pref, watchTimer == nil {
            let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.watch() }
            t.tolerance = 1
            RunLoop.main.add(t, forMode: .common)
            watchTimer = t
        } else if !pref {
            watchTimer?.invalidate(); watchTimer = nil
        }
        guard want != enabled else { return }
        enabled = want
        lock.lock(); on = want; lock.unlock()
        if want {
            restartDevices()
            ensureTap()
            KadrLog.write("жест: включён — устройств \(deviceCount), перехват \(tap != nil ? "есть" : "нет доступа"), MultitouchSupport \(available ? "есть" : "нет")")
        } else {
            stopDevices()
            removeTap()
            KadrLog.write(pref ? "жест: уступил системе — включено перетаскивание тремя пальцами" : "жест: выключен")
        }
    }

    /// Системное перетаскивание тремя пальцами (Универсальный доступ → Управление указателем → Параметры трекпада).
    /// Оно начинается с того же нажатия при трёх пальцах на тачпаде, поэтому, пока оно включено, жест ничего не перехватывает.
    static func systemThreeFingerDrag() -> Bool {
        // Тестовый профиль: KADR_THREE_FINGER_DRAG=1|0 вместо настоящей настройки (системную не трогаем).
        if Profile.name != nil, let v = ProcessInfo.processInfo.environment["KADR_THREE_FINGER_DRAG"] { return v == "1" }
        func isOn(_ v: CFPropertyList?) -> Bool { (v as? NSNumber)?.boolValue ?? false }
        for domain in ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"] {
            let dom = domain as CFString
            CFPreferencesAppSynchronize(dom)
            if isOn(CFPreferencesCopyAppValue("TrackpadThreeFingerDrag" as CFString, dom)) { return true }
        }
        let host = CFPreferencesCopyValue("com.apple.trackpad.threeFingerDragGesture" as CFString, kCFPreferencesAnyApplication,
                                          kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        return isOn(host)
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
        guard Prefs.clipGesture else { return }
        if GestureTrigger.systemThreeFingerDrag() != dragOn { apply(); return }
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
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
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
        case .leftMouseDown, .rightMouseDown:
            held = .none
            lock.lock(); let on = self.on; lock.unlock()
            guard on else { return Unmanaged.passUnretained(event) }
            // При ровно двух пальцах колбэк ждёт третий до 90 мс (кадры идут со своего потока); иначе решение сразу.
            let d = GestureLogic.decide(click: CACurrentMediaTime(), sample: { TouchState.shared.snapshot() },
                                        pause: { usleep(useconds_t(GestureLogic.pollStep * 1_000_000)) })
            // Обычный щелчок одним пальцем (или мышью) не трогаем и не пишем в журнал.
            if d.quiet { return Unmanaged.passUnretained(event) }
            let right = type == .rightMouseDown
            if press(d, button: right ? "правая" : "левая", pressure: event.getDoubleValueField(.mouseEventPressure), source: "тачпад") {
                held = right ? .right : .left
                return nil
            }
            return Unmanaged.passUnretained(event)
        case .leftMouseDragged:
            return held == .left ? nil : Unmanaged.passUnretained(event)
        case .rightMouseDragged:
            return held == .right ? nil : Unmanaged.passUnretained(event)
        case .leftMouseUp:
            if held == .left { held = .none; return nil }
            return Unmanaged.passUnretained(event)
        case .rightMouseUp:
            if held == .right { held = .none; return nil }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// Общий путь для настоящего жеста и проверки (--gesture-sim): решение, переключение, журнал.
    /// Возвращает true, если нажатие надо проглотить.
    @discardableResult
    func press(_ d: GestureLogic.Decision, button: String, pressure: Double, source: String) -> Bool {
        lock.lock()
        let on = self.on
        let toggle = on && d.toggle
        if toggle { togglesStore += 1 }
        lock.unlock()
        let line = GestureLogic.describe(d, button: button, source: source, pressure: pressure, swallowed: toggle, on: on)
        DispatchQueue.main.async {
            KadrLog.write(line)
            if toggle { GestureTrigger.shared.act() }
        }
        return toggle
    }

    /// Проверка без тачпада (--gesture-sim): «N пальцев» разом, без ожидания.
    @discardableResult
    func press(fingers: Int, raw: Int, age: Double, pressure: Double, source: String) -> Bool {
        var c = GestureLogic.Count()
        c.fingers = fingers; c.counted = fingers; c.contacts = raw; c.age = age
        return press(GestureLogic.Decision(count: c, atPress: fingers, peak: fingers), button: "левая", pressure: pressure, source: source)
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
    /// Палец на ленте: кадр над поверхностью (2), коснулся в land (3, потом 4), оторвался в lift (5 → 6 → 6 → 7 → исчез).
    private struct Finger {
        var id: Int32
        var land: Double
        var lift = Double.infinity
        var size: Float = 1
        var flicker: ClosedRange<Double>? = nil
        var flickerState: Int32 = 2
    }

    private static let dt = 0.008     // ~125 кадров в секунду

    /// Лента кадров, щелчок в момент 0. Кадры идут, пока есть контакты, плюс один пустой после ухода всех.
    private static func timeline(_ fingers: [Finger], from start: Double = -0.7, to end: Double = 0.2) -> [GestureLogic.Frame] {
        var out: [GestureLogic.Frame] = []
        var i = 0
        while start + Double(i) * dt <= end + 1e-9 {
            let t = start + Double(i) * dt
            i += 1
            var cs: [GestureLogic.Contact] = []
            for f in fingers where t >= f.land - dt {
                var st: Int32
                if t < f.land { st = 2 }
                else if t < f.lift { st = t - f.land < dt ? 3 : 4; if let fl = f.flicker, fl.contains(t) { st = f.flickerState } }
                else {
                    let k = Int((t - f.lift) / dt)
                    if k == 0 { st = 5 } else if k <= 2 { st = 6 } else if k == 3 { st = 7 } else { continue }
                }
                cs.append(.init(id: f.id, state: st, size: f.size))
            }
            if !cs.isEmpty || out.last.map({ !$0.contacts.isEmpty }) == true { out.append(.init(t: t, contacts: cs)) }
        }
        return out
    }

    /// Решение по ленте: колбэк перехвата получает нажатие через 2 мс, ожидание — виртуальными шагами.
    private static func decide(_ frames: [GestureLogic.Frame]) -> GestureLogic.Decision {
        var now = 0.002
        return GestureLogic.decide(click: 0, sample: { (now, [frames.filter { $0.t <= now }]) }, pause: { now += GestureLogic.pollStep })
    }

    private static func raw(_ items: [(id: Int32, state: Int32, size: Float)]) -> (contacts: [GestureLogic.Contact], layoutOK: Bool) {
        let n = max(1, items.count)
        let buf = UnsafeMutableRawPointer.allocate(byteCount: n * GestureLogic.touchStride, alignment: 8)
        defer { buf.deallocate() }
        memset(buf, 0, n * GestureLogic.touchStride)
        for (i, c) in items.enumerated() {
            buf.storeBytes(of: c.id, toByteOffset: i * GestureLogic.touchStride + GestureLogic.idOffset, as: Int32.self)
            buf.storeBytes(of: c.state, toByteOffset: i * GestureLogic.touchStride + GestureLogic.stateOffset, as: Int32.self)
            buf.storeBytes(of: c.size, toByteOffset: i * GestureLogic.touchStride + GestureLogic.sizeOffset, as: Float.self)
        }
        return GestureLogic.contacts(buf, count: items.count)
    }

    static func run() -> Bool {
        var ok = true, passed = 0, total = 0
        func check(_ name: String, _ cond: Bool) {
            total += 1; if cond { passed += 1 } else { ok = false }
            print("\(cond ? "OK " : "НЕТ") \(name)")
        }
        func ms(_ d: GestureLogic.Decision) -> String { d.waited.map { String(format: " [ждал %.0f мс]", $0 * 1000) } ?? "" }
        let early = -0.3

        // Разбор сырого кадра MultitouchSupport.
        let r1 = raw([(1, 4, 1.2), (2, 4, 0.9), (3, 3, 1.0)])
        check("кадр: номера, состояния и размеры читаются", r1.layoutOK && r1.contacts.map(\.id) == [1, 2, 3] && r1.contacts.map(\.state) == [4, 4, 3] && r1.contacts[0].size == 1.2)
        check("кадр: пустой → нет контактов", raw([]).contacts.isEmpty && raw([]).layoutOK)
        let g1 = raw([(1, 4, 1), (2, 99, 1), (3, 4, 1)])
        check("кадр: мусор в state → все контакты как касания (старая раскладка)", !g1.layoutOK && g1.contacts.count == 3 && g1.contacts.allSatisfy { $0.state == 4 })
        check("кадр: одинаковые номера → все контакты как касания", !raw([(5, 4, 1), (5, 4, 1)]).layoutOK)
        check("кадр: номер вне диапазона → все контакты как касания", !raw([(1, 4, 1), (1_000_000, 4, 1)]).layoutOK)
        check("кадр: размер NaN → 0", raw([(1, 4, .nan)]).contacts.first?.size == 0)

        // Нажатия на ленте.
        var d = decide(timeline([.init(id: 1, land: early), .init(id: 2, land: early), .init(id: 3, land: early)]))
        check("три пальца разом → переключить без ожидания", d.toggle && d.waited == nil && d.atPress == 3)
        print("    пример: " + GestureLogic.describe(d, button: "левая", source: "тачпад", pressure: 1, swallowed: d.toggle, on: true))

        d = decide(timeline([.init(id: 1, land: early), .init(id: 2, land: early), .init(id: 3, land: 0.04)]))
        check("3-й палец через 40 мс после щелчка → переключить" + ms(d), d.toggle && d.atPress == 2 && (d.waited ?? 1) < 0.06)
        print("    пример: " + GestureLogic.describe(d, button: "левая", source: "тачпад", pressure: 1, swallowed: d.toggle, on: true))

        d = decide(timeline([.init(id: 1, land: early), .init(id: 2, land: early), .init(id: 3, land: -0.07)]))
        check("3-й палец за 70 мс до щелчка (и лежит) → переключить", d.toggle && d.waited == nil)

        d = decide(timeline([.init(id: 1, land: early), .init(id: 2, land: early), .init(id: 3, land: -0.07, lift: -0.04)]))
        check("3-й коснулся за 70 мс и уже оторвался → нет" + ms(d), !d.toggle && d.atPress == 2)

        d = decide(timeline([.init(id: 1, land: early), .init(id: 2, land: early), .init(id: 3, land: early, flicker: -0.02...0.03)]))
        check("безымянный мигает 4→2→4 у щелчка → переключить без ожидания", d.toggle && d.waited == nil)

        d = decide(timeline([.init(id: 1, land: early), .init(id: 2, land: early), .init(id: 3, land: early, flicker: -0.02...0.02, flickerState: 6)]))
        check("безымянный мигает через 6 и возвращается → дождались, переключить" + ms(d), d.toggle && d.waited != nil)

        d = decide(timeline([.init(id: 1, land: -0.15), .init(id: 2, land: -0.15), .init(id: 3, land: 0.06)]))
        check("правая: 3-й палец через 60 мс → переключить и проглотить" + ms(d), d.toggle && d.atPress == 2 && (d.waited ?? 1) < 0.08)
        print("    пример: " + GestureLogic.describe(d, button: "правая", source: "тачпад", pressure: 1, swallowed: d.toggle, on: true))

        d = decide(timeline([.init(id: 1, land: -0.15), .init(id: 2, land: -0.15)]))
        check("правая: честные два пальца → пропустить, ожидание ≤ 100 мс" + ms(d), !d.toggle && !d.quiet && (d.waited ?? 0) >= 0.085 && (d.waited ?? 1) <= 0.1)
        print("    пример: " + GestureLogic.describe(d, button: "правая", source: "тачпад", pressure: 1, swallowed: d.toggle, on: true))

        d = decide(timeline([.init(id: 1, land: early), .init(id: 2, land: early), .init(id: 3, land: 0.12)]))
        check("3-й палец через 120 мс — поздно → нет" + ms(d), !d.toggle && (d.waited ?? 1) <= 0.1)

        d = decide(timeline([.init(id: 1, land: early), .init(id: 2, land: early, lift: 0.02)]))
        check("пальцы ушли во время ожидания → дальше не ждём" + ms(d), !d.toggle && (d.waited ?? 1) < 0.05)

        d = decide(timeline([.init(id: 1, land: -0.6, lift: -0.09), .init(id: 2, land: -0.6, lift: -0.09), .init(id: 3, land: -0.04)]))
        check("прокрутка двумя кончилась, щелчок одним → нет, сразу, без журнала", !d.toggle && d.waited == nil && d.quiet)

        d = decide(timeline([.init(id: 1, land: -0.6, lift: -0.015), .init(id: 2, land: -0.6, lift: -0.015), .init(id: 3, land: -0.04)]))
        check("прокрутка только что кончилась (пальцы в 6), щелчок одним → нет, сразу", !d.toggle && d.waited == nil && d.count.fingers == 1)

        d = decide(timeline([.init(id: 9, land: -0.65, size: 2.8), .init(id: 1, land: -0.2), .init(id: 2, land: -0.2), .init(id: 3, land: -0.2)]))
        check("3 пальца + лежащий большой палец → переключить (большой не в счёт)", d.toggle && d.count.palm && d.count.fingers == 3)
        print("    пример: " + GestureLogic.describe(d, button: "левая", source: "тачпад", pressure: 1, swallowed: d.toggle, on: true))

        d = decide(timeline([.init(id: 1, land: -0.2), .init(id: 2, land: -0.2), .init(id: 3, land: -0.2), .init(id: 4, land: -0.2)]))
        check("4 одинаковых контакта → переключить (три пальца и ещё один)", d.toggle && d.count.fingers == 4)

        d = decide(timeline([.init(id: 9, land: -0.65, size: 2.8), .init(id: 1, land: -0.15), .init(id: 2, land: -0.15)]))
        check("правая двумя + лежащий большой палец → пропустить" + ms(d), !d.toggle && d.count.palm && d.count.fingers == 2)

        d = decide(timeline([.init(id: 9, land: -0.65, size: 2.8), .init(id: 1, land: -0.15)]))
        check("щелчок одним + лежащий большой палец → сразу мимо, без журнала", !d.toggle && d.waited == nil && d.quiet)

        d = decide(timeline([.init(id: 1, land: -0.2, size: 2.0), .init(id: 2, land: -0.2), .init(id: 3, land: -0.2)]))
        check("крупный палец, но лёг вместе с остальными → считается", d.toggle && !d.count.palm && d.count.fingers == 3)

        d = decide(timeline((1...5).map { .init(id: Int32($0), land: -0.2) }))
        check("5 пальцев → нет", !d.toggle && d.waited == nil)

        d = decide(timeline([.init(id: 9, land: -0.65, size: 2.8)] + (1...4).map { .init(id: Int32($0), land: -0.2) }))
        check("4 пальца + ладонь (5 контактов) → нет", !d.toggle)

        d = decide(timeline([.init(id: 1, land: -0.6), .init(id: 2, land: -0.6), .init(id: 3, land: -0.6)], to: -0.4))
        check("старые кадры (тачпад молчит 400 мс) → нет, сразу", !d.toggle && d.waited == nil && d.quiet)

        d = decide([])
        check("мышь (кадров нет) → сразу мимо, без журнала", !d.toggle && d.waited == nil && d.quiet)

        d = decide(timeline([.init(id: 1, land: -0.2)]))
        check("щелчок одним пальцем → сразу мимо, без журнала", !d.toggle && d.waited == nil && d.quiet)

        let g3 = raw([(1, 4, 1), (2, 99, 1), (3, 4, 1)])
        let gf = stride(from: -0.3, through: 0.0, by: dt).map { GestureLogic.Frame(t: $0, contacts: g3.contacts, layoutOK: g3.layoutOK) }
        d = decide(gf)
        check("незнакомая раскладка, 3 контакта → переключить (как раньше)", d.toggle && !d.count.layoutOK)

        // Проверка без тачпада (--gesture-sim) и границы.
        func sim(_ n: Int) -> Bool { var c = GestureLogic.Count(); c.fingers = n; c.counted = n; return GestureLogic.Decision(count: c).toggle }
        check("проверка: 3 → да, 4 → да, 2 → нет, 5 → нет, 1 → нет", sim(3) && sim(4) && !sim(2) && !sim(5) && !sim(1))

        // Настоящее ожидание (usleep) не дольше потолка.
        let t0 = CACurrentMediaTime()
        let real = GestureLogic.decide(click: t0, sample: {
            let now = CACurrentMediaTime()
            let two = [GestureLogic.Contact(id: 1, state: 4, size: 1), GestureLogic.Contact(id: 2, state: 4, size: 1)]
            return (now, [[GestureLogic.Frame(t: now - 0.3, contacts: two), GestureLogic.Frame(t: now - 0.002, contacts: two)]])
        }, pause: { usleep(useconds_t(GestureLogic.pollStep * 1_000_000)) })
        let el = CACurrentMediaTime() - t0
        check(String(format: "настоящее ожидание при двух пальцах: %.0f мс (потолок 90, допуск до 120)", el * 1000), !real.toggle && el >= 0.085 && el < 0.12)

        print("итого: \(passed)/\(total)")
        return ok
    }
}
