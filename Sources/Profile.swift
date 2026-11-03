// Kadr — тестовый профиль (KADR_PROFILE=<имя>) и общая вставка по очереди.
// Профиль полностью отделён от настоящих данных владельца: свои настройки, папка данных, ключ в связке, замок.
import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum Profile {
    /// Имя профиля: только буквы, цифры, «-» и «_».
    static let name: String? = {
        guard let raw = ProcessInfo.processInfo.environment["KADR_PROFILE"] else { return nil }
        let ok = raw.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return ok.isEmpty ? nil : String(ok.prefix(40))
    }()

    static var suiteName: String? { name.map { "uz.lutfulla.kadr.\($0)" } }

    /// ~/Library/Application Support/Kadr или Kadr-<имя>.
    static let dataDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(name.map { "Kadr-\($0)" } ?? "Kadr", isDirectory: true)
    }()

    static var keychainAccount: String { name.map { "history-key-\($0)" } ?? "history-key" }
    static var lockName: String { name.map { "uz.lutfulla.kadr.profile-\($0).lock" } ?? "uz.lutfulla.kadr.main.lock" }
    static var runtimeStateURL: URL { dataDir.appendingPathComponent("runtime-state.json") }
}

// MARK: - Вставка по очереди (текстовая полка и история буфера)

enum SequentialPaster {
    private(set) static var busy = false

    /// Разделитель между элементами: tab, enter, newline (перевод строки вставкой), none.
    static func separatorTitle(_ s: String) -> String {
        switch s {
        case "tab": return "Tab"
        case "enter": return "Enter"
        case "newline": return "Перевод строки"
        default: return "Ничего"
        }
    }

    /// Есть ли «Универсальный доступ». Системный запрос — один раз и только по действию пользователя.
    static func ensureAccess() -> Bool {
        if AXIsProcessTrusted() { return true }
        if !Prefs.d.bool(forKey: "askedAccessibility") {
            Prefs.d.set(true, forKey: "askedAccessibility")
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        return false
    }

    static func openAccessibilitySettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(u)
        }
    }

    /// Каждый writer кладёт один элемент в буфер (после clearContents); затем ⌘V.
    /// Все записи помечаются служебным типом — история буфера их не сохраняет.
    static func run(_ writers: [(NSPasteboard) -> Void], separator: String, restore: Bool,
                    activate app: NSRunningApplication?, completion: @escaping () -> Void) {
        guard !busy, !writers.isEmpty else { return }
        busy = true
        let pb = NSPasteboard.general
        let saved = restore ? snapshot(pb) : nil
        var t = 0.18
        if let app, app.processIdentifier != getpid() {
            NSApp.yieldActivation(to: app)
            app.activate()
            t = 0.3   // дать программе вернуть фокус
        }
        func at(_ delay: Double, _ block: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block) }
        for (i, w) in writers.enumerated() {
            at(t) {
                pb.clearContents()
                w(pb)
                pb.setData(Data(), forType: .kadrInternal)
                postKey(CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
            }
            t += 0.18
            guard i < writers.count - 1 else { continue }
            switch separator {
            case "tab", "enter":
                at(t) { postKey(CGKeyCode(separator == "tab" ? kVK_Tab : kVK_Return), flags: []) }
                t += 0.12
            case "newline":
                at(t) {
                    pb.clearContents()
                    pb.setString("\n", forType: .string)
                    pb.setData(Data(), forType: .kadrInternal)
                    postKey(CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
                }
                t += 0.18
            default: break
            }
        }
        at(t + 0.35) {
            if let saved { restoreSnapshot(saved, to: pb) }
            busy = false
            completion()
        }
    }

    static func postKey(_ key: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }

    private static func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let v = item.data(forType: t) { d[t] = v } }
            return d
        }
    }

    private static func restoreSnapshot(_ s: [[NSPasteboard.PasteboardType: Data]], to pb: NSPasteboard) {
        pb.clearContents()
        guard !s.isEmpty else { return }
        let items: [NSPasteboardItem] = s.map { dict in
            let it = NSPasteboardItem()
            for (t, v) in dict { it.setData(v, forType: t) }
            return it
        }
        items.first?.setData(Data(), forType: .kadrInternal)
        pb.writeObjects(items)
    }
}
