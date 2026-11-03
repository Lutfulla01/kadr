// Kadr — настройки (UserDefaults) и описание горячих клавиш.
import AppKit
import Carbon.HIToolbox

struct HotkeySpec: Equatable {
    var keyCode: UInt32
    var modifiers: NSEvent.ModifierFlags

    static let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(HotkeySpec.relevant)
    }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if modifiers.contains(.command) { m |= UInt32(cmdKey) }
        if modifiers.contains(.option) { m |= UInt32(optionKey) }
        if modifiers.contains(.control) { m |= UInt32(controlKey) }
        if modifiers.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    var modifierSymbols: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s
    }

    var display: String { modifierSymbols + KeyNames.name(keyCode) }

    /// Символ для keyEquivalent пункта меню (пусто, если клавишу нельзя показать в меню).
    var menuKeyEquivalent: String { KeyNames.menuEquivalent(keyCode) }

    /// Системные сочетания снимков, которые Kadr не занимает.
    var isSystemScreenshotCombo: Bool {
        modifiers == [.command, .shift] &&
            [UInt32(kVK_ANSI_3), UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_5), UInt32(kVK_ANSI_6)].contains(keyCode)
    }
}

enum HotkeyAction: String, CaseIterable {
    case area, window, screen, ocr, shelf, textShelf, clipboard   // новые — только в конец (номера сочетаний)

    /// Действия-снимки (в меню идут первым блоком).
    static let captureCases: [HotkeyAction] = [.area, .window, .screen, .ocr]

    var title: String {
        switch self {
        case .area: return L("Capture Area")
        case .window: return L("Capture Window")
        case .screen: return L("Capture Screen")
        case .ocr: return L("Capture Text (OCR)")
        case .shelf: return L("New Shelf")
        case .textShelf: return L("Text Shelf")
        case .clipboard: return L("Clipboard History")
        }
    }

    var symbol: String {
        switch self {
        case .area: return "rectangle.dashed"
        case .window: return "macwindow"
        case .screen: return "display"
        case .ocr: return "text.viewfinder"
        case .shelf: return "tray"
        case .textShelf: return "text.badge.plus"
        case .clipboard: return "doc.on.clipboard"
        }
    }

    var defaultSpec: HotkeySpec {
        let m: NSEvent.ModifierFlags = [.option, .shift]
        switch self {
        case .area: return HotkeySpec(keyCode: UInt32(kVK_ANSI_4), modifiers: m)
        case .window: return HotkeySpec(keyCode: UInt32(kVK_ANSI_5), modifiers: m)
        case .screen: return HotkeySpec(keyCode: UInt32(kVK_ANSI_3), modifiers: m)
        case .ocr: return HotkeySpec(keyCode: UInt32(kVK_ANSI_2), modifiers: m)
        case .shelf: return HotkeySpec(keyCode: UInt32(kVK_ANSI_D), modifiers: m)
        case .textShelf: return HotkeySpec(keyCode: UInt32(kVK_ANSI_T), modifiers: m)
        case .clipboard: return HotkeySpec(keyCode: UInt32(kVK_ANSI_V), modifiers: m)
        }
    }
}

/// Для KVO: изменения из других процессов (`defaults write`, второе окно настроек) видны сразу.
extension UserDefaults {
    @objc dynamic var textShelfAutoHide: Int { integer(forKey: "textShelfAutoHide") }
    @objc dynamic var showStatusItem: Bool { bool(forKey: "showStatusItem") }
    @objc dynamic var clipEdge: Bool { bool(forKey: "clipEdge") }
    @objc dynamic var clipGesture: Bool { bool(forKey: "clipGesture") }
}

enum Prefs {
    /// KADR_PROFILE — отдельный тестовый профиль (свой набор настроек uz.lutfulla.kadr.<имя>);
    /// KADR_DEFAULTS_SUITE — отдельный набор настроек (проверка «первого запуска» без порчи настоящих).
    static let d: UserDefaults = (Profile.suiteName ?? ProcessInfo.processInfo.environment["KADR_DEFAULTS_SUITE"])
        .flatMap { UserDefaults(suiteName: $0) } ?? .standard

    static func registerDefaults() {
        d.register(defaults: [
            "format": "png",
            "openEditor": true,
            "windowShadow": true,
            "showHUD": true,
            "sound": false,
            "keepTableRows": false,
            "shakeEnabled": true,
            "shakeSensitivity": 1,
            "shelfRemoveAfterDrag": true,
            "idleShakeEnabled": false,
            "idleShakeSensitivity": 1,
            "textShelfAutoHide": 10,
            "pasteSeparator": "none",
            "importByParagraphs": false,
            "clipMaxItems": 1000,
            "clipMaxDays": 0,
            "clipSkipPrivate": false,
            "clipPasteSeparator": "tab",
            "clipPaused": false,
            "copySound": true,
            "copySoundVolume": 0.6,
            "showStatusItem": true,
            "clipEdge": false,
            "clipGesture": true,
            "clipGestureCopy": true,
            "clipEdgeSide": "right",
            "clipEdgeDelay": 0.25,
        ])
    }

    /// В тестовом профиле снимки никогда не попадают в настоящую папку владельца.
    static var defaultFolder: URL {
        if let p = ProcessInfo.processInfo.environment["KADR_SCREENSHOT_DIR"], !p.isEmpty { return URL(fileURLWithPath: p) }
        if Profile.name != nil { return Profile.dataDir.appendingPathComponent("Screenshots", isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Screenshots")
    }

    static var saveFolder: URL {
        get {
            if let p = ProcessInfo.processInfo.environment["KADR_SCREENSHOT_DIR"], !p.isEmpty { return URL(fileURLWithPath: p) }
            if let p = d.string(forKey: "saveFolder"), !p.isEmpty { return URL(fileURLWithPath: p) }
            return defaultFolder
        }
        set { d.set(newValue.path, forKey: "saveFolder") }
    }

    static var format: String { d.string(forKey: "format") == "jpeg" ? "jpeg" : "png" }
    static var openEditor: Bool { d.bool(forKey: "openEditor") }
    static var windowShadow: Bool { d.bool(forKey: "windowShadow") }
    static var showHUD: Bool { d.bool(forKey: "showHUD") }
    static var sound: Bool { d.bool(forKey: "sound") }
    static var keepTableRows: Bool { d.bool(forKey: "keepTableRows") }
    static var shakeEnabled: Bool { d.bool(forKey: "shakeEnabled") }
    static var shakeSensitivity: Int { d.integer(forKey: "shakeSensitivity") }
    static var shelfRemoveAfterDrag: Bool { d.bool(forKey: "shelfRemoveAfterDrag") }
    static var idleShakeEnabled: Bool { d.bool(forKey: "idleShakeEnabled") }
    static var idleShakeSensitivity: Int { d.integer(forKey: "idleShakeSensitivity") }
    static var textShelfAutoHide: Int { d.integer(forKey: "textShelfAutoHide") }
    static var pasteSeparator: String { d.string(forKey: "pasteSeparator") ?? "none" }
    static var importByParagraphs: Bool { d.bool(forKey: "importByParagraphs") }
    static var clipSkipPrivate: Bool { d.bool(forKey: "clipSkipPrivate") }
    static var copySound: Bool { d.bool(forKey: "copySound") }
    static var copySoundVolume: Double { let v = d.double(forKey: "copySoundVolume"); return min(max(v, 0), 1) }
    static var showStatusItem: Bool { d.bool(forKey: "showStatusItem") }
    static var clipEdge: Bool { d.bool(forKey: "clipEdge") }
    static var clipGesture: Bool { d.bool(forKey: "clipGesture") }
    static var clipGestureCopy: Bool { d.bool(forKey: "clipGestureCopy") }
    static var clipEdgeSide: String { d.string(forKey: "clipEdgeSide") ?? "right" }
    static var clipEdgeDelay: Double { let v = d.double(forKey: "clipEdgeDelay"); return v > 0 ? min(max(v, 0.1), 2) : 0.25 }
    static var clipPasteSeparator: String { d.string(forKey: "clipPasteSeparator") ?? "tab" }

    // Горячие клавиши: "код:модификаторы", "none" — выключено, нет ключа — по умолчанию.
    static func hotkey(_ a: HotkeyAction) -> HotkeySpec? {
        guard let s = d.string(forKey: "hotkey." + a.rawValue) else { return a.defaultSpec }
        if s == "none" { return nil }
        let parts = s.split(separator: ":")
        guard parts.count == 2, let code = UInt32(parts[0]), let mods = UInt(parts[1]) else { return a.defaultSpec }
        return HotkeySpec(keyCode: code, modifiers: NSEvent.ModifierFlags(rawValue: mods))
    }

    static func setHotkey(_ a: HotkeyAction, _ spec: HotkeySpec?) {
        if let spec {
            d.set("\(spec.keyCode):\(spec.modifiers.rawValue)", forKey: "hotkey." + a.rawValue)
        } else {
            d.set("none", forKey: "hotkey." + a.rawValue)
        }
    }

    static func resetHotkey(_ a: HotkeyAction) { d.removeObject(forKey: "hotkey." + a.rawValue) }

    // История последних снимков Kadr (пути, новые первыми).
    static var history: [String] {
        get { d.stringArray(forKey: "history") ?? [] }
        set { d.set(Array(newValue.prefix(10)), forKey: "history") }
    }

    static func addToHistory(_ url: URL) {
        var h = history.filter { $0 != url.path }
        h.insert(url.path, at: 0)
        history = h
    }
}

enum KeyNames {
    static let table: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
        kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
        kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
        kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
        kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
        kVK_Space: L("Space"), kVK_Return: "↩", kVK_Tab: "⇥",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
    ]

    static func name(_ code: UInt32) -> String { table[Int(code)] ?? "#\(code)" }

    static func menuEquivalent(_ code: UInt32) -> String {
        let c = Int(code)
        if c == kVK_Space { return " " }
        if c == kVK_Return { return "\r" }
        let fkeys: [Int: Int] = [kVK_F1: NSF1FunctionKey, kVK_F2: NSF2FunctionKey, kVK_F3: NSF3FunctionKey,
                                 kVK_F4: NSF4FunctionKey, kVK_F5: NSF5FunctionKey, kVK_F6: NSF6FunctionKey,
                                 kVK_F7: NSF7FunctionKey, kVK_F8: NSF8FunctionKey, kVK_F9: NSF9FunctionKey,
                                 kVK_F10: NSF10FunctionKey, kVK_F11: NSF11FunctionKey, kVK_F12: NSF12FunctionKey]
        if let f = fkeys[c], let u = UnicodeScalar(f) { return String(Character(u)) }
        guard let n = table[c], n.count == 1 else { return "" }
        return n.lowercased()
    }

    static func isFunctionKey(_ code: UInt32) -> Bool { (table[Int(code)] ?? "").hasPrefix("F") && name(code).count > 1 }
}
