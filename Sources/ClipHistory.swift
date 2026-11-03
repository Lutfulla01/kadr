// Kadr — «История буфера»: локальная зашифрованная история копирований (текст, ссылки, картинки, файлы).
// Ничего не уходит в сеть. Хранилище зашифровано AES-GCM, ключ лежит в связке ключей входа.
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CryptoKit
import Quartz
import Security

extension NSPasteboard.PasteboardType {
    /// Метка собственных служебных записей Kadr — история их пропускает всегда.
    static let kadrInternal = NSPasteboard.PasteboardType("uz.lutfulla.kadr.internal")
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
}

struct ClipItem: Codable, Equatable {
    enum Kind: String, Codable { case text, link, image, file }
    var id = UUID()
    var kind: Kind
    var date = Date()
    var text = ""            // текст, адрес ссылки или пути файлов через перевод строки
    var digest = ""          // отпечаток картинки (для повторов)
    var w = 0, h = 0
    var hasRTF = false
    var hasImage = false     // есть исходная картинка (≤ 20 МБ)
    var hasThumb = false
    var pinned = false
    var concealed = false    // скопировано как скрытое (пароль)
    var bytes = 0
    var sourceID: String?
    var sourceName: String?

    var files: [URL] { kind == .file ? text.split(separator: "\n").map { URL(fileURLWithPath: String($0)) } : [] }

    var title: String {
        switch kind {
        case .file:
            let f = files
            return f.count == 1 ? f[0].lastPathComponent : "\(f.count) " + russianPlural(f.count, "файл", "файла", "файлов")
        case .image: return w > 0 ? "Изображение \(w)×\(h)" : "Изображение"
        case .link: return URL(string: text)?.host ?? text
        case .text:
            return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? text
        }
    }

    var subtitle: String {
        switch kind {
        case .file: return files.count == 1 ? files[0].deletingLastPathComponent().path : files.map { $0.lastPathComponent }.joined(separator: ", ")
        case .image: return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        case .link: return text
        case .text:
            let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return lines.count > 1 ? lines.dropFirst().joined(separator: " · ") : "\(text.count) " + russianPlural(text.count, "символ", "символа", "символов")
        }
    }

    /// Заголовок для списка и проверок: скрытые записи — точками.
    func shownTitle(revealed: Bool) -> String { concealed && !revealed ? "••••••••" : title }
    func shownSubtitle(revealed: Bool) -> String {
        concealed && !revealed ? "Скрыто" + (sourceName.map { " · \($0)" } ?? "") : subtitle
    }

    var plainText: String { kind == .image ? title : text }
}

// MARK: - Шифрование

enum ClipCrypto {
    static let service = "uz.lutfulla.kadr.clipboard"

    enum Lookup { case found(SymmetricKey), notFound, unavailable(OSStatus) }

    static func loadKey() -> Lookup {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Profile.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,   // никаких окон с паролем
        ]
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecSuccess, let d = out as? Data, d.count == 32 { return .found(SymmetricKey(data: d)) }
        if st == errSecItemNotFound { return .notFound }
        return .unavailable(st)
    }

    static func createKey() -> SymmetricKey? {
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        var add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Profile.keychainAccount,
            kSecAttrLabel as String: "Kadr — ключ истории буфера",
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var st = SecItemAdd(add as CFDictionary, nil)
        if st == errSecParam {
            add.removeValue(forKey: kSecAttrAccessible as String)
            st = SecItemAdd(add as CFDictionary, nil)
        }
        return st == errSecSuccess ? key : nil
    }

    @discardableResult
    static func deleteKey() -> OSStatus {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: Profile.keychainAccount,
                       kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail] as CFDictionary)
    }

    static func seal(_ d: Data, _ k: SymmetricKey) -> Data? { try? AES.GCM.seal(d, using: k).combined }
    static func open(_ d: Data, _ k: SymmetricKey) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: d) else { return nil }
        return try? AES.GCM.open(box, using: k)
    }
}

// MARK: - Хранилище

final class ClipStore {
    static let shared: ClipStore = { let s = ClipStore(dir: ClipStore.defaultDir); s.debounceSave = true; return s }()
    /// Живой экземпляр пишет индекс не чаще раза в 0,3 с: при серии копирований
    /// главный поток не шифрует весь индекс на каждую запись.
    var debounceSave = false
    private var saveScheduled = false

    static var defaultDir: URL {
        if let p = ProcessInfo.processInfo.environment["KADR_CLIP_DIR"], !p.isEmpty { return URL(fileURLWithPath: p) }
        return Profile.dataDir.appendingPathComponent("Clipboard", isDirectory: true)
    }

    enum KeyState: String { case ok = "есть", created = "создан", restarted = "не найден — начата новая история", unavailable = "недоступен — история только в памяти" }

    let dir: URL
    let readOnly: Bool
    private var key: SymmetricKey?
    private(set) var keyState: KeyState = .ok
    private(set) var items: [ClipItem] = []
    var maxItems = 1000      // 0 — без ограничения
    var maxDays = 0          // 0 — не удалять по возрасту
    var onChange: (() -> Void)?
    private var thumbCache: [UUID: NSImage] = [:]
    /// Если ключа нет — данные живут только в памяти до выхода.
    private var memoryBlobs: [String: Data] = [:]

    init(dir: URL, readOnly: Bool = false) {
        self.dir = dir
        self.readOnly = readOnly
        let fm = FileManager.default
        let index = dir.appendingPathComponent("index.kadr")
        let hadIndex = fm.fileExists(atPath: index.path)
        switch ClipCrypto.loadKey() {
        case .found(let k): key = k
        case .notFound:
            if readOnly { keyState = .unavailable }
            else if let k = ClipCrypto.createKey() {
                key = k
                keyState = hadIndex ? .restarted : .created
                if hadIndex { moveAside() }
            } else { keyState = .unavailable }
        case .unavailable: keyState = .unavailable
        }
        if !readOnly {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
        guard let key, let enc = try? Data(contentsOf: index) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        if let plain = ClipCrypto.open(enc, key), let list = try? dec.decode([ClipItem].self, from: plain) {
            items = list
        } else if !readOnly {
            // Ключ не подходит к старой истории — начинаем новую, без падения.
            moveAside()
            keyState = .restarted
        }
    }

    var persistent: Bool { key != nil && !readOnly }
    private var indexURL: URL { dir.appendingPathComponent("index.kadr") }
    func blob(_ id: UUID, _ ext: String) -> URL { dir.appendingPathComponent("\(id.uuidString).\(ext).kadr") }

    private func moveAside() {
        let fm = FileManager.default
        let old = dir.deletingLastPathComponent().appendingPathComponent(dir.lastPathComponent + ".old")
        try? fm.removeItem(at: old)
        try? fm.moveItem(at: dir, to: old)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    private func writeSealed(_ data: Data, to url: URL) {
        guard persistent, let key, let sealed = ClipCrypto.seal(data, key) else { return }
        try? sealed.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func readBlob(_ id: UUID, _ ext: String) -> Data? {
        if let mem = memoryBlobs["\(id.uuidString).\(ext)"] { return mem }
        guard let key, let d = try? Data(contentsOf: blob(id, ext)) else { return nil }
        return ClipCrypto.open(d, key)
    }

    private func putBlob(_ data: Data, _ id: UUID, _ ext: String) {
        if persistent { writeSealed(data, to: blob(id, ext)) } else { memoryBlobs["\(id.uuidString).\(ext)"] = data }
    }

    func save() {
        if persistent {
            if debounceSave {
                if !saveScheduled {
                    saveScheduled = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.flush() }
                }
            } else {
                writeIndex()
            }
        }
        onChange?()
    }

    /// Дописать отложенный индекс сразу (выход из программы).
    func flush() {
        guard saveScheduled else { return }
        saveScheduled = false
        writeIndex()
    }

    private func writeIndex() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        if let d = try? enc.encode(items) { writeSealed(d, to: indexURL) }
    }

    func add(_ item: ClipItem, rtf: Data? = nil, png: Data? = nil, thumb: Data? = nil) {
        // Повтор — поднимаем существующую запись наверх.
        if let i = items.firstIndex(where: { $0.kind == item.kind && $0.text == item.text && $0.digest == item.digest }) {
            var old = items.remove(at: i)
            old.date = item.date
            old.sourceID = item.sourceID
            old.sourceName = item.sourceName
            old.concealed = old.concealed || item.concealed
            items.insert(old, at: 0)
            save()
            return
        }
        if let rtf { putBlob(rtf, item.id, "rtf") }
        if let png { putBlob(png, item.id, "png") }
        if let thumb { putBlob(thumb, item.id, "thumb") }
        items.insert(item, at: 0)
        trim()
        save()
    }

    func touch(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        var it = items.remove(at: i)
        it.date = Date()
        items.insert(it, at: 0)
        save()
    }

    func setPinned(_ id: UUID, _ v: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].pinned = v
        save()
    }

    func remove(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        deleteBlobs(items[i])
        items.remove(at: i)
        save()
    }

    func clear(keepPinned: Bool) {
        let gone = items.filter { !(keepPinned && $0.pinned) }
        gone.forEach(deleteBlobs)
        items.removeAll { !(keepPinned && $0.pinned) }
        save()
    }

    private func deleteBlobs(_ it: ClipItem) {
        thumbCache[it.id] = nil
        for ext in ["rtf", "png", "thumb"] {
            memoryBlobs["\(it.id.uuidString).\(ext)"] = nil
            try? FileManager.default.removeItem(at: blob(it.id, ext))
        }
    }

    /// Ограничения: число записей (0 — без ограничения) и, по желанию, возраст. Закреплённые не удаляются никогда.
    func trim() {
        let border = Date().addingTimeInterval(-Double(maxDays) * 86400)
        var keep: [ClipItem] = []
        var count = 0
        for it in items {
            if it.pinned { keep.append(it); continue }
            if (maxDays > 0 && it.date < border) || (maxItems > 0 && count >= maxItems) { deleteBlobs(it); continue }
            count += 1
            keep.append(it)
        }
        items = keep
    }

    func applyLimitsFromPrefs() {
        maxItems = max(0, Prefs.d.integer(forKey: "clipMaxItems"))
        maxDays = max(0, Prefs.d.integer(forKey: "clipMaxDays"))
        let before = items.count
        trim()
        if items.count != before { save() }
    }

    func thumbnail(_ it: ClipItem) -> NSImage? {
        guard it.hasThumb else { return nil }
        if let c = thumbCache[it.id] { return c }
        let img = readBlob(it.id, "thumb").flatMap { NSImage(data: $0) }
        thumbCache[it.id] = img
        return img
    }

    /// Миниатюра без задержки списка: из кэша сразу, иначе расшифровка и декодирование в фоне.
    func cachedThumbnail(_ it: ClipItem) -> NSImage? { thumbCache[it.id] }

    private static let thumbQueue = DispatchQueue(label: "uz.lutfulla.kadr.clip-thumbs", qos: .userInitiated)
    private var thumbLoading: Set<UUID> = []

    func loadThumbnail(_ it: ClipItem, done: @escaping (NSImage?) -> Void) {
        guard it.hasThumb, let key else { done(nil); return }
        if let c = thumbCache[it.id] { done(c); return }
        guard !thumbLoading.contains(it.id) else { return }
        thumbLoading.insert(it.id)
        let url = blob(it.id, "thumb")
        let mem = memoryBlobs["\(it.id.uuidString).thumb"]
        ClipStore.thumbQueue.async { [weak self] in
            var img: NSImage?
            if let d = mem ?? (try? Data(contentsOf: url)).flatMap({ mem == nil ? ClipCrypto.open($0, key) : $0 }),
               let src = CGImageSourceCreateWithData(d as CFData, nil),
               let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                    kCGImageSourceThumbnailMaxPixelSize: 96,
                                                                    kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
                img = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
            }
            DispatchQueue.main.async {
                self?.thumbLoading.remove(it.id)
                self?.thumbCache[it.id] = img
                done(img)
            }
        }
    }

    func imageData(_ it: ClipItem) -> Data? { readBlob(it.id, it.hasImage ? "png" : "thumb") }

    /// Содержимое записи в буфер (без очистки и служебной метки — их ставит вызывающий).
    func fill(_ it: ClipItem, plain: Bool, _ pb: NSPasteboard) {
        switch it.kind {
        case .text:
            pb.setString(it.text, forType: .string)
            if !plain, it.hasRTF, let rtf = readBlob(it.id, "rtf") { pb.setData(rtf, forType: .rtf) }
        case .link:
            pb.setString(it.text, forType: .string)
            if !plain { pb.setString(it.text, forType: .URL) }
        case .image:
            if plain { pb.setString(it.title, forType: .string) }
            else if let d = imageData(it) {
                pb.setData(d, forType: .png)
                if let tiff = NSImage(data: d)?.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
            }
        case .file:
            if plain { pb.setString(it.text, forType: .string) }
            else if let first = it.files.first {
                pb.setString(first.absoluteString, forType: .fileURL)
                pb.setString(it.text, forType: .string)
            }
        }
        if it.concealed { pb.setData(Data(), forType: .concealed) }
    }

    /// Кладёт записи в буфер обмена как одно копирование (помечая служебными).
    func write(_ list: [ClipItem], plain: Bool, to pb: NSPasteboard = .general) {
        pb.clearContents()
        if list.count == 1, let it = list.first {
            if it.kind == .file && !plain { pb.writeObjects(it.files.map { $0 as NSURL }) }
            fill(it, plain: plain, pb)
        } else {
            pb.setString(list.map { $0.plainText }.joined(separator: "\n"), forType: .string)
            if list.contains(where: { $0.concealed }) { pb.setData(Data(), forType: .concealed) }
        }
        pb.setData(Data(), forType: .kadrInternal)
    }

    /// Расшифрованная копия для Quick Look и перетаскивания картинок (временная папка, чистится при показе окна).
    static let viewDir = FileManager.default.temporaryDirectory.appendingPathComponent("KadrClipView", isDirectory: true)

    static func clearViewDir() { try? FileManager.default.removeItem(at: viewDir) }

    func previewURL(_ it: ClipItem) -> URL? {
        let fm = FileManager.default
        try? fm.createDirectory(at: ClipStore.viewDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        switch it.kind {
        case .file: return it.files.first
        case .image:
            guard let d = imageData(it) else { return nil }
            let u = ClipStore.viewDir.appendingPathComponent("Изображение \(ShelfStore.stamp()).png")
            try? d.write(to: u)
            return u
        case .text, .link:
            let u = ClipStore.viewDir.appendingPathComponent("Текст.txt")
            try? it.text.write(to: u, atomically: true, encoding: .utf8)
            return u
        }
    }
}

// MARK: - Запись

enum ClipRecorder {
    /// Пропускаются только при включённой настройке «не записывать пароли».
    static let privateTypes: [NSPasteboard.PasteboardType] = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword",
    ].map { NSPasteboard.PasteboardType($0) }
    static let concealedTypes: [NSPasteboard.PasteboardType] = [.concealed, NSPasteboard.PasteboardType("com.agilebits.onepassword")]

    static let defaultIgnore = ["com.apple.keychainaccess", "com.apple.Passwords", "com.1password.1password",
                                "com.agilebits.onepassword7", "com.bitwarden.desktop", "org.keepassxc.keepassxc"]

    static var ignoreList: [String] {
        (Prefs.d.string(forKey: "clipIgnore") ?? defaultIgnore.joined(separator: "\n"))
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Содержимое буфера, прочитанное на главном потоке (дальше разбор можно вести в фоне).
    struct Snapshot {
        var types: [NSPasteboard.PasteboardType]
        var fileURLs: [URL]
        var string: String?
        var png: Data?
        var tiff: Data?
        var rtf: Data?
        var otherURL: URL?
    }

    static func snapshot(_ pb: NSPasteboard) -> Snapshot {
        let types = pb.types ?? []
        let files = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let hasImage = types.contains(.png) || types.contains(.tiff)
        let skip = types.contains(.kadrInternal)
        return Snapshot(types: types, fileURLs: files,
                        string: skip ? nil : pb.string(forType: .string),
                        png: skip || !files.isEmpty ? nil : pb.data(forType: .png),
                        tiff: skip || !files.isEmpty || !hasImage || types.contains(.png) ? nil : pb.data(forType: .tiff),
                        rtf: skip ? nil : pb.data(forType: .rtf),
                        otherURL: skip ? nil : (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.first(where: { !$0.isFileURL }))
    }

    /// Готовая к сохранению запись (тяжёлая работа — перекодирование, миниатюра — уже сделана).
    struct Prepared { var item: ClipItem; var rtf: Data?; var png: Data?; var thumb: Data? }

    private static let work = DispatchQueue(label: "uz.lutfulla.kadr.clip-record", qos: .utility)

    /// Для слежения за буфером: читает буфер сейчас, разбирает в фоне, сохраняет на главном потоке.
    static func recordAsync(from pb: NSPasteboard, sourceID: String?, sourceName: String?, store: ClipStore) {
        let snap = snapshot(pb)
        let skipPrivate = Prefs.clipSkipPrivate
        let ignore = ignoreList
        work.async {
            guard case .success(let p) = prepare(snap, sourceID: sourceID, sourceName: sourceName, skipPrivate: skipPrivate, ignore: ignore) else { return }
            DispatchQueue.main.async { store.add(p.item, rtf: p.rtf, png: p.png, thumb: p.thumb) }
        }
    }

    /// Разбирает буфер и сохраняет запись сразу. Возвращает причину пропуска (для проверок) или nil.
    @discardableResult
    static func record(from pb: NSPasteboard, sourceID: String?, sourceName: String?, store: ClipStore,
                       skipPrivate: Bool = Prefs.clipSkipPrivate) -> String? {
        switch prepare(snapshot(pb), sourceID: sourceID, sourceName: sourceName, skipPrivate: skipPrivate, ignore: ignoreList) {
        case .success(let p): store.add(p.item, rtf: p.rtf, png: p.png, thumb: p.thumb); return nil
        case .failure(let r): return r.reason
        }
    }

    struct Skip: Error { let reason: String }

    static func prepare(_ s: Snapshot, sourceID: String?, sourceName: String?, skipPrivate: Bool, ignore: [String]) -> Result<Prepared, Skip> {
        let types = s.types
        if types.isEmpty { return .failure(Skip(reason: "пусто")) }
        if types.contains(.kadrInternal) { return .failure(Skip(reason: "служебная запись Kadr")) }
        if skipPrivate {
            if types.contains(where: { privateTypes.contains($0) }) { return .failure(Skip(reason: "скрытая запись (настройка)")) }
            if let sid = sourceID, ignore.contains(where: { $0.caseInsensitiveCompare(sid) == .orderedSame }) {
                return .failure(Skip(reason: "программа в списке исключений (настройка)"))
            }
        }
        var item = ClipItem(kind: .text)
        item.sourceID = sourceID
        item.sourceName = sourceName
        item.concealed = types.contains(where: { concealedTypes.contains($0) })

        if !s.fileURLs.isEmpty {
            item.kind = .file
            item.text = s.fileURLs.map { $0.path }.joined(separator: "\n")
            item.bytes = item.text.utf8.count
            return .success(Prepared(item: item))
        }
        let str = s.string
        let hasImage = types.contains(.png) || types.contains(.tiff)
        if hasImage, str == nil || types.contains(.png) {
            let png = s.png ?? s.tiff.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
            if let png, let src = CGImageSourceCreateWithData(png as CFData, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                item.kind = .image
                item.bytes = png.count
                item.w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
                item.h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
                item.digest = SHA256.hash(data: png).prefix(12).map { String(format: "%02x", $0) }.joined()
                let thumb = makeThumb(png)
                item.hasThumb = thumb != nil
                item.hasImage = png.count <= 20_000_000
                return .success(Prepared(item: item, png: item.hasImage ? png : nil, thumb: thumb))
            }
        }
        if let text = str, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !item.concealed, !t.contains(where: { $0.isWhitespace }), let u = URL(string: t),
               let sch = u.scheme?.lowercased(), ["http", "https"].contains(sch), u.host != nil {
                item.kind = .link
                item.text = t
                item.bytes = t.utf8.count
                return .success(Prepared(item: item))
            }
            item.kind = .text
            item.text = text
            let rtf = item.concealed ? nil : s.rtf
            item.hasRTF = rtf != nil
            item.bytes = text.utf8.count + (rtf?.count ?? 0)
            return .success(Prepared(item: item, rtf: rtf))
        }
        if let u = s.otherURL {
            item.kind = .link
            item.text = u.absoluteString
            return .success(Prepared(item: item))
        }
        return .failure(Skip(reason: "неподдерживаемый тип"))
    }

    static func makeThumb(_ data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                   kCGImageSourceThumbnailMaxPixelSize: 160,
                                                                   kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}

/// Следит за буфером обмена: 0,25 с в покое, 0,05 с во время серий (разрешений не требует).
final class ClipMonitor {
    static let shared = ClipMonitor()
    private var timer: Timer?
    private var lastCount = NSPasteboard.general.changeCount

    var paused: Bool {
        get { Prefs.d.bool(forKey: "clipPaused") }
        set { Prefs.d.set(newValue, forKey: "clipPaused") }
    }

    /// Обычно — раз в 0,25 с; несколько секунд после изменения — каждые 0,05 с (быстрые серии копирований).
    static let idleInterval = 0.25, fastInterval = 0.05, fastWindow = 4.0
    private var fastUntil = Date.distantPast
    private var emptySince: Date?
    private var interval = 0.0

    func start() {
        ClipStore.shared.applyLimitsFromPrefs()
        lastCount = NSPasteboard.general.changeCount
        schedule(ClipMonitor.idleInterval)
    }

    private func schedule(_ i: Double) {
        guard i != interval else { return }
        interval = i
        timer?.invalidate()
        let t = Timer(timeInterval: i, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = i * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let pb = NSPasteboard.general
        let c = pb.changeCount
        if c != lastCount {
            // Номер изменения растёт уже на clearContents, а данные программа кладёт чуть позже
            // (RTF, картинки). Пустой буфер не считаем прочитанным — перечитываем до 1 с.
            if (pb.types ?? []).isEmpty {
                if emptySince == nil { emptySince = Date() }
                if Date().timeIntervalSince(emptySince!) < 1.0 {
                    fastUntil = Date().addingTimeInterval(ClipMonitor.fastWindow)
                    schedule(ClipMonitor.fastInterval)
                    return
                }
            }
            emptySince = nil
            lastCount = c
            fastUntil = Date().addingTimeInterval(ClipMonitor.fastWindow)
            schedule(ClipMonitor.fastInterval)
            guard !paused else { return }
            let front = NSWorkspace.shared.frontmostApplication
            ClipRecorder.recordAsync(from: pb, sourceID: front?.bundleIdentifier, sourceName: front?.localizedName, store: ClipStore.shared)
        } else if interval != ClipMonitor.idleInterval && Date() > fastUntil {
            schedule(ClipMonitor.idleInterval)
        }
    }
}

// MARK: - Окно истории

final class ClipHistoryPanel: NSPanel, NSWindowDelegate {
    static let shared = ClipHistoryPanel()
    /// Панель у края экрана (создаётся при первом показе).
    static var edgeIfCreated: ClipHistoryPanel?
    static var edge: ClipHistoryPanel {
        if let e = edgeIfCreated { return e }
        let e = ClipHistoryPanel(edge: true); edgeIfCreated = e; return e
    }
    private(set) var view: ClipHistoryView!
    var previousApp: NSRunningApplication?
    /// «Не прятать после вставки» (замок в нижней панели).
    var keepOpen = false
    private var keyMonitor: Any?
    let isEdge: Bool
    var axPrefix: String { isEdge ? "kadr.clipEdge" : "kadr.clipHistory" }

    static let size = NSSize(width: 460, height: 520)
    static let edgeWidth: CGFloat = 380

    private init(edge: Bool = false) {
        isEdge = edge
        super.init(contentRect: NSRect(origin: .zero, size: ClipHistoryPanel.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isMovableByWindowBackground = !edge
        isReleasedWhenClosed = false
        isRestorable = false
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        delegate = self
        title = edge ? "История буфера у края" : "История буфера"
        setAccessibilityTitle(title)
        setAccessibilityIdentifier(axPrefix)
        view = ClipHistoryView(panel: self, store: ClipStore.shared)
        contentView = view
        ClipStore.shared.onChange = {
            for p in [ClipHistoryPanel.shared, ClipHistoryPanel.edgeIfCreated].compactMap({ $0 }) where p.isVisible { p.view.reload() }
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { hide() }

    func toggle() { isVisible ? hide() : show() }

    // MARK: Панель у края экрана

    /// Целевая рамка панели у края (по ней считаем «курсор ушёл»).
    private(set) var edgeFrame = NSRect.zero
    private var edgeShownAt = NSPoint.zero
    private var leaveTimer: Timer?
    private var leaveSince: CFTimeInterval?
    private(set) var edgeOpenedAt: CFTimeInterval = 0
    /// Открыта жестом: не прячется, когда курсор ушёл или щёлкнули мимо (можно щёлкнуть в поле логина и вставить).
    private(set) var sticky = false

    /// Выезжает у края экрана. Фокус клавиатуры остаётся в текущей программе, пока
    /// в панели не щёлкнули или не повели в ней мышью (тогда можно печатать в поиске).
    func showAtEdge(screen: NSScreen, right: Bool, sticky: Bool = false) {
        let t0 = CACurrentMediaTime()
        edgeOpenedAt = t0
        self.sticky = sticky
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier { previousApp = front }
        let fr = screen.frame, vis = screen.visibleFrame
        let w = ClipHistoryPanel.edgeWidth
        let target = NSRect(x: right ? fr.maxX - w : fr.minX, y: vis.minY + 6, width: w, height: vis.height - 12)
        edgeFrame = target
        setFrame(target, display: false)
        view.prepareForShow()
        alphaValue = 1
        orderFrontRegardless()
        // Без своей анимации: сдвиг слоя оставлял окно «прозрачным» для щелчков (WindowServer),
        // анимация рамки блокировала главный поток. Появление — системное, у панели оно короткое.
        edgeShownAt = NSEvent.mouseLocation
        leaveSince = nil
        installKeyMonitor()
        startEdgeTimer()
        let t1 = CACurrentMediaTime()
        DispatchQueue.main.async {
            KadrLog.write(String(format: "панель у края: %d записей, показ %.0f мс, до первого кадра %.0f мс",
                                 ClipStore.shared.items.count, (t1 - t0) * 1000, (CACurrentMediaTime() - t0) * 1000))
        }
    }

    func startEdgeTimer() {
        installKeyMonitor()
        leaveTimer?.invalidate()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.edgeTick() }
        RunLoop.main.add(t, forMode: .common)
        leaveTimer = t
    }

    private func edgeTick() {
        guard isVisible else { leaveTimer?.invalidate(); leaveTimer = nil; return }
        // Перетаскивание строки наружу или открытое меню — не прячемся.
        if NSEvent.pressedMouseButtons != 0 || view.menuOpen { leaveSince = nil; return }
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { leaveSince = nil; return }
        let p = NSEvent.mouseLocation
        if sticky {
            if edgeFrame.contains(p), !isKeyWindow, hypot(p.x - edgeShownAt.x, p.y - edgeShownAt.y) > 24 { makeKey(); view.focusSearch() }
            return
        }
        if edgeFrame.insetBy(dx: -4, dy: -4).contains(p) {
            leaveSince = nil
            // Повёл мышью внутри панели — значит, работает с ней: принимаем клавиатуру.
            if !isKeyWindow, hypot(p.x - edgeShownAt.x, p.y - edgeShownAt.y) > 24 { makeKey(); view.focusSearch() }
            return
        }
        let now = CACurrentMediaTime()
        if let since = leaveSince {
            if now - since >= 0.3 { KadrLog.write("панель у края: курсор ушёл — прячу"); hide(returnFocus: false) }
        } else {
            leaveSince = now
        }
    }

    override func sendEvent(_ event: NSEvent) {
        if isEdge, ProcessInfo.processInfo.environment["KADR_EDGE_DEBUG"] == "1" { KadrLog.write("панель у края: событие \(event.type.rawValue) key=\(isKeyWindow)") }
        if isEdge, event.type == .leftMouseDown || event.type == .rightMouseDown, !isKeyWindow { makeKey() }
        super.sendEvent(event)
    }

    private func installKeyMonitor() {
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, e.window === self, self.view.handleKey(e) else { return e }
                return nil
            }
        }
    }

    func show() {
        let t0 = CACurrentMediaTime()
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier { previousApp = front }
        ClipStore.clearViewDir()
        let c = NSEvent.mouseLocation
        var r = NSRect(x: c.x - frame.width / 2, y: c.y - frame.height - 12, width: frame.width, height: frame.height)
        let screen = NSScreen.screens.first { NSMouseInRect(c, $0.frame, false) } ?? NSScreen.main
        if let vis = screen?.visibleFrame {
            if r.minY < vis.minY { r.origin.y = c.y + 12 }
            r.origin.x = max(vis.minX + 6, min(vis.maxX - r.width - 6, r.origin.x))
            r.origin.y = max(vis.minY + 6, min(vis.maxY - r.height - 6, r.origin.y))
        }
        setFrame(r, display: false)
        view.prepareForShow()
        // Клавиатура должна идти в окно истории, а не в прежнюю программу.
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
        view.focusSearch()
        installKeyMonitor()
        let t1 = CACurrentMediaTime()
        DispatchQueue.main.async {
            KadrLog.write(String(format: "история: %d записей, показ %.0f мс, до первого кадра %.0f мс",
                                 ClipStore.shared.items.count, (t1 - t0) * 1000, (CACurrentMediaTime() - t0) * 1000))
        }
    }

    /// returnFocus — вернуть фокус программе, где были до открытия (Esc, повторное сочетание).
    func hide(returnFocus: Bool = true) {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().orderOut(nil) }
        let wasVisible = isVisible
        orderOut(nil)
        if isEdge {
            if wasVisible { KadrLog.write(String(format: "панель у края: скрыта через %.0f мс", (CACurrentMediaTime() - edgeOpenedAt) * 1000)) }
            leaveTimer?.invalidate(); leaveTimer = nil
            if wasVisible { EdgeTrigger.shared.panelHidden() }
            return   // программа не активировалась — возвращать фокус некуда
        }
        if returnFocus, wasVisible, let app = previousApp, !app.isTerminated { app.activate() }
    }

    func windowDidResignKey(_ notification: Notification) {
        // Щелчок мимо — закрываем (кроме Quick Look и панели, открытой жестом).
        if isEdge && sticky { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { return }
        if view.menuOpen { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isKeyWindow, self.isVisible, !self.view.menuOpen else { return }
            if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { return }
            self.hide(returnFocus: false)
        }
    }

    // MARK: Вставка

    /// Одна запись — остаётся в буфере; несколько — по очереди с разделителем, затем буфер возвращается.
    func paste(_ list: [ClipItem], plain: Bool) {
        guard !list.isEmpty, !SequentialPaster.busy else { return }
        let store = ClipStore.shared
        guard SequentialPaster.ensureAccess() else {
            store.write(list, plain: plain)
            view.note("Скопировано. Чтобы вставлять сразу, включите Kadr в «Универсальном доступе»",
                      button: ("Открыть", { SequentialPaster.openAccessibilitySettings() }))
            return
        }
        // Панель у края не активирует Kadr: вставляем в программу, которая впереди сейчас
        // (пользователь мог щёлкнуть в другое поле после открытия).
        if isEdge, let f = NSWorkspace.shared.frontmostApplication, f.bundleIdentifier != Bundle.main.bundleIdentifier { previousApp = f }
        let reshow = keepOpen && isVisible
        hide(returnFocus: false)
        let writers: [(NSPasteboard) -> Void] = list.map { it in { pb in
            if it.kind == .file && !plain { pb.writeObjects(it.files.map { $0 as NSURL }) }
            store.fill(it, plain: plain, pb)
        } }
        let single = list.count == 1
        SequentialPaster.run(writers, separator: Prefs.clipPasteSeparator, restore: !single, activate: previousApp) { [weak self] in
            if single, let it = list.first { store.touch(it.id) }
            // Замок: панель возвращается, но клавиатура остаётся в программе, куда вставили.
            if reshow, let self { self.view.reload(); self.orderFrontRegardless(); if self.isEdge { self.startEdgeTimer() } }
        }
    }

    func copy(_ list: [ClipItem]) {
        guard !list.isEmpty else { return }
        ClipStore.shared.write(list, plain: false)
        if list.count == 1, let it = list.first { ClipStore.shared.touch(it.id) }
        view.note(list.count == 1 ? "Скопировано" : "Скопировано: \(list.count) " + russianPlural(list.count, "запись", "записи", "записей"))
    }

    // MARK: Quick Look

    var previewItem: URL?

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = view }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil }

    func quickLook(_ it: ClipItem) {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().orderOut(nil); return }
        guard !it.concealed else { view.note("Просмотр скрытых записей выключен"); return }
        previewItem = ClipStore.shared.previewURL(it)
        guard previewItem != nil, let ql = QLPreviewPanel.shared() else { return }
        ql.makeKeyAndOrderFront(nil)
        ql.reloadData()
    }
}

// MARK: - Вид истории 1.4: карточки, нижняя панель, фильтры в «…»

enum ClipFilter: Int, CaseIterable {
    case all, text, link, image, file, password
    var title: String { ["Все", "Текст", "Ссылки", "Картинки", "Файлы", "Пароли"][rawValue] }
    var symbol: String { ["tray.full", "text.alignleft", "link", "photo", "doc", "key"][rawValue] }
    func match(_ it: ClipItem) -> Bool {
        switch self {
        case .all: return true
        case .text: return it.kind == .text && !it.concealed
        case .link: return it.kind == .link
        case .image: return it.kind == .image
        case .file: return it.kind == .file
        case .password: return it.concealed
        }
    }
}

enum ClipStyle {
    private static func dyn(_ dark: CGFloat, _ light: CGFloat) -> NSColor {
        NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor.white.withAlphaComponent(dark) : NSColor.black.withAlphaComponent(light)
        }
    }
    static let card = dyn(0.07, 0.045)
    static let cardHover = dyn(0.11, 0.075)
    static let hairline = dyn(0.10, 0.10)
    /// Подложка под прозрачностью: ровный тёмный/светлый фон независимо от обоев.
    static let tint = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.07, alpha: 0.62) : NSColor(white: 0.98, alpha: 0.55)
    }
    static let rowHeight: CGFloat = 88
    static let radius: CGFloat = 12
}

/// Кнопка-значок нижней панели: подсветка при наведении, «активная» — цветом акцента.
final class ClipBarButton: NSButton {
    var active = false { didSet { look() } }
    private var hover = false

    init(_ symbol: String, _ tip: String, ax: String, target: AnyObject, action: Selector) {
        super.init(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        refusesFirstResponder = true
        symbolConfiguration = .init(pointSize: 14, weight: .regular)
        setSymbol(symbol, tip)
        setAccessibilityIdentifier(ax)
        self.target = target
        self.action = action
        wantsLayer = true
        layer?.cornerRadius = 8
        look()
    }
    required init?(coder: NSCoder) { fatalError() }

    func setSymbol(_ symbol: String, _ tip: String) {
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        toolTip = tip
        setAccessibilityLabel(tip)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hover = true; look() }
    override func mouseExited(with event: NSEvent) { hover = false; look() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); look() }

    private func look() {
        contentTintColor = active ? .controlAccentColor : (hover ? .labelColor : .secondaryLabelColor)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let bg: NSColor = active ? NSColor.controlAccentColor.withAlphaComponent(0.16) : (hover ? ClipStyle.cardHover : .clear)
            layer?.backgroundColor = bg.cgColor
        }
    }
}

/// Строка-карточка: подложка, рамка акцента у выделенной, подсветка при наведении.
final class ClipTableRowView: NSTableRowView {
    private var hover = false
    private var cell: ClipRowView? { numberOfColumns > 0 ? view(atColumn: 0) as? ClipRowView : nil }
    private var card: NSRect { bounds.insetBy(dx: 10, dy: 5) }

    override var isSelected: Bool { didSet { if isSelected != oldValue { cell?.setState(selected: isSelected, hover: hover); needsDisplay = true } } }
    // Не «выделенный» стиль ячейки: текст карточки не белеет, выделение — рамкой.
    override var isEmphasized: Bool { get { false } set {} }
    override func didAddSubview(_ subview: NSView) { super.didAddSubview(subview); cell?.setState(selected: isSelected, hover: hover) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }
    private func setHover(_ h: Bool) {
        guard h != hover else { return }
        hover = h
        cell?.setState(selected: isSelected, hover: h)
        needsDisplay = true
    }

    override func drawBackground(in dirtyRect: NSRect) {
        (hover ? ClipStyle.cardHover : ClipStyle.card).setFill()
        NSBezierPath(roundedRect: card, xRadius: ClipStyle.radius, yRadius: ClipStyle.radius).fill()
    }
    override func drawSelection(in dirtyRect: NSRect) {
        ClipStyle.cardHover.setFill()
        NSBezierPath(roundedRect: card, xRadius: ClipStyle.radius, yRadius: ClipStyle.radius).fill()
        NSColor.controlAccentColor.setStroke()
        let b = NSBezierPath(roundedRect: card.insetBy(dx: 1, dy: 1), xRadius: ClipStyle.radius - 1, yRadius: ClipStyle.radius - 1)
        b.lineWidth = 2
        b.stroke()
    }
}

/// Для доступности отдаём только видимые строки: обход дерева (VoiceOver, тесты)
/// не создаёт и не опрашивает сотни строк истории.
final class VisibleRowsTableView: NSTableView {
    // Панель у края не активирует Kadr: первый щелчок должен сразу работать.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private func visibleRowViews() -> [Any] {
        let r = rows(in: visibleRect)
        guard r.length > 0 else { return [] }
        return (r.location..<(r.location + r.length)).compactMap { view(atColumn: 0, row: $0, makeIfNecessary: false) }
    }
    override func accessibilityChildren() -> [Any]? { visibleRowViews() }
}

final class ClipHistoryView: NSVisualEffectView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate,
    QLPreviewPanelDataSource {
    unowned let panel: ClipHistoryPanel
    let store: ClipStore
    private let search = NSSearchField()
    private let scroll = NSScrollView()
    let table = VisibleRowsTableView()
    private let empty = NSTextField(labelWithString: "")
    private let noteL = NSTextField(labelWithString: "")
    private let noteButton = NSButton(title: "", target: nil, action: nil)
    private let pill = NSButton(title: "", target: nil, action: nil)
    private let line = NSView()
    private let tintView = NSView()
    private var searchB: ClipBarButton!, historyB: ClipBarButton!, pinnedB: ClipBarButton!, moreB: ClipBarButton!, closeSearchB: ClipBarButton!
    private var collapseB: ClipBarButton!, keepB: ClipBarButton!, windowB: ClipBarButton!, settingsB: ClipBarButton!
    private var noteAction: (() -> Void)?
    private var noteTimer: Timer?
    private var clockTimer: Timer?
    private(set) var shown: [ClipItem] = []
    /// Порядок выделения (для вставки нескольких записей по очереди).
    fileprivate(set) var order: [UUID] = []
    private var revealed: Set<UUID> = []
    private var iconCache: [String: NSImage] = [:]
    private var missingIcons: Set<String> = []
    private(set) var filter: ClipFilter = .all
    private(set) var pinnedTab = false
    private(set) var searching = false
    private var menuRow: Int?
    var menuOpen = false

    override var isFlipped: Bool { true }

    init(panel: ClipHistoryPanel, store: ClipStore) {
        self.panel = panel
        self.store = store
        super.init(frame: NSRect(origin: .zero, size: ClipHistoryPanel.size))
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        let p = panel.axPrefix
        tintView.wantsLayer = true
        addSubview(tintView)

        pill.bezelStyle = .inline
        pill.controlSize = .small
        pill.font = .systemFont(ofSize: 11, weight: .medium)
        pill.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Снять фильтр")
        pill.imagePosition = .imageTrailing
        pill.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        pill.target = self
        pill.action = #selector(clearFilter)
        pill.refusesFirstResponder = true
        pill.isHidden = true
        pill.setAccessibilityIdentifier(p + ".filterPill")
        addSubview(pill)

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = ClipStyle.rowHeight
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.refusesFirstResponder = true      // клавиши ловит монитор окна
        table.intercellSpacing = .zero
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        if panel.isEdge { table.action = #selector(singleClicked) }
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.menu = NSMenu()
        table.menu?.delegate = self
        table.setAccessibilityIdentifier(p + ".list")
        table.setAccessibilityLabel("Записи истории")
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        addSubview(scroll)

        empty.alignment = .center
        empty.textColor = .secondaryLabelColor
        empty.font = .systemFont(ofSize: 12)
        empty.maximumNumberOfLines = 2
        addSubview(empty)

        noteL.font = .systemFont(ofSize: 11, weight: .medium)
        noteL.textColor = .secondaryLabelColor
        noteL.alignment = .center
        noteL.lineBreakMode = .byTruncatingTail
        noteL.isHidden = true
        noteL.setAccessibilityIdentifier(p + ".note")
        addSubview(noteL)
        noteButton.bezelStyle = .inline
        noteButton.controlSize = .small
        noteButton.target = self
        noteButton.action = #selector(notePressed)
        noteButton.isHidden = true
        addSubview(noteButton)

        search.placeholderString = "Поиск в истории"
        search.delegate = self
        search.focusRingType = .none
        search.sendsSearchStringImmediately = true
        search.isHidden = true
        (search.cell as? NSSearchFieldCell)?.cancelButtonCell = nil   // закрывает крестик справа
        search.setAccessibilityIdentifier(p + ".search")
        search.setAccessibilityLabel("Поиск в истории")
        addSubview(search)

        line.wantsLayer = true
        addSubview(line)

        searchB = ClipBarButton("magnifyingglass", "Поиск (или просто печатайте)", ax: p + ".bar.search", target: self, action: #selector(startSearchPressed))
        historyB = ClipBarButton("clock", "История", ax: p + ".bar.history", target: self, action: #selector(showHistory))
        pinnedB = ClipBarButton("pin", "Закреплённые", ax: p + ".bar.pinned", target: self, action: #selector(showPinned))
        moreB = ClipBarButton("ellipsis", "Фильтры и действия", ax: p + ".bar.more", target: self, action: #selector(morePressed))
        closeSearchB = ClipBarButton("xmark.circle.fill", "Закрыть поиск", ax: p + ".bar.closeSearch", target: self, action: #selector(endSearchPressed))
        closeSearchB.isHidden = true
        let collapseSymbol = panel.isEdge ? (Prefs.clipEdgeSide == "left" ? "chevron.left" : "chevron.right") : "xmark"
        collapseB = ClipBarButton(collapseSymbol, "Спрятать", ax: p + ".bar.collapse", target: self, action: #selector(collapsePressed))
        keepB = ClipBarButton("lock.open", "Не прятать после вставки", ax: p + ".bar.keep", target: self, action: #selector(keepPressed))
        windowB = ClipBarButton("macwindow", "Открыть окном", ax: p + ".bar.window", target: self, action: #selector(windowPressed))
        windowB.isHidden = !panel.isEdge
        settingsB = ClipBarButton("gearshape", "Настройки", ax: p + ".bar.settings", target: self, action: #selector(settingsPressed))
        [searchB, historyB, pinnedB, moreB, closeSearchB, collapseB, keepB, windowB, settingsB].forEach { addSubview($0!) }
        historyB.active = true
        look()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func look() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
            line.layer?.backgroundColor = ClipStyle.hairline.cgColor
            tintView.layer?.backgroundColor = ClipStyle.tint.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        look()
    }

    override func layout() {
        super.layout()
        let W = bounds.width, H = bounds.height
        let bar1 = H - 88, bar2 = H - 44
        tintView.frame = bounds
        var top: CGFloat = 6
        if !pill.isHidden {
            pill.sizeToFit()
            pill.frame = NSRect(x: 14, y: 10, width: pill.frame.width + 6, height: 22)
            top = 38
        }
        scroll.frame = NSRect(x: 0, y: top, width: W, height: bar1 - top)
        table.tableColumns.first?.width = scroll.contentSize.width
        empty.frame = NSRect(x: 20, y: scroll.frame.midY - 18, width: W - 40, height: 36)
        noteButton.sizeToFit()
        let nb = noteButton.isHidden ? 0 : noteButton.frame.width + 6
        noteL.frame = NSRect(x: 16, y: bar1 - 22, width: W - 32 - nb, height: 15)
        noteButton.frame.origin = NSPoint(x: W - 14 - noteButton.frame.width, y: bar1 - 26)
        // Первая строка нижней панели: поиск, история/закреплённые, «…» — или поле поиска.
        let y1 = bar1 + 7
        searchB.frame.origin = NSPoint(x: 12, y: y1)
        historyB.frame.origin = NSPoint(x: 48, y: y1)
        pinnedB.frame.origin = NSPoint(x: 82, y: y1)
        moreB.frame.origin = NSPoint(x: W - 42, y: y1)
        search.frame = NSRect(x: 14, y: bar1 + 9, width: W - 14 - 48, height: 26)
        closeSearchB.frame.origin = NSPoint(x: W - 42, y: y1)
        line.frame = NSRect(x: 12, y: bar2, width: W - 24, height: 1)
        // Вторая строка: спрятать, не прятать после вставки, окном, настройки.
        let y2 = bar2 + 7
        collapseB.frame.origin = NSPoint(x: 12, y: y2)
        keepB.frame.origin = NSPoint(x: 48, y: y2)
        windowB.frame.origin = NSPoint(x: 84, y: y2)
        settingsB.frame.origin = NSPoint(x: W - 42, y: y2)
    }

    func prepareForShow() {
        search.stringValue = ""
        setSearching(false)
        filter = .all
        pinnedTab = false
        revealed = []
        order = []
        keepB.active = panel.keepOpen
        updateBar()
        reload()
        startClock()
    }

    /// Клавиатура: в поле поиска, если поиск открыт; иначе в окно (клавиши ловит монитор).
    func focusSearch() { panel.makeFirstResponder(searching ? search : nil) }

    private var searchFocused: Bool {
        guard searching, let ed = search.currentEditor() else { return false }
        return panel.firstResponder === ed
    }

    private func setSearching(_ on: Bool) {
        searching = on
        search.isHidden = !on
        closeSearchB.isHidden = !on
        [searchB, historyB, pinnedB, moreB].forEach { $0?.isHidden = on }
        needsLayout = true
    }

    func startSearch(with text: String? = nil) {
        setSearching(true)
        if let text { search.stringValue = text }
        panel.makeFirstResponder(search)
        if let ed = search.currentEditor() { ed.selectedRange = NSRange(location: (search.stringValue as NSString).length, length: 0) }
        order = []
        reload()
    }

    private func endSearch() {
        search.stringValue = ""
        setSearching(false)
        panel.makeFirstResponder(nil)
        order = []
        reload()
    }

    private func updateBar() {
        historyB.active = !pinnedTab
        pinnedB.active = pinnedTab
        pill.isHidden = filter == .all
        pill.title = filter.title
        pill.setAccessibilityLabel("Фильтр: \(filter.title). Снять")
        needsLayout = true
    }

    func setFilter(_ f: ClipFilter) { filter = f; order = []; updateBar(); reload() }
    func setPinnedTab(_ on: Bool) { pinnedTab = on; order = []; updateBar(); reload() }

    func reload() {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let f = filter, pinOnly = pinnedTab
        let list = store.items.filter { it in
            if pinOnly && !it.pinned { return false }
            if !f.match(it) { return false }
            if q.isEmpty { return true }
            if it.concealed && !revealed.contains(it.id) { return (it.sourceName?.lowercased().contains(q) ?? false) }
            return it.text.lowercased().contains(q) || it.title.lowercased().contains(q) || (it.sourceName?.lowercased().contains(q) ?? false)
        }
        // Закреплённые — наверху.
        shown = list.filter { $0.pinned } + list.filter { !$0.pinned }
        let keep = order.filter { id in shown.contains { $0.id == id } }
        table.reloadData()
        if keep.isEmpty {
            order = []
            // У панели у края ничего не выделяем заранее: ⌘-щелчок по логину и паролю
            // должен дать ровно эти две записи (а не «первая строка + логин − пароль»).
            if !shown.isEmpty && !panel.isEdge { select([0]) }
        } else {
            let saved = keep
            table.selectRowIndexes(IndexSet(keep.compactMap { id in shown.firstIndex { $0.id == id } }), byExtendingSelection: false)
            order = saved
        }
        refreshBadges()
        if store.items.isEmpty {
            empty.stringValue = ClipMonitor.shared.paused ? "Запись на паузе" : "Скопируйте что-нибудь —\nоно появится здесь"
        } else if shown.isEmpty {
            empty.stringValue = pinnedTab && q.isEmpty && f == .all ? "Закреплённых нет —\n⌘P закрепит выбранную запись" : "Ничего не найдено"
        } else {
            empty.stringValue = ""
        }
        empty.isHidden = !shown.isEmpty
    }

    private func select(_ rows: IndexSet) {
        table.selectRowIndexes(rows, byExtendingSelection: false)
        if let r = rows.first { table.scrollRowToVisible(r) }
    }

    /// Выбранные записи в порядке выделения.
    var selectedItems: [ClipItem] { order.compactMap { id in shown.first { $0.id == id } } }

    /// Новый порядок выделения: снятые убираем, новые добавляем в конец (по порядку строк).
    static func updatedOrder(_ old: [UUID], selected: [UUID]) -> [UUID] {
        let set = Set(selected)
        let kept = old.filter { set.contains($0) }
        return kept + selected.filter { !kept.contains($0) }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let ids = table.selectedRowIndexes.compactMap { shown.indices.contains($0) ? shown[$0].id : nil }
        order = ClipHistoryView.updatedOrder(order, selected: ids)
        refreshBadges()
    }

    /// Первая строка, видная целиком наполовину и больше, — она получает ⌘1.
    var firstVisibleRow: Int {
        let vr = table.visibleRect
        let r = table.rows(in: vr)
        guard r.length > 0 else { return 0 }
        var first = r.location
        if first < shown.count - 1, table.rect(ofRow: first).midY < vr.minY { first += 1 }
        return first
    }

    @objc private func scrolled() { refreshBadges() }

    private func refreshBadges() {
        let multi = order.count > 1
        let first = firstVisibleRow
        table.enumerateAvailableRowViews { rv, row in
            guard let cell = rv.view(atColumn: 0) as? ClipRowView, self.shown.indices.contains(row) else { return }
            let pos = self.order.firstIndex(of: self.shown[row].id)
            let q = row - first + 1
            cell.setBadge(multi ? pos.map { $0 + 1 } : nil, quick: (1...9).contains(q) ? q : nil)
        }
    }

    private func startClock() {
        clockTimer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] t in
            guard let self, self.window?.isVisible == true else { t.invalidate(); return }
            self.table.enumerateAvailableRowViews { rv, _ in (rv.view(atColumn: 0) as? ClipRowView)?.updateTime() }
        }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        clockTimer = t
    }

    func note(_ text: String, button: (String, () -> Void)? = nil) {
        noteTimer?.invalidate()
        noteL.stringValue = text
        noteL.isHidden = false
        noteAction = button?.1
        noteButton.title = button?.0 ?? ""
        noteButton.isHidden = button == nil
        needsLayout = true
        noteTimer = Timer.scheduledTimer(withTimeInterval: button == nil ? 2 : 10, repeats: false) { [weak self] _ in
            self?.noteL.isHidden = true
            self?.noteButton.isHidden = true
            self?.needsLayout = true
        }
    }

    @objc private func notePressed() { noteAction?() }

    // MARK: Нижняя панель

    @objc private func startSearchPressed() { startSearch() }
    @objc private func endSearchPressed() { endSearch() }
    @objc private func showHistory() { setPinnedTab(false) }
    @objc private func showPinned() { setPinnedTab(!pinnedTab) }
    @objc private func clearFilter() { setFilter(.all) }
    @objc private func collapsePressed() { panel.hide(returnFocus: true) }
    @objc private func keepPressed() {
        panel.keepOpen.toggle()
        keepB.active = panel.keepOpen
        keepB.setSymbol(panel.keepOpen ? "lock.fill" : "lock.open", panel.keepOpen ? "Панель не прячется после вставки" : "Не прятать после вставки")
    }
    @objc private func windowPressed() {
        panel.hide(returnFocus: false)
        ClipHistoryPanel.shared.show()
    }
    @objc private func settingsPressed() {
        panel.hide(returnFocus: false)
        (NSApp.delegate as? AppDelegate)?.openSettings()
    }

    @objc private func morePressed() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ t: String, _ s: String, on: Bool = false, _ a: @escaping () -> Void) {
            let m = ClosureMenuItem(title: t, handler: a)
            m.image = NSImage(systemSymbolName: s, accessibilityDescription: nil)
            m.state = on ? .on : .off
            menu.addItem(m)
        }
        for f in ClipFilter.allCases {
            add(f.title, f.symbol, on: filter == f) { [weak self] in self?.setFilter(f) }
        }
        menu.addItem(.separator())
        add("Закреплённые", "pin", on: pinnedTab) { [weak self] in self?.setPinnedTab(!(self?.pinnedTab ?? false)) }
        menu.addItem(.separator())
        add("Очистить историю…", "trash") { [weak self] in self?.confirmClear() }
        add("Настройки…", "gearshape") { [weak self] in self?.settingsPressed() }
        menuOpen = true
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreB.bounds.height + 4), in: moreB)
        menuOpen = false
    }

    private func confirmClear() {
        let a = NSAlert()
        a.messageText = "Очистить историю?"
        a.informativeText = "Удалятся все записи, кроме закреплённых. Вернуть их будет нельзя."
        a.alertStyle = .warning
        a.addButton(withTitle: "Очистить")
        a.addButton(withTitle: "Отмена")
        a.buttons.first?.hasDestructiveAction = true
        menuOpen = true
        NSApp.activate(ignoringOtherApps: true)
        let r = a.runModal()
        menuOpen = false
        if r == .alertFirstButtonReturn {
            store.clear(keepPinned: true)
            order = []
            reload()
            note("История очищена")
        }
        panel.makeKey()
    }

    // MARK: Щелчки

    /// Панель у края: обычный щелчок сразу вставляет, ⌘/⇧-щелчок — выделяет.
    @objc private func singleClicked() {
        let r = table.clickedRow
        guard shown.indices.contains(r) else { return }
        let f = NSApp.currentEvent?.modifierFlags ?? []
        if f.contains(.command) || f.contains(.shift) { return }
        let it = shown[r]
        panel.paste(order.count > 1 && order.contains(it.id) ? selectedItems : [it], plain: false)
    }

    @objc private func doubleClicked() {
        let r = table.clickedRow
        guard shown.indices.contains(r) else { return }
        panel.paste(order.count > 1 ? selectedItems : [shown[r]], plain: false)
    }

    func controlTextDidChange(_ obj: Notification) { order = []; reload() }

    func showCardMenu(for id: UUID, from view: NSView) {
        guard let r = shown.firstIndex(where: { $0.id == id }) else { return }
        let menu = NSMenu()
        menuRow = r
        menuNeedsUpdate(menu)
        menuRow = nil
        menuOpen = true
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 2), in: view)
        menuOpen = false
    }

    // MARK: Клавиши (их ловит монитор окна до поля поиска)

    func handleKey(_ e: NSEvent) -> Bool {
        let f = e.modifierFlags.intersection([.command, .option, .control, .shift])
        let code = Int(e.keyCode)
        let typingInSearch = searchFocused && !search.stringValue.isEmpty
        switch code {
        case kVK_DownArrow, kVK_UpArrow:
            move(code == kVK_DownArrow ? 1 : -1, extend: f.contains(.shift) || f.contains(.command)); return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            let list = selectedItems.isEmpty ? Array(shown.prefix(1)) : selectedItems
            panel.paste(list, plain: f.contains(.command)); return true
        case kVK_Escape:
            if searching { endSearch() } else { panel.hide() }
            return true
        case kVK_Tab:
            let n = ClipFilter.allCases.count
            setFilter(ClipFilter(rawValue: (filter.rawValue + (f.contains(.shift) ? n - 1 : 1)) % n) ?? .all)
            return true
        case kVK_Delete, kVK_ForwardDelete:
            guard !typingInSearch || f.contains(.command) else { return false }
            removeSelected(); return true
        case kVK_Space:
            guard !searchFocused && f.isEmpty else { return false }
            if let it = selectedItems.last { panel.quickLook(it) }
            return true
        default: break
        }
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        if f == .command {
            if let i = digits.firstIndex(of: code) {
                let r = firstVisibleRow + i
                if shown.indices.contains(r) { panel.paste([shown[r]], plain: false) }
                return true
            }
            switch code {
            case kVK_ANSI_F: startSearch(); return true
            case kVK_ANSI_C where (search.currentEditor()?.selectedRange.length ?? 0) == 0:
                panel.copy(selectedItems); return true
            case kVK_ANSI_P:
                let list = selectedItems
                let pin = list.contains { !$0.pinned }
                list.forEach { store.setPinned($0.id, pin) }
                reload()
                return true
            default: return false
            }
        }
        // Печать в любом месте панели начинает поиск.
        if !searchFocused, f.subtracting(.shift).isEmpty, let ch = e.characters, !ch.isEmpty,
           ch.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) {
            startSearch(with: (searching ? search.stringValue : "") + ch)
            return true
        }
        return false
    }

    private func move(_ d: Int, extend: Bool) {
        guard !shown.isEmpty else { return }
        let cur = order.last.flatMap { id in shown.firstIndex { $0.id == id } } ?? (d > 0 ? -1 : shown.count)
        let r = max(0, min(shown.count - 1, cur + d))
        if extend {
            table.selectRowIndexes([r], byExtendingSelection: true)
            let id = shown[r].id
            order.removeAll { $0 == id }
            order.append(id)
            refreshBadges()
        } else {
            order = []
            table.selectRowIndexes([r], byExtendingSelection: false)
        }
        table.scrollRowToVisible(r)
    }

    private func removeSelected() {
        let list = selectedItems
        guard !list.isEmpty else { return }
        let firstRow = shown.firstIndex { $0.id == list[0].id } ?? 0
        list.forEach { store.remove($0.id) }
        order = []
        reload()
        if !shown.isEmpty { order = []; select([min(firstRow, shown.count - 1)]) }
    }

    func toggleReveal(_ id: UUID) {
        if revealed.contains(id) { revealed.remove(id) } else { revealed.insert(id) }
        if let r = shown.firstIndex(where: { $0.id == id }) { table.reloadData(forRowIndexes: [r], columnIndexes: [0]) }
        refreshBadges()
    }

    // MARK: Таблица

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ClipTableRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let it = shown[row]
        let rid = NSUserInterfaceItemIdentifier("clipCard")
        let v = (tableView.makeView(withIdentifier: rid, owner: nil) as? ClipRowView)
            ?? { let c = ClipRowView(frame: NSRect(x: 0, y: 0, width: tableView.bounds.width, height: ClipStyle.rowHeight)); c.identifier = rid; return c }()
        v.itemID = it.id
        v.configure(it, revealed: revealed.contains(it.id), thumb: store.cachedThumbnail(it), appIcon: appIcon(it.sourceID))
        if it.kind == .image, it.hasThumb, store.cachedThumbnail(it) == nil {
            store.loadThumbnail(it) { [weak v] img in
                guard let v, v.itemID == it.id, let img else { return }
                v.setThumb(img)
            }
        }
        v.onReveal = { [weak self] in self?.toggleReveal(it.id) }
        v.onMore = { [weak self, weak v] in if let self, let v { self.showCardMenu(for: it.id, from: v.moreButton) } }
        v.setAXPrefix(panel.axPrefix)
        let pos = order.firstIndex(of: it.id)
        let q = row - firstVisibleRow + 1
        v.setBadge(order.count > 1 ? pos.map { $0 + 1 } : nil, quick: (1...9).contains(q) ? q : nil)
        return v
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let it = shown[row]
        switch it.kind {
        case .text: return it.text as NSString
        case .link: return (URL(string: it.text) as NSURL?) ?? (it.text as NSString)
        case .image: return store.previewURL(it).map { $0 as NSURL }
        case .file: return it.files.first.map { $0 as NSURL }
        }
    }

    private func appIcon(_ id: String?) -> NSImage? {
        guard let id else { return nil }
        if let c = iconCache[id] { return c }
        if missingIcons.contains(id) { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { missingIcons.insert(id); return nil }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[id] = img
        return img
    }

    // MARK: Quick Look

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { self.panel.previewItem == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { self.panel.previewItem as NSURL? }
}

extension ClipHistoryView: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) { menuOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = menuRow ?? (table.clickedRow >= 0 ? table.clickedRow : table.selectedRow)
        guard shown.indices.contains(row) else { return }
        let clicked = shown[row]
        let list = order.contains(clicked.id) && order.count > 1 ? selectedItems : [clicked]
        let many = list.count > 1
        func add(_ t: String, _ s: String, _ a: @escaping () -> Void) {
            let m = ClosureMenuItem(title: t, handler: a)
            m.image = NSImage(systemSymbolName: s, accessibilityDescription: nil)
            menu.addItem(m)
        }
        add(many ? "Вставить по очереди (\(list.count))" : "Вставить", "arrow.down.doc") { [weak self] in self?.panel.paste(list, plain: false) }
        add("Вставить как текст", "textformat") { [weak self] in self?.panel.paste(list, plain: true) }
        add("Копировать", "doc.on.doc") { [weak self] in self?.panel.copy(list) }
        if !many {
            add(clicked.pinned ? "Открепить" : "Закрепить", clicked.pinned ? "pin.slash" : "pin") { [weak self] in
                self?.store.setPinned(clicked.id, !clicked.pinned); self?.reload()
            }
        }
        let texts = list.filter { $0.kind == .text || $0.kind == .link }
        let files = list.filter { $0.kind == .file || $0.kind == .image }
        if !texts.isEmpty || !files.isEmpty { menu.addItem(.separator()) }
        if !texts.isEmpty {
            add("На текстовую полку", "text.badge.plus") { [weak self] in
                TextShelfPanel.shared.add(texts.map { $0.text })
                self?.note("Добавлено на текстовую полку")
            }
        }
        if !files.isEmpty {
            add("На полку", "tray.and.arrow.down") { [weak self] in
                guard let self else { return }
                var items: [ShelfItem] = []
                for it in files {
                    if it.kind == .file { items += it.files.map { ShelfItem(file: $0, temp: false) } }
                    else if let d = self.store.imageData(it) {
                        let dst = ShelfStore.newDir().appendingPathComponent("Изображение \(ShelfStore.stamp()).png")
                        if (try? d.write(to: dst)) != nil { items.append(ShelfItem(file: dst, temp: true)) }
                    }
                }
                ShelfPanel.addToFrontmost(items, near: nil)
                self.note("Добавлено на полку")
            }
        }
        menu.addItem(.separator())
        add(many ? "Удалить из истории (\(list.count))" : "Удалить из истории", "trash") { [weak self] in
            list.forEach { self?.store.remove($0.id) }
            self?.order = []
            self?.reload()
        }
    }
}

/// Карточка записи: значок программы, ⌘N, время; ниже — превью по типу.
final class ClipRowView: NSTableCellView {
    private let app = NSImageView()
    private let quick = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let pinMark = NSImageView()
    private let time = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let main = NSTextField(wrappingLabelWithString: "")
    private let sub = NSTextField(labelWithString: "")
    private let eye = NSButton()
    let moreButton = NSButton()
    private var kind: ClipItem.Kind = .text
    private var concealed = false
    private var date = Date()
    private var imgAspect: CGFloat = 1.6
    private var selected = false, hover = false
    var onReveal: (() -> Void)?
    var onMore: (() -> Void)?
    var itemID: UUID?

    func setAXPrefix(_ p: String) {
        setAccessibilityIdentifier(p + ".row")
        eye.setAccessibilityIdentifier(p + ".reveal")
        moreButton.setAccessibilityIdentifier(p + ".cardMore")
    }

    func setThumb(_ img: NSImage) {
        icon.image = img
        if img.size.height > 0 { imgAspect = img.size.width / img.size.height }
        needsLayout = true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        app.imageScaling = .scaleProportionallyUpOrDown
        quick.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        quick.textColor = .controlAccentColor
        badge.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .bold)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.drawsBackground = false
        badge.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        badge.layer?.cornerRadius = 8
        badge.isHidden = true
        badge.setAccessibilityLabel("Порядок вставки")
        pinMark.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Закреплено")
        pinMark.contentTintColor = .secondaryLabelColor
        pinMark.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        time.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        time.textColor = .secondaryLabelColor
        time.alignment = .right
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 6
        icon.layer?.masksToBounds = true
        main.font = .systemFont(ofSize: 13)
        main.textColor = .labelColor
        main.maximumNumberOfLines = 2
        main.lineBreakMode = .byWordWrapping
        main.cell?.truncatesLastVisibleLine = true
        main.isSelectable = false
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingMiddle
        for b in [eye, moreButton] {
            b.isBordered = false
            b.bezelStyle = .regularSquare
            b.imagePosition = .imageOnly
            b.refusesFirstResponder = true
            b.contentTintColor = .secondaryLabelColor
            b.isHidden = true
        }
        eye.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        eye.target = self
        eye.action = #selector(eyePressed)
        moreButton.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        moreButton.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Действия")
        moreButton.toolTip = "Действия"
        moreButton.setAccessibilityLabel("Действия")
        moreButton.target = self
        moreButton.action = #selector(morePressed)
        [app, quick, badge, pinMark, time, icon, main, sub, eye, moreButton].forEach(addSubview)
        setAccessibilityIdentifier("kadr.clipHistory.row")
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    @objc private func eyePressed() { onReveal?() }
    @objc private func morePressed() { onMore?() }

    func setState(selected s: Bool, hover h: Bool) {
        selected = s; hover = h
        eye.isHidden = !(concealed && (s || h))
        moreButton.isHidden = !s
        needsLayout = true
    }

    func updateTime() { time.stringValue = ClipRowView.relative(date) }

    private static func preview(_ s: String) -> String {
        let head = s.count > 400 ? String(s.prefix(400)) : s
        return head.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    func configure(_ it: ClipItem, revealed: Bool, thumb img: NSImage?, appIcon: NSImage?) {
        kind = it.kind
        concealed = it.concealed
        date = it.date
        let masked = it.concealed && !revealed
        app.image = appIcon ?? NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
        app.contentTintColor = .tertiaryLabelColor
        app.toolTip = it.sourceName
        updateTime()
        pinMark.isHidden = !it.pinned
        main.font = .systemFont(ofSize: 13)
        main.maximumNumberOfLines = 2
        icon.isHidden = true
        icon.contentTintColor = nil
        sub.isHidden = true
        if it.concealed {
            main.stringValue = masked ? "••••••••••" : it.text
            main.font = masked ? .systemFont(ofSize: 15, weight: .semibold) : .monospacedSystemFont(ofSize: 13, weight: .regular)
            main.maximumNumberOfLines = 1
            sub.stringValue = "Пароль" + (it.sourceName.map { " · \($0)" } ?? "")
            sub.isHidden = false
        } else {
            switch it.kind {
            case .text:
                main.stringValue = ClipRowView.preview(it.text)
            case .link:
                icon.image = NSImage(systemSymbolName: "link", accessibilityDescription: "Ссылка")
                icon.contentTintColor = .secondaryLabelColor
                icon.isHidden = false
                main.stringValue = URL(string: it.text)?.host ?? it.title
                main.font = .systemFont(ofSize: 13, weight: .medium)
                main.maximumNumberOfLines = 1
                sub.stringValue = it.text
                sub.isHidden = false
            case .image:
                icon.image = img ?? NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
                icon.contentTintColor = img == nil ? .secondaryLabelColor : nil
                imgAspect = it.h > 0 ? CGFloat(it.w) / CGFloat(it.h) : 1.6
                icon.isHidden = false
                main.stringValue = it.w > 0 ? "\(it.w)×\(it.h)" : "Изображение"
                main.maximumNumberOfLines = 1
                sub.stringValue = ByteCountFormatter.string(fromByteCount: Int64(it.bytes), countStyle: .file)
                sub.isHidden = false
            case .file:
                icon.image = it.files.first.map { NSWorkspace.shared.icon(forFile: $0.path) }
                icon.isHidden = false
                main.stringValue = it.title
                main.font = .systemFont(ofSize: 13, weight: .medium)
                main.maximumNumberOfLines = 1
                sub.stringValue = it.subtitle
                sub.isHidden = false
            }
        }
        let tip = revealed ? "Скрыть" : "Показать"
        eye.image = NSImage(systemSymbolName: revealed ? "eye.slash" : "eye", accessibilityDescription: tip)
        eye.toolTip = tip
        eye.setAccessibilityLabel(tip)
        setState(selected: selected, hover: hover)
        toolTip = masked ? nil : (it.kind == .text ? String(it.text.prefix(500)) : it.text)
        setAccessibilityLabel(it.shownTitle(revealed: revealed))
        needsLayout = true
    }

    func setBadge(_ n: Int?, quick q: Int?) {
        badge.isHidden = n == nil
        badge.stringValue = n.map(String.init) ?? ""
        quick.isHidden = n != nil || q == nil
        quick.stringValue = q.map { "⌘\($0)" } ?? ""
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let W = bounds.width
        let L: CGFloat = 22, R = W - 22, top: CGFloat = 15
        app.frame = NSRect(x: L, y: top, width: 20, height: 20)
        quick.sizeToFit()
        quick.frame.origin = NSPoint(x: L + 28, y: top + 2)
        badge.frame = NSRect(x: L + 27, y: top + 2, width: 17, height: 16)
        let afterQ = (badge.isHidden ? (quick.isHidden ? L + 28 : quick.frame.maxX + 6) : badge.frame.maxX + 6)
        pinMark.frame = NSRect(x: afterQ, y: top + 3, width: 13, height: 14)
        time.frame = NSRect(x: R - 90, y: top + 3, width: 90, height: 14)
        let y = top + 26
        let right = R - 26
        let by = bounds.height - 5 - 8 - 22
        moreButton.frame = NSRect(x: R - 22, y: by, width: 22, height: 22)
        eye.frame = NSRect(x: moreButton.isHidden ? R - 22 : R - 50, y: by, width: 22, height: 22)
        switch (concealed, kind) {
        case (true, _):
            main.frame = NSRect(x: L, y: y, width: right - L, height: 18)
            sub.frame = NSRect(x: L, y: y + 19, width: right - L, height: 14)
        case (_, .text):
            main.frame = NSRect(x: L, y: y, width: right - L, height: 34)
        case (_, .link):
            icon.frame = NSRect(x: L, y: y + 1, width: 15, height: 15)
            main.frame = NSRect(x: L + 21, y: y, width: right - L - 21, height: 17)
            sub.frame = NSRect(x: L, y: y + 19, width: right - L, height: 14)
        case (_, .image):
            let h: CGFloat = 34, w = min(max(h * imgAspect, 34), 120)
            icon.frame = NSRect(x: L, y: y, width: w, height: h)
            main.frame = NSRect(x: L + w + 10, y: y + 1, width: right - L - w - 10, height: 16)
            sub.frame = NSRect(x: L + w + 10, y: y + 19, width: right - L - w - 10, height: 14)
        case (_, .file):
            icon.frame = NSRect(x: L - 2, y: y, width: 34, height: 34)
            main.frame = NSRect(x: L + 40, y: y + 1, width: right - L - 40, height: 17)
            sub.frame = NSRect(x: L + 40, y: y + 19, width: right - L - 40, height: 14)
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM"
        return f
    }()

    static func relative(_ d: Date) -> String {
        let s = max(0, Date().timeIntervalSince(d))
        if s < 5 { return "сейчас" }
        if s < 60 { return "\(Int(s)) с" }
        if s < 3600 { return "\(Int(s / 60)) мин" }
        if s < 86400 { return "\(Int(s / 3600)) ч" }
        if s < 2 * 86400 { return "вчера" }
        if s < 7 * 86400 { return "\(Int(s / 86400)) дн" }
        return dayFormatter.string(from: d)
    }
}

// MARK: - Проверка без окон (KADR_PROFILE=<имя> Kadr --clip-test write|reload)

enum ClipSelfTest {
    static func run(phase: String) -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) {
            print("\(cond ? "OK " : "НЕТ") \(name)")
            if !cond { ok = false }
        }
        guard Profile.name != nil else { print("нужен KADR_PROFILE=<имя> — настоящие данные не трогаем"); return false }
        let dir = ClipStore.defaultDir
        let oldDir = dir.deletingLastPathComponent().appendingPathComponent(dir.lastPathComponent + ".old")
        let secret = "Пароль-Тест-7f3a91"
        let marker = "Kadr-маркер-текста-55c2"
        if phase == "write" {
            ClipCrypto.deleteKey()
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: oldDir)
            let store = ClipStore(dir: dir)
            check("ключ создан в связке ключей (\(store.keyState.rawValue))", store.keyState == .created && store.persistent)
            let pb = NSPasteboard(name: NSPasteboard.Name("uz.lutfulla.kadr.cliptest"))
            func put(_ fill: () -> Void) -> NSPasteboard { pb.clearContents(); fill(); return pb }
            let rtf = NSAttributedString(string: marker).rtf(from: NSRange(location: 0, length: (marker as NSString).length), documentAttributes: [:])
            var r = ClipRecorder.record(from: put { pb.setString(marker + "\nвторая строка", forType: .string); if let rtf { pb.setData(rtf, forType: .rtf) } },
                                        sourceID: "com.apple.TextEdit", sourceName: "TextEdit", store: store, skipPrivate: false)
            check("текст записан (с RTF)", r == nil && store.items.first?.kind == .text && store.items.first?.hasRTF == true)
            r = ClipRecorder.record(from: put { pb.setString("https://example.com/kadr-test", forType: .string) }, sourceID: nil, sourceName: nil, store: store, skipPrivate: false)
            check("ссылка распознана", r == nil && store.items.first?.kind == .link && store.items.first?.title == "example.com")
            let img = NSImage(size: NSSize(width: 64, height: 40), flipped: false) { rect in NSColor.systemRed.setFill(); rect.fill(); return true }
            let png = NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!
            r = ClipRecorder.record(from: put { pb.setData(png, forType: .png) }, sourceID: nil, sourceName: nil, store: store, skipPrivate: false)
            check("картинка записана с миниатюрой", r == nil && store.items.first?.kind == .image && store.items.first?.hasThumb == true && store.thumbnail(store.items[0]) != nil)
            r = ClipRecorder.record(from: put { pb.writeObjects([URL(fileURLWithPath: "/Applications/Kadr.app") as NSURL]) }, sourceID: nil, sourceName: nil, store: store, skipPrivate: false)
            check("файл записан", r == nil && store.items.first?.kind == .file && store.items.first?.title == "Kadr.app")
            r = ClipRecorder.record(from: put { pb.setString(secret, forType: .string); pb.setData(Data(), forType: .concealed) },
                                    sourceID: "com.apple.Passwords", sourceName: "Пароли", store: store, skipPrivate: false)
            check("пароль (скрытый тип) записан по умолчанию и помечен скрытым", r == nil && store.items.first?.concealed == true)
            check("в списке скрыт точками, глазом открывается", store.items.first?.shownTitle(revealed: false) == "••••••••" && store.items.first?.shownTitle(revealed: true) == secret)
            let before = store.items.count
            r = ClipRecorder.record(from: put { pb.setString("другой-пароль", forType: .string); pb.setData(Data(), forType: .concealed) },
                                    sourceID: nil, sourceName: nil, store: store, skipPrivate: true)
            check("с настройкой «не записывать пароли» скрытый пропущен", r != nil && store.items.count == before)
            r = ClipRecorder.record(from: put { pb.setString("из связки ключей", forType: .string) }, sourceID: "com.apple.keychainaccess", sourceName: nil, store: store, skipPrivate: true)
            check("с настройкой программа из списка исключений пропущена", r != nil && store.items.count == before)
            r = ClipRecorder.record(from: put { pb.setString("служебное", forType: .string); pb.setData(Data(), forType: .kadrInternal) }, sourceID: nil, sourceName: nil, store: store, skipPrivate: false)
            check("служебная запись Kadr пропущена всегда", r != nil && store.items.count == before)
            r = ClipRecorder.record(from: put { pb.setString(marker + "\nвторая строка", forType: .string) }, sourceID: nil, sourceName: nil, store: store, skipPrivate: false)
            check("повтор поднимается наверх, а не дублируется", store.items.count == before && store.items.first?.kind == .text)
            let a = UUID(), b = UUID(), c = UUID()
            var o = ClipHistoryView.updatedOrder([], selected: [c])
            o = ClipHistoryView.updatedOrder(o, selected: [a, c])
            o = ClipHistoryView.updatedOrder(o, selected: [a, b, c])
            check("порядок выделения сохраняется (c, a, b)", o == [c, a, b])
            check("снятие выделения убирает из порядка", ClipHistoryView.updatedOrder(o, selected: [a, b]) == [a, b])
            let w = NSPasteboard(name: NSPasteboard.Name("uz.lutfulla.kadr.cliptest2"))
            store.write([store.items.first { $0.concealed }!], plain: false, to: w)
            check("пароль при вставке помечен скрытым и служебным", w.types?.contains(.concealed) == true && w.types?.contains(.kadrInternal) == true && w.string(forType: .string) == secret)
            pb.releaseGlobally(); w.releaseGlobally()
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            let needles = [secret, marker, "example.com/kadr", "Kadr.app", "TextEdit"].map { Data($0.utf8) }
            let leaked = files.filter { u in guard let d = try? Data(contentsOf: u) else { return false }; return needles.contains { d.range(of: $0) != nil } }
            check("на диске \(files.count) файлов, открытого текста нет", !files.isEmpty && leaked.isEmpty)
            let perms = files.compactMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.posixPermissions] as? Int }
            let dperm = (try? FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int) ?? 0
            check("права: папка 0700, файлы 0600", dperm == 0o700 && perms.allSatisfy { $0 == 0o600 })
            print("записей: \(store.items.count)")
        } else if phase == "reload" {
            let store = ClipStore(dir: dir)
            check("после перезапуска ключ найден", store.keyState == .ok)
            check("после перезапуска записи на месте (5)", store.items.count == 5)
            check("содержимое расшифровано", store.items.contains { $0.text == secret && $0.concealed } && store.items.contains { $0.text.hasPrefix(marker) })
            check("RTF и картинка читаются", store.items.first { $0.hasRTF }.flatMap { store.readBlob($0.id, "rtf") } != nil
                  && store.items.first { $0.kind == .image }.flatMap { store.imageData($0) } != nil)
            let ro = ClipStore(dir: dir, readOnly: true)
            check("только чтение (для --profile-state) видит те же записи", ro.items.count == 5)
            store.setPinned(store.items.last!.id, true)
            store.maxItems = 3
            for i in 1...6 { store.add(ClipItem(kind: .text, text: "запись \(i)")) }
            check("ограничение 3 записи + закреплённая", store.items.count == 4 && store.items.filter { $0.pinned }.count == 1)
            store.maxItems = 0
            for i in 7...12 { store.add(ClipItem(kind: .text, text: "запись \(i)")) }
            check("0 — без ограничения", store.items.count == 10)
            var old = ClipItem(kind: .text, text: "старая запись")
            old.date = Date().addingTimeInterval(-40 * 86400)
            store.add(old)
            store.trim()
            check("по возрасту по умолчанию не удаляется", store.items.contains { $0.text == "старая запись" })
            store.maxDays = 30
            store.trim()
            check("с ограничением 30 дней старая удалена", !store.items.contains { $0.text == "старая запись" })
            ClipCrypto.deleteKey()
            let fresh = ClipStore(dir: dir)
            check("без ключа: новая пустая история (\(fresh.keyState.rawValue))", fresh.items.isEmpty && fresh.keyState == .restarted && fresh.persistent)
            ClipCrypto.deleteKey()
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: oldDir)
            if case .notFound = ClipCrypto.loadKey() { check("тестовый ключ удалён", true) } else { check("тестовый ключ удалён", false) }
        }
        return ok
    }
}
