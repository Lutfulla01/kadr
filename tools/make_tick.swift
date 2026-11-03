// Синтез звука копирования Kadr («тик»): короткий мягкий щелчок, рисуется кодом, чужих звуков нет.
// Рендерит три варианта, меряет спектр и огибающую, лучший пишет в CAF (48 кГц, моно, 16 бит).
// Использование: swift make_tick.swift <выход.caf> [папка для всех вариантов]
import AVFoundation
import Foundation

let rate = 48_000.0
let peakDB = -18.0

struct Variant {
    let name: String
    let about: String
    let duration: Double
    let render: (Int, Double) -> Double   // (номер отсчёта, время в с) -> отсчёт
}

// Плавная атака: приподнятый косинус (без щелчка в начале).
func attack(_ t: Double, _ a: Double) -> Double { t >= a ? 1 : 0.5 - 0.5 * cos(Double.pi * t / a) }
// Плавное затухание в конце файла.
func tailFade(_ t: Double, _ dur: Double, _ f: Double) -> Double { t <= dur - f ? 1 : max(0, 0.5 + 0.5 * cos(Double.pi * (t - (dur - f)) / f)) }

// Вариант B: щелчок через резонаторы (двухполюсный полосовой фильтр).
final class Resonator {
    var y1 = 0.0, y2 = 0.0
    let a1: Double, a2: Double, g: Double
    init(freq: Double, decay: Double) {               // decay — постоянная времени огибающей, с
        let r = exp(-1 / (decay * rate))
        a1 = 2 * r * cos(2 * Double.pi * freq / rate); a2 = -r * r; g = 1 - r
    }
    func step(_ x: Double) -> Double { let y = g * x + a1 * y1 + a2 * y2; y2 = y1; y1 = y; return y }
}
let resHi = Resonator(freq: 2_500, decay: 0.006), resLo = Resonator(freq: 800, decay: 0.008)
var lp = 0.0

let variants: [Variant] = [
    Variant(name: "A", about: "синус 2,4 кГц (лёгкий спад до 2,3 кГц) + тело 750 Гц, атака 1,5 мс, экспонента 6/9 мс",
            duration: 0.036) { _, t in
        let f0 = 2_400.0, drop = 0.04, tau = 0.006
        // Фаза тона с небольшим спадом частоты: интеграл f(t) = f0 * (1 - drop * (1 - e^(-t/0.01))).
        let phase = 2 * Double.pi * f0 * (t - drop * (t - 0.01 * (1 - exp(-t / 0.01))))
        let hi = sin(phase) * exp(-t / tau)
        let lo = 0.32 * sin(2 * Double.pi * 750 * t) * exp(-t / 0.009)
        return (hi + lo) * attack(t, 0.0015) * tailFade(t, 0.036, 0.006)
    },
    Variant(name: "B", about: "импульс 0,3 мс через резонаторы 2,5 кГц и 800 Гц, сглаживание 6 кГц",
            duration: 0.040) { n, t in
        let x = n < Int(0.0003 * rate) ? 1.0 : 0.0
        let y = resHi.step(x) + 0.5 * resLo.step(x)
        lp += (1 - exp(-2 * Double.pi * 6_000 / rate)) * (y - lp)
        return lp * tailFade(t, 0.040, 0.006)
    },
    Variant(name: "C", about: "треугольник 2 кГц + тело 700 Гц, атака 1 мс, экспонента 7 мс",
            duration: 0.040) { _, t in
        let p = (2_000 * t).truncatingRemainder(dividingBy: 1)
        let tri = 4 * abs(p - 0.5) - 1
        let lo = 0.3 * sin(2 * Double.pi * 700 * t) * exp(-t / 0.01)
        return (tri * exp(-t / 0.007) + lo) * attack(t, 0.001) * tailFade(t, 0.040, 0.006)
    },
]

struct Report { let name: String; let samples: [Double]; let peak: Double; let above8k: Double; let centroid: Double; let rises: Int; let t60: Double }

func analyze(_ name: String, _ s: [Double]) -> Report {
    let peak = s.map { abs($0) }.max() ?? 0
    // Спектр: ДПФ окна Ханна на 4096 точек (звук короче — дополняется нулями).
    let n = 4096
    var x = [Double](repeating: 0, count: n)
    for i in 0..<min(n, s.count) { x[i] = s[i] * (0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(min(n, s.count) - 1))) }
    var total = 0.0, hi = 0.0, cen = 0.0
    for k in 1..<(n / 2) {
        var re = 0.0, im = 0.0
        let w = 2 * Double.pi * Double(k) / Double(n)
        for i in 0..<min(n, s.count) { re += x[i] * cos(w * Double(i)); im -= x[i] * sin(w * Double(i)) }
        let e = re * re + im * im, f = Double(k) * rate / Double(n)
        total += e; cen += e * f
        if f > 8_000 { hi += e }
    }
    // Огибающая: RMS в окне 2 мс с шагом 1 мс. После пика считаем подъёмы больше 1 дБ (гладкость спада).
    let win = Int(0.002 * rate), hop = Int(0.001 * rate)
    var env: [Double] = []
    var i = 0
    while i + win <= s.count { env.append(sqrt(s[i..<(i + win)].map { $0 * $0 }.reduce(0, +) / Double(win))); i += hop }
    let top = env.firstIndex(of: env.max() ?? 0) ?? 0
    var rises = 0
    for j in (top + 1)..<env.count where env[j] > 1e-9 && env[j - 1] > 1e-9 && 20 * log10(env[j] / env[j - 1]) > 1 { rises += 1 }
    let t60 = Double((env.indices.last { env[$0] > (env.max() ?? 0) * 0.001 }) ?? 0) / 1000
    return Report(name: name, samples: s, peak: peak, above8k: hi / max(total, 1e-12), centroid: cen / max(total, 1e-12), rises: rises, t60: t60)
}

func render(_ v: Variant) -> [Double] {
    let count = Int(v.duration * rate)
    var s = (0..<count).map { v.render($0, Double($0) / rate) }
    let m = s.map { abs($0) }.max() ?? 1
    let target = pow(10, peakDB / 20)
    s = s.map { $0 / m * target }
    return s
}

func write(_ s: [Double], to url: URL) throws {
    try? FileManager.default.removeItem(at: url)
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                                   AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(s.count))!
    buf.frameLength = AVAudioFrameCount(s.count)
    for (i, v) in s.enumerated() { buf.floatChannelData![0][i] = Float(v) }
    try file.write(from: buf)
}

let args = CommandLine.arguments
guard args.count >= 2 else { print("использование: swift make_tick.swift <выход.caf> [папка вариантов]"); exit(1) }
let out = URL(fileURLWithPath: args[1])
let dir = args.count > 2 ? URL(fileURLWithPath: args[2]) : nil
if let dir { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }

var reports: [Report] = []
for v in variants {
    let r = analyze(v.name, render(v))
    reports.append(r)
    print(String(format: "%@: %2.0f мс, пик %.1f дБFS, выше 8 кГц %.3f%%, центр спектра %.0f Гц, подъёмов огибающей %d, до −60 дБ %.0f мс — %@",
                 v.name, v.duration * 1000, 20 * log10(r.peak), r.above8k * 100, r.centroid, r.rises, r.t60 * 1000, v.about))
    if let dir { try write(r.samples, to: dir.appendingPathComponent("tick-\(v.name).caf")) }
}
// Выбор: без энергии выше 8 кГц (< 0,1 %), без подъёмов огибающей, центр спектра 1,5–3 кГц; из подходящих — меньше всего ВЧ.
let fit = reports.filter { $0.above8k < 0.001 && $0.rises == 0 && (1_500...3_000).contains($0.centroid) }
guard let best = fit.min(by: { $0.above8k < $1.above8k }) else { print("ни один вариант не прошёл критерии"); exit(1) }
try write(best.samples, to: out)
print("выбран \(best.name) → \(out.path)")
