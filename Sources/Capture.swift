// Kadr — снимок через /usr/sbin/screencapture, сохранение, буфер обмена.
import AppKit
import ImageIO
import UniformTypeIdentifiers

enum CaptureMode { case area, window, screen }

enum CaptureResult {
    case cancelled
    case noPermission
    case ok(URL) // временный PNG
}

// MARK: - Загрузка / запись картинок

struct LoadedImage {
    let cg: CGImage
    let pxPerPt: CGFloat // 2 для Retina-снимков (PNG с 144 DPI), иначе 1
}

enum ImageFiles {
    static func load(_ url: URL) -> LoadedImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              // Декодируем сразу: файл может быть удалён до того, как картинку начнут читать (OCR в фоне).
              let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        var k: CGFloat = 1
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let dpi = props[kCGImagePropertyDPIWidth] as? Double, dpi > 72.5 {
            k = CGFloat(max(1, min(4, (dpi / 72).rounded())))
        }
        return LoadedImage(cg: cg, pxPerPt: k)
    }

    static func data(_ cg: CGImage, type: UTType, pxPerPt: CGFloat) -> Data? {
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72 * Double(pxPerPt),
            kCGImagePropertyDPIHeight: 72 * Double(pxPerPt),
        ]
        if type == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = 0.9 }
        CGImageDestinationAddImage(dst, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return nil }
        return out as Data
    }

    static func type(for url: URL) -> UTType {
        ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) ? .jpeg : .png
    }

    @discardableResult
    static func write(_ cg: CGImage, to url: URL, pxPerPt: CGFloat) -> Bool {
        guard let d = data(cg, type: type(for: url), pxPerPt: pxPerPt) else { return false }
        return (try? d.write(to: url, options: .atomic)) != nil
    }

    /// Буфер обмена: картинкой (NSImage) + PNG-данные.
    static func copyToClipboard(_ cg: CGImage, pxPerPt: CGFloat) {
        let size = NSSize(width: CGFloat(cg.width) / pxPerPt, height: CGFloat(cg.height) / pxPerPt)
        let img = NSImage(cgImage: cg, size: size)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([img])
        if let png = data(cg, type: .png, pxPerPt: pxPerPt) { pb.setData(png, forType: .png) }
    }

    static func copyText(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    /// Почти чёрная картинка = признак отсутствия разрешения «Запись экрана».
    static func looksBlank(_ cg: CGImage) -> Bool {
        let w = 24, h = 24
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let p = ctx.data?.bindMemory(to: UInt8.self, capacity: w * h * 4) else { return false }
        for i in 0..<(w * h) {
            let r = p[i * 4], g = p[i * 4 + 1], b = p[i * 4 + 2], a = p[i * 4 + 3]
            if a > 8 && max(r, max(g, b)) > 4 { return false }
        }
        return true
    }

    static func thumbnail(_ url: URL, maxPixel: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let scale = CGFloat(max(cg.width, cg.height)) / CGFloat(maxPixel) * 2
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale))
    }
}

// MARK: - Снимок

final class CaptureService {
    static let shared = CaptureService()
    private(set) var busy = false

    private var current: Process?
    private var startedAt = Date.distantPast

    func run(_ mode: CaptureMode, completion: @escaping (CaptureResult) -> Void) {
        if busy {
            // Зависший screencapture не должен навсегда глотать сочетания.
            if let p = current, p.isRunning, Date().timeIntervalSince(startedAt) > 20 {
                KadrLog.write("снимок \(mode): прежний screencapture висит \(Int(Date().timeIntervalSince(startedAt))) с — останавливаю")
                p.terminate()
            } else {
                KadrLog.write("снимок \(mode): пропущен — уже идёт снимок (\(String(format: "%.1f", Date().timeIntervalSince(startedAt))) с)")
                return
            }
        }
        busy = true
        startedAt = Date()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-\(UUID().uuidString).png")
        var args: [String] = []
        if !Prefs.sound { args.append("-x") }
        switch mode {
        case .area:
            args += ["-i"]
            if !Prefs.windowShadow { args.append("-o") }
        case .window:
            args += ["-i", "-W"]
            if !Prefs.windowShadow { args.append("-o") }
        case .screen:
            args += ["-D", String(Self.displayIndexUnderCursor())]
        }
        args += ["-t", "png", tmp.path]

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let t0 = Date()
        p.terminationHandler = { proc in
            let status = proc.terminationStatus
            let reason = proc.terminationReason == .uncaughtSignal ? "сигнал" : "выход"
            DispatchQueue.main.async {
                self.busy = false
                self.current = nil
                let size = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int) ?? 0
                let dur = String(format: "%.2f", Date().timeIntervalSince(t0))
                if size <= 0 {
                    try? FileManager.default.removeItem(at: tmp)
                    // Отмена (Esc) даёт пустой результат; ошибка при неотменяемом режиме — нет прав.
                    let noPerm = mode == .screen && status != 0
                    KadrLog.write("снимок \(mode): \(reason) \(status), файла нет, \(dur) с → \(noPerm ? "нет разрешения" : "отмена")")
                    if noPerm { completion(.noPermission) } else { completion(.cancelled) }
                    return
                }
                if let img = ImageFiles.load(tmp), ImageFiles.looksBlank(img.cg) {
                    try? FileManager.default.removeItem(at: tmp)
                    KadrLog.write("снимок \(mode): \(reason) \(status), файл \(size) Б, чёрный → нет разрешения")
                    completion(.noPermission)
                    return
                }
                KadrLog.write("снимок \(mode): \(reason) \(status), файл \(size) Б, \(dur) с → готово")
                completion(.ok(tmp))
            }
        }
        do {
            try p.run()
            current = p
            KadrLog.write("снимок \(mode): запущен screencapture \(args.joined(separator: " ")) (pid \(p.processIdentifier))")
        } catch {
            busy = false
            current = nil
            KadrLog.write("снимок \(mode): screencapture не запустился: \(error.localizedDescription)")
            completion(.noPermission)
        }
    }

    /// Номер дисплея для `screencapture -D` (1 — главный), под курсором.
    static func displayIndexUnderCursor() -> Int {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
              let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return 1 }
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        if let i = ids.firstIndex(of: CGDirectDisplayID(num.uint32Value)) { return i + 1 }
        return 1
    }

    /// Переносит временный PNG в папку снимков под именем «Kadr ГГГГ-ММ-ДД в ЧЧ.ММ.СС».
    static func save(temp: URL) -> URL? {
        let folder = Prefs.saveFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'в' HH.mm.ss"
        let ext = Prefs.format == "jpeg" ? "jpg" : "png"
        let base = "Kadr \(f.string(from: Date()))"
        var url = folder.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        if ext == "png" {
            do { try FileManager.default.moveItem(at: temp, to: url) } catch {
                guard (try? FileManager.default.copyItem(at: temp, to: url)) != nil else { return nil }
                try? FileManager.default.removeItem(at: temp)
            }
            return url
        }
        guard let img = ImageFiles.load(temp), ImageFiles.write(img.cg, to: url, pxPerPt: img.pxPerPt) else { return nil }
        try? FileManager.default.removeItem(at: temp)
        return url
    }
}


/// Короткий журнал снимков: ~/Library/Logs/Kadr.log (у профиля — Kadr-<имя>.log). Только локально.
enum KadrLog {
    static let url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/\(Profile.name.map { "Kadr-\($0)" } ?? "Kadr").log")
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ line: String) {
        let text = "\(fmt.string(from: Date())) \(line)\n"
        let fm = FileManager.default
        if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int, size > 1_000_000 {
            try? fm.removeItem(at: url.deletingPathExtension().appendingPathExtension("old.log"))
            try? fm.moveItem(at: url, to: url.deletingPathExtension().appendingPathExtension("old.log"))
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(text.data(using: .utf8)!)
            try? h.close()
        } else {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.data(using: .utf8)!.write(to: url)
        }
    }
}
