// Kadr — снимки экрана из строки меню. Точка входа и тестовые режимы командной строки:
//   Kadr --ocr <файл>                  — распознать текст и вывести в stdout
//   Kadr --render-test <in> <out.png>  — нарисовать набор пометок через экспорт редактора
//   Kadr --edit <файл>                 — открыть редактор на файле
//   Kadr --status                      — состояние разрешений, автозапуска и сочетаний
//   Kadr --shelf <файлы…> [--expand] [--actions] — открыть полку с файлами
//   Kadr --shake-test                  — проверка детектора встряхивания
//   Kadr --text-shelf [--pinned]       — показать текстовую полку (файл можно подменить KADR_TEXTSHELF_STORE)
//   KADR_PROFILE=<имя> Kadr            — отдельный тестовый профиль (свои настройки, данные, ключ, замок)
//   KADR_PROFILE=<имя> Kadr --profile-state       — сводка состояния профиля в JSON (только чтение)
//   KADR_PROFILE=<имя> Kadr --clip-test write|reload — проверка истории буфера без окон
//   KADR_PROFILE=<имя> Kadr --profile-reset       — удалить данные, ключ и настройки профиля
//   KADR_PROFILE=<имя> Kadr --clip-render out.png [--multi] — нарисовать окно истории в файл (без показа)
//   Kadr --onboarding [--onboarding-page <n>] — показать знакомство (с n-й страницы, с 1); KADR_NO_ONBOARDING=1 — не показывать само
import AppKit
import ServiceManagement
import SwiftUI

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

func renderTest(_ input: URL, _ output: URL) {
    guard let img = ImageFiles.load(input) else { fail("не читается: \(input.path)") }
    let r = Renderer(base: img.cg, pxPerPt: img.pxPerPt)
    let W = CGFloat(img.cg.width), H = CGFloat(img.cg.height)
    let k = img.pxPerPt
    let red = Palette.colors[0], blue = Palette.colors[4]
    var st = DocState(crop: r.fullRect)
    st.shapes = [
        Shape(tool: .arrow, points: [CGPoint(x: W * 0.10, y: H * 0.85), CGPoint(x: W * 0.40, y: H * 0.55)],
              color: red, width: Palette.widthsPt[1] * k),
        Shape(tool: .rect, points: [CGPoint(x: W * 0.05, y: H * 0.05), CGPoint(x: W * 0.45, y: H * 0.40)],
              color: red, width: Palette.widthsPt[1] * k),
        Shape(tool: .text, points: [CGPoint(x: W * 0.55, y: H * 0.10)], color: blue, width: 0,
              text: "Kadr: проверка", fontSize: Palette.fontPt[1] * k),
        Shape(tool: .mosaic, points: [CGPoint(x: W * 0.31, y: H * 0.41), CGPoint(x: W * 0.47, y: H * 0.50)],
              color: red, width: 0),
        Shape(tool: .badge, points: [CGPoint(x: W * 0.50, y: H * 0.50)], color: red, width: 0, number: 1,
              radius: (10 + Palette.widthsPt[1]) * k),
    ]
    guard let out = r.export(st) else { fail("экспорт не удался") }
    guard ImageFiles.write(out, to: output, pxPerPt: k) else { fail("не записан: \(output.path)") }
    print("\(out.width)x\(out.height) → \(output.path)")
}

let args = CommandLine.arguments
// До любых записей в настройки и папку данных: новая ли это установка (для знакомства).
Onboarding.captureInstallState()
Prefs.registerDefaults()

if let i = args.firstIndex(of: "--ocr") {
    guard i + 1 < args.count else { fail("использование: Kadr --ocr <файл | - (PNG из stdin)> [--rows | --no-rows]") }
    let rows = args.contains("--rows") || (!args.contains("--no-rows") && Prefs.keepTableRows)
    if args[i + 1] == "-" {
        // Режим отдельного процесса распознавания (OCR.recognizeIsolated): снимок приходит через stdin.
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("stdin: не картинка") }
        print(OCR.recognize(cg, keepRows: rows))
        exit(0)
    }
    guard let img = ImageFiles.load(URL(fileURLWithPath: args[i + 1])) else { fail("не читается: \(args[i + 1])") }
    print(OCR.recognize(img.cg, keepRows: rows))
    exit(0)
}

if let i = args.firstIndex(of: "--render-test") {
    guard i + 2 < args.count else { fail("использование: Kadr --render-test <in.png> <out.png>") }
    renderTest(URL(fileURLWithPath: args[i + 1]), URL(fileURLWithPath: args[i + 2]))
    exit(0)
}

if args.contains("--gesture-test") {
    exit(GestureSelfTest.run() ? 0 : 1)
}

if let i = args.firstIndex(of: "--gesture-sim") {
    // Нажатие «N пальцами» в запущенном тестовом профиле (настоящие касания не подделать).
    guard let p = Profile.name else { fail("нужен KADR_PROFILE=<имя>") }
    let n = i + 1 < args.count ? Int(args[i + 1]) ?? 3 : 3
    DistributedNotificationCenter.default().postNotificationName(Notification.Name("uz.lutfulla.kadr.gesture-sim"), object: "\(p):\(n)", userInfo: nil, deliverImmediately: true)
    exit(0)
}

if args.contains("--profile-state") {
    exit(ProfileState.dump())
}

if args.contains("--profile-reset") {
    // Удалить всё у тестового профиля: ключ в связке, папку данных, набор настроек. Настоящие данные недоступны.
    guard let p = Profile.name, let suite = Profile.suiteName else { fail("нужен KADR_PROFILE=<имя>") }
    ClipCrypto.deleteKey()
    try? FileManager.default.removeItem(at: Profile.dataDir)
    UserDefaults.standard.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/\(suite).plist"))
    print("профиль \(p) очищен")
    exit(0)
}

if let i = args.firstIndex(of: "--clip-test") {
    let phase = i + 1 < args.count ? args[i + 1] : "write"
    exit(ClipSelfTest.run(phase: phase) ? 0 : 1)
}

if args.contains("--status") {
    let login: String
    switch SMAppService.mainApp.status {
    case .enabled: login = "включён"
    case .requiresApproval: login = "ждёт разрешения"
    case .notRegistered: login = "не зарегистрирован"
    case .notFound: login = "не найден"
    @unknown default: login = "?"
    }
    if let p = Profile.name { print("Профиль: \(p) — \(Profile.dataDir.path)") }
    print("Запуск при входе: \(login)")
    print("Запись экрана: \(CGPreflightScreenCaptureAccess() ? "разрешена" : "нет разрешения")")
    print("Папка: \(Prefs.saveFolder.path), формат: \(Prefs.format)")
    for a in HotkeyAction.allCases { print("\(a.title): \(Prefs.hotkey(a)?.display ?? "нет")") }
    exit(0)
}

if args.contains("--split-test") {
    let sample = "Первая строка\r\nвторая строка\n\n  \nАбзац два, строка 1\nстрока 2\n\n\nТретий"
    print("по строкам:", TextShelfStore.split(sample, paragraphs: false).map { "[\($0)]" }.joined(separator: " "))
    print("по абзацам:", TextShelfStore.split(sample, paragraphs: true).map { "[\($0.replacingOccurrences(of: "\n", with: "⏎"))]" }.joined(separator: " "))
    exit(0)
}

if args.contains("--shake-test") {
    exit(ShakeSelfTest.run() ? 0 : 1)
}

if let i = args.firstIndex(of: "--drop-test") {
    // Разбор «бросков» через настоящий (частный) буфер обмена и очистка старых файлов полки.
    guard i + 1 < args.count, let img = ImageFiles.load(URL(fileURLWithPath: args[i + 1])),
          let png = ImageFiles.data(img.cg, type: .png, pxPerPt: img.pxPerPt) else { fail("использование: Kadr --drop-test <png>") }
    let pb = NSPasteboard(name: NSPasteboard.Name("uz.lutfulla.kadr.droptest"))
    func run(_ name: String, _ fill: () -> Void) {
        pb.clearContents()
        fill()
        var got: [ShelfItem] = []
        ShelfStore.receive(pb) { got += $0 }
        let desc = got.map { "\($0.kind == .file ? "файл" : "ссылка"):\($0.title)\($0.isTemp ? " (врем.)" : "")" }
        print("\(name): \(desc.isEmpty ? "ничего" : desc.joined(separator: ", "))")
    }
    run("файлы из Finder") { pb.writeObjects([URL(fileURLWithPath: args[i + 1]) as NSURL, URL(fileURLWithPath: "/tmp") as NSURL]) }
    run("картинка PNG") { pb.setData(png, forType: .png) }
    run("ссылка из браузера") {
        pb.writeObjects([URL(string: "https://example.com/page")! as NSURL])
        pb.setString("Пример страницы", forType: NSPasteboard.PasteboardType("public.url-name"))
    }
    run("текст") { pb.setString("Купить молоко\nи хлеб", forType: .string) }
    run("текст-ссылка") { pb.setString("https://example.com", forType: .string) }
    pb.releaseGlobally()
    let old = ShelfStore.newDir()
    try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 86400)], ofItemAtPath: old.path)
    let fresh = ShelfStore.newDir()
    ShelfStore.cleanup()
    print("очистка: старая папка \(FileManager.default.fileExists(atPath: old.path) ? "осталась" : "удалена"), свежая \(FileManager.default.fileExists(atPath: fresh.path) ? "на месте" : "удалена")")
    exit(0)
}

var shelfTest: (files: [URL], expand: Bool, actions: Bool)?
if let i = args.firstIndex(of: "--shelf") {
    let files = args[(i + 1)...].filter { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) }
    shelfTest = (files, args.contains("--expand"), args.contains("--actions"))
}

var editURL: URL?
if let i = args.firstIndex(of: "--edit") {
    guard i + 1 < args.count else { fail("использование: Kadr --edit <файл>") }
    editURL = URL(fileURLWithPath: args[i + 1])
}

let app = NSApplication.shared

// Замер скорости окна истории на синтетической истории (только тестовый профиль, без показа на экране).
if let i = args.firstIndex(of: "--clip-perf") {
    guard Profile.name != nil else { fail("нужен KADR_PROFILE=<имя>") }
    app.setActivationPolicy(.prohibited)
    let n = i + 1 < args.count ? Int(args[i + 1]) ?? 184 : 184
    let images = i + 2 < args.count ? Int(args[i + 2]) ?? 20 : 20
    let store = ClipStore.shared
    if store.items.count < n {
        let pb = NSPasteboard(name: NSPasteboard.Name("uz.lutfulla.kadr.clipperf"))
        let W = 2940, H = 1912
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for k in 0..<n {
            pb.clearContents()
            if k % max(1, n / max(1, images)) == 0 && store.items.filter({ $0.kind == .image }).count < images {
                let p = rep.bitmapData!
                for j in stride(from: 0, to: W * H * 4, by: 4) { p[j] = UInt8((j / 4 + k * 7) % 251); p[j + 1] = UInt8((j / 9) % 241); p[j + 2] = UInt8(k % 255); p[j + 3] = 255 }
                pb.setData(rep.representation(using: .png, properties: [:])!, forType: .png)
            } else {
                pb.setString("Запись номер \(k)\nвторая строка \(UUID().uuidString)", forType: .string)
            }
            ClipRecorder.record(from: pb, sourceID: "com.apple.TextEdit", sourceName: "TextEdit", store: store, skipPrivate: false)
        }
        pb.releaseGlobally()
    }
    store.flush()   // отложенная запись индекса — иначе свежая загрузка увидит старое число
    print("записей: \(store.items.count), картинок: \(store.items.filter { $0.kind == .image }.count)")
    for round in 1...3 {
        let t0 = Date()
        let fresh = ClipStore(dir: ClipStore.defaultDir)
        let tLoad = Date().timeIntervalSince(t0)
        let view = ClipHistoryPanel.shared.view
        let t1 = Date()
        view.prepareForShow()
        view.frame = NSRect(origin: .zero, size: ClipHistoryPanel.size)
        view.layoutSubtreeIfNeeded()
        view.table.layoutSubtreeIfNeeded()
        let rep2 = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep2)
        let tShow = Date().timeIntervalSince(t1)
        let t2 = Date()
        var deep = 0
        func walk(_ e: Any, _ d: Int) {
            guard d < 7 else { return }
            deep += 1
            let kids: [Any]? = (e as? NSView)?.accessibilityChildren() ?? (e as? NSAccessibilityElement)?.accessibilityChildren()
            for c in kids ?? [] { walk(c, d + 1) }
        }
        walk(view, 0)
        let tAX = Date().timeIntervalSince(t2)
        print(String(format: "круг %d: загрузка индекса %.0f мс (%d), показ+отрисовка %.0f мс, обход AX %.0f мс (%d элементов)", round, tLoad * 1000, fresh.items.count, tShow * 1000, tAX * 1000, deep))
    }
    exit(0)
}

// Окно настроек без показа на экране: рисуется в файл (только для тестового профиля, проверка перевода).
if let i = args.firstIndex(of: "--settings-render"), i + 1 < args.count {
    guard Profile.name != nil else { fail("нужен KADR_PROFILE=<имя>") }
    app.setActivationPolicy(.prohibited)
    if let a = ProcessInfo.processInfo.environment["KADR_APPEARANCE"] { app.appearance = NSAppearance(named: a == "light" ? .aqua : .darkAqua) }
    let recs = HotkeyAction.allCases.map { HotkeyRecorderModel(action: $0) }
    let host = NSHostingView(rootView: SettingsView(recorders: recs))
    let fit = host.fittingSize
    let size = NSSize(width: max(fit.width, 560), height: 2700)
    let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    win.contentView = host
    host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[i + 1]))
    print("настройки: \(Int(size.width))×\(Int(size.height)) → \(args[i + 1])")
    exit(0)
}

// Окно истории без показа на экране: раскладка рисуется в файл (только для тестового профиля).
if let i = args.firstIndex(of: "--clip-render"), i + 1 < args.count {
    guard Profile.name != nil else { fail("нужен KADR_PROFILE=<имя>") }
    app.setActivationPolicy(.prohibited)
    if let a = ProcessInfo.processInfo.environment["KADR_APPEARANCE"] { app.appearance = NSAppearance(named: a == "light" ? .aqua : .darkAqua) }
    let store = ClipStore.shared
    let pb = NSPasteboard(name: NSPasteboard.Name("uz.lutfulla.kadr.cliprender"))
    func put(_ src: String?, _ name: String?, _ fill: () -> Void) {
        pb.clearContents(); fill(); ClipRecorder.record(from: pb, sourceID: src, sourceName: name, store: store, skipPrivate: false)
    }
    put("com.apple.finder", "Finder") { pb.writeObjects([URL(fileURLWithPath: "/Applications/Kadr.app") as NSURL]) }
    let img = NSImage(size: NSSize(width: 320, height: 200), flipped: false) { r in
        NSColor.systemTeal.setFill(); r.fill(); NSColor.white.setFill(); NSRect(x: 40, y: 40, width: 120, height: 80).fill(); return true }
    put("com.apple.Preview", UILocale.isRussian ? "Просмотр" : "Preview") { pb.setData(NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!, forType: .png) }
    put("com.apple.Safari", "Safari") { pb.setString("https://example.com/katalog", forType: .string) }
    put("com.apple.Passwords", L("Passwords")) { pb.setString("secret-password", forType: .string); pb.setData(Data(), forType: .concealed) }
    put("com.apple.Safari", "Safari") { pb.setString("ivan@example.com", forType: .string) }
    put("com.apple.TextEdit", "TextEdit") { pb.setString(UILocale.isRussian ? "Встреча в 15:00\nобсудить запуск и цены" : "Meeting at 3 pm\ndiscuss launch and pricing", forType: .string) }
    pb.releaseGlobally()
    if let first = store.items.last { store.setPinned(first.id, true) }
    let view = ClipHistoryPanel.shared.view
    view.prepareForShow()
    if args.contains("--multi") {
        // Выделение логин → пароль, как для заполнения формы.
        let ids = view.shown.map { $0.id }
        view.table.selectRowIndexes([1], byExtendingSelection: false)
        view.table.selectRowIndexes([2], byExtendingSelection: true)
        _ = ids
    }
    view.frame = NSRect(origin: .zero, size: ClipHistoryPanel.size)
    view.layoutSubtreeIfNeeded()
    view.table.layoutSubtreeIfNeeded()
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    let out = NSImage(size: view.bounds.size)
    out.lockFocus()
    NSColor.windowBackgroundColor.setFill()
    NSBezierPath(roundedRect: NSRect(origin: .zero, size: view.bounds.size), xRadius: 18, yRadius: 18).fill()
    rep.draw(in: NSRect(origin: .zero, size: view.bounds.size))
    out.unlockFocus()
    let png = NSBitmapImageRep(data: out.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    try? png.write(to: URL(fileURLWithPath: args[i + 1]))
    print("порядок: \(view.selectedItems.map { $0.shownTitle(revealed: false) })")
    ClipCrypto.deleteKey()
    try? FileManager.default.removeItem(at: Profile.dataDir)
    exit(0)
}

// Вторую копию в обычном режиме не запускаем. Замок берёт только основной экземпляр,
// поэтому тестовые запуски (--edit, --shelf) ему не мешают. Замок снимается системой при выходе.
var mainLockFD: Int32 = -1
let textShelfTest = args.contains("--text-shelf")
if editURL == nil && shelfTest == nil && !textShelfTest {
    // У каждого профиля свой замок: профиль не мешает настоящему Kadr и наоборот.
    let lockPath = FileManager.default.temporaryDirectory.appendingPathComponent(Profile.lockName).path
    mainLockFD = open(lockPath, O_CREAT | O_RDWR, 0o600)
    if mainLockFD < 0 || flock(mainLockFD, LOCK_EX | LOCK_NB) != 0 {
        // Уже запущен: просим работающий экземпляр открыть настройки (если значок не виден, это единственный путь).
        DistributedNotificationCenter.default().postNotificationName(Notification.Name("uz.lutfulla.kadr.reopen"),
                                                                     object: Profile.name ?? "main", userInfo: nil, deliverImmediately: true)
        exit(0)
    }
}

let delegate = AppDelegate(editOnly: editURL, shelfTest: shelfTest)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
