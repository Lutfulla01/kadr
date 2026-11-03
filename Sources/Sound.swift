// Kadr — звук копирования («тик»): короткий мягкий щелчок, когда в буфер попало новое копирование.
// Звук рисуется скриптом tools/make_tick.swift (Resources/tick.caf) и лежит в памяти готовым буфером.
// Вывод — AVAudioEngine: запускается при первом тике и гаснет через 10 с тишины, так что звуковое
// устройство не держится открытым всё время. Пока движок работает, тик — это только постановка буфера (< 1 мс).
// Громкость системы учитывается, чужой звук не приглушается (на macOS нет общего «аудиофокуса»).
import AVFoundation
import AppKit

enum CopySound {
    /// Не чаще одного тика за 120 мс (серии копирований).
    static let minGap: CFTimeInterval = 0.12
    static let keepAlive: TimeInterval = 10
    private static var engine: AVAudioEngine?
    private static let node = AVAudioPlayerNode()
    private static var buffer: AVAudioPCMBuffer?
    private static var idleStop: DispatchWorkItem?
    private static var lastPlay: CFTimeInterval = -1
    /// Для проверок (StateDump): сколько раз сыграл, сколько пропущено ограничением частоты, последняя задержка.
    private(set) static var plays = 0
    private(set) static var limited = 0
    private(set) static var lastLatencyMs = 0.0

    /// Читает звук в память и собирает граф (без запуска вывода).
    static func preload() {
        guard buffer == nil, let url = Bundle.main.url(forResource: "tick", withExtension: "caf"),
              let file = try? AVAudioFile(forReading: url),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buf)) != nil else { return }
        buffer = buf
        makeEngine()
    }

    private static func makeEngine() {
        guard let buf = buffer else { return }
        let e = AVAudioEngine()
        e.attach(node)
        e.connect(node, to: e.mainMixerNode, format: buf.format)
        e.prepare()
        engine = e
    }

    /// Буфер сменился настоящим копированием (не служебной записью Kadr); detectedAt — CACurrentMediaTime() обнаружения.
    static func copied(detectedAt t0: CFTimeInterval) {
        guard Prefs.copySound else { return }
        let now = CACurrentMediaTime()
        let gap = (now - lastPlay) * 1000
        guard now - lastPlay >= minGap else {
            limited += 1
            if Profile.name != nil { KadrLog.write(String(format: "тик пропущен — чаще 120 мс (%.0f мс)", gap)) }
            return
        }
        lastPlay = now
        let cold = play(volume: Prefs.copySoundVolume)
        plays += 1
        lastLatencyMs = (CACurrentMediaTime() - t0) * 1000
        if Profile.name != nil {
            KadrLog.write(String(format: "тик: %.1f мс от обнаружения%@, после прошлого %.0f мс", lastLatencyMs, cold ? " (запуск вывода)" : "", gap))
        }
    }

    /// «Прослушать» в настройках: без проверки настройки и частоты.
    static func preview(volume: Double) { play(volume: volume) }

    /// Возвращает true, если пришлось запускать вывод.
    @discardableResult
    private static func play(volume: Double) -> Bool {
        preload()
        guard let buf = buffer else { return false }
        var cold = false
        if engine?.isRunning != true {
            cold = true
            do { try engine?.start() } catch {
                // Сменилось устройство вывода или граф сломан — собираем заново.
                engine?.stop(); engine?.detach(node); makeEngine()
                do { try engine?.start() } catch { return true }
            }
        }
        node.volume = Float(min(max(volume, 0), 1))
        node.scheduleBuffer(buf, at: nil, options: .interrupts)
        if !node.isPlaying { node.play() }
        idleStop?.cancel()
        let w = DispatchWorkItem { node.stop(); engine?.stop() }
        idleStop = w
        DispatchQueue.main.asyncAfter(deadline: .now() + keepAlive, execute: w)
        return cold
    }
}
