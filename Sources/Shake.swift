// Kadr — встряхивание курсора во время перетаскивания открывает полку.
import AppKit

/// Чистая логика: считает развороты движения по X. Разворот засчитывается, если перед ним
/// курсор прошёл не меньше minAmplitude; нужно reversalsNeeded разворотов за window секунд.
struct ShakeDetector {
    var minAmplitude: CGFloat = 45
    var window: TimeInterval = 0.6
    var reversalsNeeded = 3

    private var started = false
    private var dir: CGFloat = 0
    private var runStart: CGFloat = 0
    private var extreme: CGFloat = 0
    private var reversals: [TimeInterval] = []
    private var runYMin: CGFloat = 0
    private var runYMax: CGFloat = 0

    /// 0 — низкая, 1 — средняя, 2 — высокая чувствительность.
    mutating func configure(sensitivity: Int) {
        reversalsNeeded = 3
        switch sensitivity {
        case 0: minAmplitude = 90; window = 0.55
        case 2: minAmplitude = 48; window = 0.65
        default: minAmplitude = 65; window = 0.6
        }
    }

    /// Встряхивание без перетаскивания: пороги заметно строже, чтобы не срабатывать при обычной работе мышью.
    mutating func configureIdle(sensitivity: Int) {
        switch sensitivity {
        case 0: minAmplitude = 170; window = 0.9; reversalsNeeded = 5
        case 2: minAmplitude = 100; window = 0.85; reversalsNeeded = 4
        default: minAmplitude = 130; window = 0.85; reversalsNeeded = 4
        }
    }

    mutating func reset() {
        started = false
        dir = 0
        reversals.removeAll()
    }

    mutating func add(x: CGFloat, y: CGFloat = 0, t: TimeInterval) -> Bool {
        if !started {
            started = true
            runStart = x
            extreme = x
            dir = 0
            runYMin = y
            runYMax = y
            return false
        }
        runYMin = min(runYMin, y)
        runYMax = max(runYMax, y)
        if dir == 0 {
            if abs(x - runStart) >= 6 { dir = x > runStart ? 1 : -1; extreme = x }
            return false
        }
        if (x - extreme) * dir >= 0 { extreme = x; return false } // движение продолжается
        guard (extreme - x) * dir >= 8 else { return false }       // мелкое дрожание не считаем
        // Засчитываем только размашистый и преимущественно горизонтальный взмах.
        let dx = abs(extreme - runStart)
        if dx >= minAmplitude && (runYMax - runYMin) <= dx * 0.6 { reversals.append(t) }
        runYMin = y
        runYMax = y
        runStart = extreme
        extreme = x
        dir = -dir
        reversals.removeAll { t - $0 > window }
        if reversals.count >= reversalsNeeded {
            reversals.removeAll()
            return true
        }
        return false
    }
}

/// Решает, идёт ли настоящее перетаскивание, и только тогда отдаёт движение детектору.
/// Настоящее: буфер перетаскивания изменился ПОСЛЕ текущего нажатия, в нём есть поддерживаемые данные,
/// кнопка держится ≥ 0,25 с и курсор прошёл ≥ 40 pt. Всё сбрасывается при отпускании и при движении без кнопки.
struct DragShakeGate {
    var detector = ShakeDetector()
    var cooldownUntil: TimeInterval = 0
    private var downTime: TimeInterval?
    private var downChangeCount = 0
    private var travel: CGFloat = 0
    private var last: CGPoint?
    private var fired = false

    mutating func mouseDown(t: TimeInterval, changeCount: Int) {
        downTime = t
        downChangeCount = changeCount
        travel = 0
        last = nil
        fired = false
        detector.reset()
    }

    mutating func reset() {
        downTime = nil
        travel = 0
        last = nil
        fired = false
        detector.reset()
    }

    mutating func dragged(p: CGPoint, t: TimeInterval, changeCount: Int, hasSupportedData: Bool, sensitivity: Int) -> Bool {
        guard let down = downTime, !fired else { return false }
        if let l = last { travel += hypot(p.x - l.x, p.y - l.y) }
        last = p
        guard changeCount != downChangeCount, hasSupportedData else { detector.reset(); return false }
        guard t - down >= 0.25, travel >= 40, t >= cooldownUntil else { return false }
        detector.configure(sensitivity: sensitivity)
        if detector.add(x: p.x, y: p.y, t: t) {
            fired = true
            cooldownUntil = t + 2
            return true
        }
        return false
    }
}

/// Глобальное наблюдение за перетаскиванием в других программах.
/// Мышиные глобальные мониторы работают без разрешения «Универсальный доступ».
final class ShakeMonitor {
    static let shared = ShakeMonitor()

    var onShake: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?
    var onIdleShake: ((NSPoint) -> Void)?
    private var idleDetector = ShakeDetector()
    private var lastIdleFire: TimeInterval = 0
    private(set) var available = false
    private var monitors: [Any] = []
    private var gate = DragShakeGate()
    private var firedThisDrag = false

    /// Движение мыши без кнопки нужно только встряхиванию без перетаскивания (по умолчанию выключено).
    /// Монитор движения будит Kadr на каждом сдвиге курсора, поэтому ставится только при включённой настройке.
    private var moveMonitor: Any?
    private var idleObserver: NSKeyValueObservation?

    func start() {
        guard monitors.isEmpty else { return }
        let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in self?.mouseDown(e) }
        let drag = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] e in self?.mouseDragged(e) }
        let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in self?.mouseUp() }
        monitors = [down, drag, up].compactMap { $0 }
        available = monitors.count == 3
        updateMoveMonitor()
        idleObserver = Prefs.d.observe(\.idleShakeEnabled, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateMoveMonitor() }
        }
    }

    private func updateMoveMonitor() {
        let want = Prefs.idleShakeEnabled
        if want, moveMonitor == nil {
            moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] e in self?.mouseMoved(e) }
        } else if !want, let m = moveMonitor {
            NSEvent.removeMonitor(m)
            moveMonitor = nil
            idleDetector.reset()
        }
    }

    /// Пауза после открытия или закрытия полки, чтобы полки не мигали.
    func noteShelfClosed() {
        let now = ProcessInfo.processInfo.systemUptime
        gate.cooldownUntil = max(gate.cooldownUntil, now + 2)
        lastIdleFire = max(lastIdleFire, now)
    }

    private func mouseMoved(_ e: NSEvent) {
        // Движение без кнопки: никакого перетаскивания нет — сбрасываем его состояние.
        gate.reset()
        firedThisDrag = false
        guard Prefs.idleShakeEnabled, NSEvent.pressedMouseButtons == 0 else { idleDetector.reset(); return }
        idleDetector.configureIdle(sensitivity: Prefs.idleShakeSensitivity)
        let p = NSEvent.mouseLocation
        if idleDetector.add(x: p.x, y: p.y, t: e.timestamp), e.timestamp - lastIdleFire > 2 {
            lastIdleFire = e.timestamp
            idleDetector.reset()
            onIdleShake?(p)
        }
    }

    private func mouseDown(_ e: NSEvent) {
        gate.mouseDown(t: e.timestamp, changeCount: NSPasteboard(name: .drag).changeCount)
        firedThisDrag = false
    }

    private static let supported: Set<NSPasteboard.PasteboardType> = Set(ShelfStore.readableTypes)

    private func mouseDragged(_ e: NSEvent) {
        guard Prefs.shakeEnabled, !firedThisDrag, NSEvent.pressedMouseButtons & 1 == 1 else { return }
        let pb = NSPasteboard(name: .drag)
        let cc = pb.changeCount
        var hasData = false
        if cc != 0 {
            let types = Set(pb.types ?? [])
            hasData = !(pb.pasteboardItems ?? []).isEmpty && !types.isDisjoint(with: ShakeMonitor.supported)
        }
        let p = NSEvent.mouseLocation
        if gate.dragged(p: p, t: e.timestamp, changeCount: cc, hasSupportedData: hasData, sensitivity: Prefs.shakeSensitivity) {
            firedThisDrag = true
            onShake?(p)
        }
    }

    private func mouseUp() {
        if firedThisDrag { onDragEnded?() }
        firedThisDrag = false
        gate.reset()
    }
}

/// Синтетическая проверка детектора (Kadr --shake-test).
enum ShakeSelfTest {
    static func run() -> Bool {
        func feed(_ sens: Int, duration: Double, _ f: (Double) -> Double) -> Bool {
            var d = ShakeDetector()
            d.configure(sensitivity: sens)
            var t = 0.0
            while t <= duration {
                if d.add(x: CGFloat(f(t)), t: t) { return true }
                t += 1.0 / 120
            }
            return false
        }
        let cases: [(String, Bool, Bool)] = [
            ("встряхивание ±80 pt, 3.5 Гц", true, feed(1, duration: 1.0) { 500 + 80 * sin(2 * .pi * 3.5 * $0) }),
            ("прямое перетаскивание 400 pt/с", false, feed(1, duration: 2.0) { 100 + 400 * $0 }),
            ("дрожание ±10 pt, 6 Гц", false, feed(1, duration: 2.0) { 500 + 10 * sin(2 * .pi * 6 * $0) }),
            ("медленные качели ±150 pt, 0.7 Гц", false, feed(1, duration: 3.0) { 500 + 150 * sin(2 * .pi * 0.7 * $0) }),
            ("±45 pt, 4 Гц, средняя", true, feed(1, duration: 1.0) { 500 + 45 * sin(2 * .pi * 4 * $0) }),
            ("±30 pt, 4 Гц, средняя", false, feed(1, duration: 1.0) { 500 + 30 * sin(2 * .pi * 4 * $0) }),
            ("±45 pt, 4 Гц, низкая", false, feed(0, duration: 1.0) { 500 + 45 * sin(2 * .pi * 4 * $0) }),
            ("перетаскивание, потом встряхивание", true, feed(1, duration: 2.0) { t in
                t < 1 ? 100 + 300 * t : 400 + 70 * sin(2 * .pi * 3 * (t - 1)) }),
        ]
        func feedIdle(_ sens: Int, duration: Double, _ f: (Double) -> Double) -> Bool {
            var d = ShakeDetector()
            d.configureIdle(sensitivity: sens)
            var t = 0.0
            while t <= duration {
                if d.add(x: CGFloat(f(t)), t: t) { return true }
                t += 1.0 / 120
            }
            return false
        }
        // Обычные быстрые движения: рывок к цели с перелётом и поправкой.
        func flick(_ t: Double) -> Double {
            if t < 0.25 { return 100 + 900 * (t / 0.25) }       // рывок на 900 pt
            if t < 0.35 { return 1000 + 50 * ((t - 0.25) / 0.1) } // перелёт
            if t < 0.5 { return 1050 - 60 * ((t - 0.35) / 0.15) } // поправка назад
            return 990
        }
        // Туда-обратно один раз (перенос взгляда между двумя окнами).
        func backAndForth(_ t: Double) -> Double { t < 0.3 ? 200 + 1500 * t : max(200, 650 - 1500 * (t - 0.3)) }
        // Выделение текста/подбор позиции: частые мелкие качания ±40 pt.
        func scrub(_ t: Double) -> Double { 600 + 40 * sin(2 * .pi * 5 * t) }
        // Два размашистых взмаха и остановка.
        func twoSwings(_ t: Double) -> Double { t < 0.6 ? 600 + 200 * sin(2 * .pi * 1.7 * t) : 600 + 200 * sin(2 * .pi * 1.7 * 0.6) }
        // Быстрые переходы между тремя целями (меню, панель, документ).
        func hops(_ t: Double) -> Double {
            let pts: [Double] = [200, 900, 500, 1100, 300]
            let i = min(Int(t / 0.35), pts.count - 2)
            let f = min(1, (t - Double(i) * 0.35) / 0.2)
            return pts[i] + (pts[i + 1] - pts[i]) * f
        }
        let idle: [(String, Bool, Bool)] = [
            ("[без перетаскивания] встряхивание ±160 pt, 3 Гц", true, feedIdle(1, duration: 1.2) { 600 + 160 * sin(2 * .pi * 3 * $0) }),
            ("[без перетаскивания] рывок к цели с поправкой", false, feedIdle(1, duration: 1.0, flick)),
            ("[без перетаскивания] туда-обратно один раз", false, feedIdle(1, duration: 1.0, backAndForth)),
            ("[без перетаскивания] мелкие качания ±40 pt, 5 Гц", false, feedIdle(1, duration: 2.0, scrub)),
            ("[без перетаскивания] два взмаха и стоп", false, feedIdle(1, duration: 1.5, twoSwings)),
            ("[без перетаскивания] переходы между целями", false, feedIdle(2, duration: 1.6, hops)),
            ("[без перетаскивания] встряхивание ±80 pt, высокая", true, feedIdle(2, duration: 1.2) { 600 + 80 * sin(2 * .pi * 3 * $0) }),
            ("[без перетаскивания] качания ±55 pt, 3 Гц, средняя", false, feedIdle(1, duration: 2.0) { 600 + 55 * sin(2 * .pi * 3 * $0) }),
            ("[без перетаскивания] качания ±40 pt, 3 Гц, высокая", false, feedIdle(2, duration: 2.0) { 600 + 40 * sin(2 * .pi * 3 * $0) }),
        ]
        // Ворота перетаскивания: события как от глобального монитора.
        enum Ev { case down(Double, Int), drag(Double, CGFloat, CGFloat, Int, Bool), up }
        func gateRun(_ evs: [Ev], cooldownFrom: Double? = nil) -> Bool {
            var g = DragShakeGate()
            if let c = cooldownFrom { g.cooldownUntil = c }
            var opened = false
            for e in evs {
                switch e {
                case .down(let t, let cc): g.mouseDown(t: t, changeCount: cc)
                case .drag(let t, let x, let y, let cc, let data):
                    if g.dragged(p: CGPoint(x: x, y: y), t: t, changeCount: cc, hasSupportedData: data, sensitivity: 1) { opened = true }
                case .up: g.reset()
                }
            }
            return opened
        }
        func shakeDrag(from t0: Double, to t1: Double, amp: CGFloat, hz: Double, cc: Int, data: Bool, vertical: Bool = false) -> [Ev] {
            var r: [Ev] = []
            var t = t0
            while t <= t1 {
                let v = 500 + amp * CGFloat(sin(2 * .pi * hz * (t - t0)))
                r.append(vertical ? .drag(t, 500, v, cc, data) : .drag(t, v, 400, cc, data))
                t += 1.0 / 120
            }
            return r
        }
        let gate: [(String, Bool, Bool)] = [
            ("[ворота] выделение текста туда-сюда без смены буфера перетаскивания", false,
             gateRun([.down(0, 7)] + shakeDrag(from: 0.05, to: 1.5, amp: 120, hz: 3, cc: 7, data: false))),
            ("[ворота] буфер сменился раньше нажатия (старое значение)", false,
             gateRun([.down(0, 8)] + shakeDrag(from: 0.05, to: 1.5, amp: 120, hz: 3, cc: 8, data: true))),
            ("[ворота] нажатие не замечено монитором", false,
             gateRun(shakeDrag(from: 0.05, to: 1.5, amp: 120, hz: 3, cc: 9, data: true))),
            ("[ворота] буфер сменился, но в нём нет поддерживаемых данных", false,
             gateRun([.down(0, 7)] + shakeDrag(from: 0.05, to: 1.5, amp: 120, hz: 3, cc: 8, data: false))),
            ("[ворота] настоящее перетаскивание + встряхивание", true,
             gateRun([.down(0, 7)] + shakeDrag(from: 0.05, to: 1.5, amp: 90, hz: 3.5, cc: 8, data: true))),
            ("[ворота] настоящее перетаскивание, вертикальные качания", false,
             gateRun([.down(0, 7)] + shakeDrag(from: 0.05, to: 1.5, amp: 120, hz: 3, cc: 8, data: true, vertical: true))),
            ("[ворота] перетаскивание по прямой", false,
             gateRun([.down(0, 7)] + (0..<120).map { i in .drag(0.05 + Double(i) / 120, 100 + CGFloat(i) * 6, 400, 8, true) })),
            ("[ворота] встряхивание только в первые 0,2 с", false,
             gateRun([.down(0, 7)] + shakeDrag(from: 0.0, to: 0.2, amp: 120, hz: 6, cc: 8, data: true) + [.up])),
            ("[ворота] повтор в паузе после полки", false,
             gateRun([.down(10, 7)] + shakeDrag(from: 10.05, to: 11.5, amp: 90, hz: 3.5, cc: 8, data: true), cooldownFrom: 12)),
            ("[ворота] отпускание сбрасывает: второе нажатие без смены буфера", false,
             gateRun([.down(0, 7)] + shakeDrag(from: 0.05, to: 0.2, amp: 10, hz: 1, cc: 8, data: true) + [.up, .down(1, 8)]
                     + shakeDrag(from: 1.05, to: 2.5, amp: 120, hz: 3, cc: 8, data: true))),
        ]
        var ok = true
        for (name, expected, got) in cases + idle + gate {
            let pass = expected == got
            ok = ok && pass
            print("\(pass ? "OK  " : "FAIL") \(name): ожидалось \(expected ? "да" : "нет"), получено \(got ? "да" : "нет")")
        }
        return ok
    }
}
