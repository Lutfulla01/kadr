// Kadr — окно настроек (SwiftUI).
import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

final class HotkeyRecorderModel: ObservableObject {
    let action: HotkeyAction
    @Published var spec: HotkeySpec?
    @Published var recording = false
    @Published var hint = ""
    private var monitor: Any?
    var onChange: (() -> Void)?

    init(action: HotkeyAction) {
        self.action = action
        spec = Prefs.hotkey(action)
    }

    var label: String {
        if recording { return "Нажмите сочетание…" }
        return spec?.display ?? "Нет"
    }

    func start() {
        guard !recording else { stop(); return }
        recording = true
        hint = ""
        HotkeyCenter.shared.unregisterAll()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            self?.handle(e)
            return nil
        }
    }

    private func handle(_ e: NSEvent) {
        let code = UInt32(e.keyCode)
        if Int(code) == kVK_Escape { stop(); return }
        if Int(code) == kVK_Delete || Int(code) == kVK_ForwardDelete {
            spec = nil
            Prefs.setHotkey(action, nil)
            stop()
            return
        }
        let s = HotkeySpec(keyCode: code, modifiers: e.modifierFlags)
        let hasMod = !s.modifiers.intersection([.command, .option, .control]).isEmpty
        if !hasMod && !KeyNames.isFunctionKey(code) {
            hint = "Нужен ⌘, ⌥ или ⌃"
            NSSound.beep()
            return
        }
        if s.isSystemScreenshotCombo {
            hint = "Это системное сочетание — его не занимаем"
            NSSound.beep()
            return
        }
        spec = s
        Prefs.setHotkey(action, s)
        stop()
    }

    func reset() {
        Prefs.resetHotkey(action)
        spec = Prefs.hotkey(action)
        hint = ""
        HotkeyCenter.shared.reload()
        onChange?()
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = false
        HotkeyCenter.shared.reload()
        if HotkeyCenter.shared.failed.contains(action) { hint = "Сочетание занято другой программой" }
        onChange?()
    }
}

struct HotkeyRow: View {
    @ObservedObject var model: HotkeyRecorderModel

    var body: some View {
        HStack(spacing: 8) {
            Label(model.action.title, systemImage: model.action.symbol)
            Spacer()
            if !model.hint.isEmpty {
                Text(model.hint).font(.caption).foregroundStyle(.secondary)
            }
            Button(action: model.start) {
                Text(model.label)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .monospacedDigit()
                    .frame(minWidth: 110)
            }
            .help("Нажмите и введите новое сочетание. Delete — выключить, Esc — отмена")
            Button(action: model.reset) { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(.borderless)
                .help("Вернуть по умолчанию (\(model.action.defaultSpec.display))")
        }
    }
}

final class LoginItemModel: ObservableObject {
    @Published var status: SMAppService.Status = SMAppService.mainApp.status

    var isOn: Bool { status == .enabled || status == .requiresApproval }

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {}
        refresh()
    }

    func refresh() { status = SMAppService.mainApp.status }

    var statusText: String {
        switch status {
        case .enabled: return "Включено"
        case .requiresApproval: return "Ждёт разрешения: Системные настройки → Основные → Объекты входа"
        case .notRegistered: return "Выключено"
        case .notFound: return "Недоступно для этой копии приложения"
        @unknown default: return ""
        }
    }
}

final class FolderModel: ObservableObject {
    @Published var path = Prefs.saveFolder.path
}

struct SettingsView: View {
    @AppStorage("openEditor", store: Prefs.d) private var openEditor = true
    @AppStorage("windowShadow", store: Prefs.d) private var windowShadow = true
    @AppStorage("showHUD", store: Prefs.d) private var showHUD = true
    @AppStorage("sound", store: Prefs.d) private var sound = false
    @AppStorage("keepTableRows", store: Prefs.d) private var keepTableRows = false
    @AppStorage("format", store: Prefs.d) private var format = "png"
    @AppStorage("shakeEnabled", store: Prefs.d) private var shakeEnabled = true
    @AppStorage("shakeSensitivity", store: Prefs.d) private var shakeSensitivity = 1
    @AppStorage("shelfRemoveAfterDrag", store: Prefs.d) private var shelfRemoveAfterDrag = true
    @AppStorage("idleShakeEnabled", store: Prefs.d) private var idleShakeEnabled = false
    @AppStorage("idleShakeSensitivity", store: Prefs.d) private var idleShakeSensitivity = 1
    @AppStorage("textShelfAutoHide", store: Prefs.d) private var textShelfAutoHide = 10
    @AppStorage("pasteSeparator", store: Prefs.d) private var pasteSeparator = "none"
    @AppStorage("importByParagraphs", store: Prefs.d) private var importByParagraphs = false
    @AppStorage("showStatusItem", store: Prefs.d) private var showStatusItem = true
    @AppStorage("clipMaxItems", store: Prefs.d) private var clipMaxItems = 1000
    @AppStorage("clipMaxDays", store: Prefs.d) private var clipMaxDays = 0
    @AppStorage("clipSkipPrivate", store: Prefs.d) private var clipSkipPrivate = false
    @AppStorage("clipPasteSeparator", store: Prefs.d) private var clipPasteSeparator = "tab"
    @AppStorage("clipEdge", store: Prefs.d) private var clipEdge = false
    @AppStorage("clipGesture", store: Prefs.d) private var clipGesture = true
    @AppStorage("clipGestureCopy", store: Prefs.d) private var clipGestureCopy = true
    @AppStorage("clipEdgeSide", store: Prefs.d) private var clipEdgeSide = "right"
    @AppStorage("clipEdgeDelay", store: Prefs.d) private var clipEdgeDelay = 0.25
    @AppStorage("clipIgnore", store: Prefs.d) private var clipIgnore = ClipRecorder.defaultIgnore.joined(separator: "\n")
    @StateObject private var folderModel = FolderModel()
    private var folder: String { folderModel.path }
    @StateObject private var login = LoginItemModel()
    let recorders: [HotkeyRecorderModel]

    var body: some View {
        Form {
            Section("Горячие клавиши") {
                ForEach(recorders, id: \.action) { HotkeyRow(model: $0) }
            }
            Section("Сохранение") {
                HStack {
                    Label {
                        Text(abbreviated(folder)).lineLimit(1).truncationMode(.middle)
                    } icon: { Image(systemName: "folder") }
                    Spacer()
                    Button("Выбрать…", action: chooseFolder)
                }
                Picker("Формат файла", selection: $format) {
                    Text("PNG").tag("png")
                    Text("JPEG").tag("jpeg")
                }
                .pickerStyle(.segmented)
            }
            Section("Снимок") {
                Toggle("Открывать редактор после снимка", isOn: $openEditor)
                Toggle("Тень у снимка окна", isOn: $windowShadow)
                Toggle("Звук затвора", isOn: $sound)
            }
            Section("Текст с экрана") {
                Toggle("Подсказка «Текст скопирован»", isOn: $showHUD)
                Toggle("Сохранять строки таблиц (колонки через Tab)", isOn: $keepTableRows)
            }
            Section("Полка") {
                Toggle("Открывать полку встряхиванием", isOn: $shakeEnabled)
                Picker("Чувствительность", selection: $shakeSensitivity) {
                    Text("Низкая").tag(0)
                    Text("Средняя").tag(1)
                    Text("Высокая").tag(2)
                }
                .pickerStyle(.segmented)
                .disabled(!shakeEnabled)
                Toggle("Убирать с полки после перетаскивания", isOn: $shelfRemoveAfterDrag)
                if !ShakeMonitor.shared.available {
                    Text("Система не дала следить за перетаскиванием: встряхивание не сработает, полка открывается сочетанием или из меню.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Текстовая полка") {
                Toggle("Открывать текстовую полку встряхиванием без перетаскивания", isOn: $idleShakeEnabled)
                Picker("Чувствительность", selection: $idleShakeSensitivity) {
                    Text("Низкая").tag(0)
                    Text("Средняя").tag(1)
                    Text("Высокая").tag(2)
                }
                .pickerStyle(.segmented)
                .disabled(!idleShakeEnabled)
                Picker("Скрывать без действий", selection: $textShelfAutoHide) {
                    Text("Никогда").tag(0)
                    Text("5 с").tag(5)
                    Text("10 с").tag(10)
                    Text("30 с").tag(30)
                }
                Picker("Между фрагментами при вставке", selection: $pasteSeparator) {
                    Text("Ничего").tag("none")
                    Text("Enter").tag("enter")
                    Text("Tab").tag("tab")
                }
                Toggle("Импорт буфера по абзацам (иначе по строкам)", isOn: $importByParagraphs)
            }
            Section("История буфера") {
                Picker("Хранить записей", selection: $clipMaxItems) {
                    Text("100").tag(100)
                    Text("500").tag(500)
                    Text("1000").tag(1000)
                    Text("5000").tag(5000)
                    Text("Без ограничения").tag(0)
                }
                Picker("Удалять старше", selection: $clipMaxDays) {
                    Text("Не удалять").tag(0)
                    Text("7 дней").tag(7)
                    Text("30 дней").tag(30)
                    Text("90 дней").tag(90)
                }
                Picker("Между записями при вставке нескольких", selection: $clipPasteSeparator) {
                    Text("Tab").tag("tab")
                    Text("Enter").tag("enter")
                    Text("Перевод строки").tag("newline")
                    Text("Ничего").tag("none")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Вызов панели истории").font(.subheadline)
                    Toggle("Нажатие тремя пальцами", isOn: $clipGesture)
                    Toggle("Нажатие тремя пальцами при выделенном тексте — копировать", isOn: $clipGestureCopy)
                        .disabled(!clipGesture)
                        .padding(.leading, 18)
                    Text("Нажмите тачпад тремя пальцами до щелчка — панель выедет сбоку; тот же жест её прячет. Панель не прячется от щелчка мимо: можно щёлкнуть в поле и вставить. Если в программе выделен текст, тот же жест его копирует.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let problem = GestureTrigger.shared.problem {
                        Text(problem).font(.caption).foregroundStyle(.orange)
                    }
                    Toggle("Край экрана", isOn: $clipEdge)
                    if clipEdge {
                        Picker("Задержка у края", selection: $clipEdgeDelay) {
                            Text("0,15 с").tag(0.15)
                            Text("0,25 с").tag(0.25)
                            Text("0,5 с").tag(0.5)
                        }
                        Text("Упритесь курсором во внешний край — выедет история. Не срабатывает при перетаскивании, прокрутке, на стыке мониторов и поверх полноэкранных программ.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("Сторона панели", selection: $clipEdgeSide) {
                        Text("Справа").tag("right")
                        Text("Слева").tag("left")
                    }
                }
                Toggle("Не записывать пароли и скрытые записи", isOn: $clipSkipPrivate)
                if clipSkipPrivate {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Не записывать из программ (идентификаторы, по одному в строке):")
                            .font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $clipIgnore)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(height: 74)
                    }
                }
                HStack {
                    Text("Закреплённые записи не удаляются. История зашифрована и хранится только на этом Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Очистить историю…") { confirmClearClipboard() }
                        .controlSize(.small)
                }
            }
            .onChange(of: clipMaxItems) { _, _ in ClipStore.shared.applyLimitsFromPrefs() }
            .onChange(of: clipMaxDays) { _, _ in ClipStore.shared.applyLimitsFromPrefs() }
            Section("Система") {
                Toggle("Показывать значок в строке меню", isOn: $showStatusItem)
                Text("Если значка не видно, его могла спрятать macOS: Системные настройки → Строка меню → разрешите Kadr; на ноутбуке он может прятаться за вырезом экрана. Эти настройки всегда открываются повторным запуском Kadr из «Программ».")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Запускать при входе", isOn: Binding(get: { login.isOn }, set: { login.set($0) }))
                    .disabled(Profile.name != nil)
                HStack {
                    Text(login.statusText).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if login.status == .requiresApproval {
                        Button("Открыть настройки") { SMAppService.openSystemSettingsLoginItems() }
                            .controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: min(760, (NSScreen.main?.visibleFrame.height ?? 800) - 60))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            login.refresh()
        }
    }

    private func confirmClearClipboard() {
        let a = NSAlert()
        a.messageText = "Очистить историю буфера?"
        a.informativeText = "Будут удалены все записи, кроме закреплённых. Это нельзя отменить."
        a.addButton(withTitle: "Очистить")
        a.addButton(withTitle: "Отмена")
        a.buttons.first?.hasDestructiveAction = true
        if a.runModal() == .alertFirstButtonReturn { ClipStore.shared.clear(keepPinned: true) }
    }

    private func abbreviated(_ p: String) -> String { (p as NSString).abbreviatingWithTildeInPath }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Prefs.saveFolder
        panel.prompt = "Выбрать"
        if panel.runModal() == .OK, let url = panel.url {
            Prefs.saveFolder = url
            folderModel.path = url.path
        }
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static var shared: SettingsWindowController?

    static func show(onHotkeysChanged: @escaping () -> Void) {
        if shared == nil {
            let recs = HotkeyAction.allCases.map { a -> HotkeyRecorderModel in
                let m = HotkeyRecorderModel(action: a)
                m.onChange = onHotkeysChanged
                return m
            }
            let host = NSHostingController(rootView: SettingsView(recorders: recs))
            let win = NSWindow(contentViewController: host)
            win.title = "Настройки Kadr"
            win.styleMask = [.titled, .closable]
            win.isReleasedWhenClosed = false
            win.isRestorable = false
            win.identifier = NSUserInterfaceItemIdentifier("kadr.settings")
            win.setAccessibilityIdentifier("kadr.settings")
            let wc = SettingsWindowController(window: win)
            win.delegate = wc
            shared = wc
            win.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        shared?.window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        SettingsWindowController.shared = nil
    }
}
