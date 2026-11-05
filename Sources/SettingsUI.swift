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
        if recording { return L("Type Shortcut…") }
        return spec?.display ?? L("Not Set")
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
            hint = L("Use ⌘, ⌥ or ⌃")
            NSSound.beep()
            return
        }
        if s.isSystemScreenshotCombo {
            hint = L("Reserved by macOS")
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
        if HotkeyCenter.shared.failed.contains(action) { hint = L("Used by another app") }
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
            .help("Click and type a new shortcut. Delete clears it, Esc cancels.")
            Button(action: model.reset) { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(.borderless)
                .help(Lf("Reset to default (%@)", model.action.defaultSpec.display))
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
        case .enabled: return L("Enabled")
        case .requiresApproval: return L("Needs approval: System Settings → General → Login Items")
        case .notRegistered: return L("Disabled")
        case .notFound: return L("Not available for this copy of the app")
        @unknown default: return ""
        }
    }
}

/// Язык интерфейса Kadr: "en", "ru" или "system" (ключа AppleLanguages в домене приложения нет). Действует после перезапуска.
final class LanguageModel: ObservableObject {
    @Published var value = LanguageModel.stored() {
        didSet { if value != oldValue { LanguageModel.apply(value) } }
    }

    func reload() {
        let v = LanguageModel.stored()
        if v != value { value = v }
    }

    static func stored() -> String {
        let domain = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) }
        switch (domain?["AppleLanguages"] as? [String])?.first?.prefix(2) {
        case "en": return "en"
        case "ru": return "ru"
        default: return "system"
        }
    }

    static func apply(_ lang: String) {
        if lang == "en" || lang == "ru" {
            UserDefaults.standard.set([lang], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
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
    @AppStorage("clipGesture", store: Prefs.d) private var clipGesture = false
    @AppStorage("clipGestureCopy", store: Prefs.d) private var clipGestureCopy = true
    @AppStorage("copySound", store: Prefs.d) private var copySound = true
    @AppStorage("copySoundVolume", store: Prefs.d) private var copySoundVolume = 0.6
    @AppStorage("clipEdgeSide", store: Prefs.d) private var clipEdgeSide = "right"
    @AppStorage("clipEdgeDelay", store: Prefs.d) private var clipEdgeDelay = 0.25
    @AppStorage("clipIgnore", store: Prefs.d) private var clipIgnore = ClipRecorder.defaultIgnore.joined(separator: "\n")
    @StateObject private var folderModel = FolderModel()
    private var folder: String { folderModel.path }
    @StateObject private var login = LoginItemModel()
    @StateObject private var language = LanguageModel()
    let recorders: [HotkeyRecorderModel]

    var body: some View {
        Form {
            Section("Keyboard Shortcuts") {
                ForEach(recorders, id: \.action) { HotkeyRow(model: $0) }
            }
            Section("Saving") {
                HStack {
                    Label {
                        Text(abbreviated(folder)).lineLimit(1).truncationMode(.middle)
                    } icon: { Image(systemName: "folder") }
                    Spacer()
                    Button("Choose…", action: chooseFolder)
                }
                Picker("File format", selection: $format) {
                    Text("PNG").tag("png")
                    Text("JPEG").tag("jpeg")
                }
                .pickerStyle(.segmented)
            }
            Section("Screenshots") {
                Toggle("Open editor after capture", isOn: $openEditor)
                Toggle("Window shadow in window captures", isOn: $windowShadow)
                Toggle("Shutter sound", isOn: $sound)
            }
            Section("Text Recognition") {
                Toggle("Show “Text Copied” notice", isOn: $showHUD)
                Toggle("Keep table rows (columns separated by tabs)", isOn: $keepTableRows)
            }
            Section("Shelf") {
                Toggle("Shake while dragging to open a shelf", isOn: $shakeEnabled)
                Picker("Sensitivity", selection: $shakeSensitivity) {
                    Text("Low").tag(0)
                    Text("Medium").tag(1)
                    Text("High").tag(2)
                }
                .pickerStyle(.segmented)
                .disabled(!shakeEnabled)
                Toggle("Remove items from shelf after dragging out", isOn: $shelfRemoveAfterDrag)
                if !ShakeMonitor.shared.available {
                    Text("macOS didn’t allow drag tracking, so shaking won’t work. Open a shelf with the shortcut or from the menu.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Text Shelf") {
                Toggle("Shake the pointer to open the text shelf (no dragging)", isOn: $idleShakeEnabled)
                Picker("Sensitivity", selection: $idleShakeSensitivity) {
                    Text("Low").tag(0)
                    Text("Medium").tag(1)
                    Text("High").tag(2)
                }
                .pickerStyle(.segmented)
                .disabled(!idleShakeEnabled)
                Picker("Hide when idle", selection: $textShelfAutoHide) {
                    Text("Never").tag(0)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                    Text("30 seconds").tag(30)
                }
                Picker("Separator when pasting", selection: $pasteSeparator) {
                    Text("None").tag("none")
                    Text("Enter").tag("enter")
                    Text("Tab").tag("tab")
                }
                Toggle("Import clipboard by paragraph (otherwise by line)", isOn: $importByParagraphs)
            }
            Section("Clipboard History") {
                Picker("Items to keep", selection: $clipMaxItems) {
                    Text("100").tag(100)
                    Text("500").tag(500)
                    Text("1000").tag(1000)
                    Text("5000").tag(5000)
                    Text("Unlimited").tag(0)
                }
                Picker("Keep history for", selection: $clipMaxDays) {
                    Text("Forever").tag(0)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                Picker("Separator when pasting multiple items", selection: $clipPasteSeparator) {
                    Text("Tab").tag("tab")
                    Text("Enter").tag("enter")
                    Text("Line Break").tag("newline")
                    Text("None").tag("none")
                }
                Toggle("Sound on copy", isOn: $copySound)
                if copySound {
                    HStack(spacing: 10) {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                        Slider(value: $copySoundVolume, in: 0.05...1)
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                        Button("Preview") { CopySound.preview(volume: copySoundVolume) }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Open the history panel with").font(.subheadline)
                    Toggle("Three-finger press", isOn: $clipGesture)
                    Toggle("Three-finger press on selected text copies it", isOn: $clipGestureCopy)
                        .disabled(!clipGesture)
                        .padding(.leading, 18)
                    Text("Off by default. Press the trackpad with three fingers until it clicks, and the panel slides in from the side. The same gesture hides it. If text is selected in an app, it copies it instead. While it’s on, a two-finger right-click can arrive up to 90 ms later. If three-finger drag is on in System Settings, Kadr stays out of its way and the gesture does nothing.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let problem = GestureTrigger.shared.problem {
                        Text(problem).font(.caption).foregroundStyle(.orange)
                    }
                    Toggle("Screen edge", isOn: $clipEdge)
                    if clipEdge {
                        Picker("Edge delay", selection: $clipEdgeDelay) {
                            Text("0.15 seconds").tag(0.15)
                            Text("0.25 seconds").tag(0.25)
                            Text("0.5 seconds").tag(0.5)
                        }
                        Text("Push the pointer against the outer screen edge to reveal history. Doesn’t trigger while dragging or scrolling, between displays, or over full-screen apps.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("Panel side", selection: $clipEdgeSide) {
                        Text("Right").tag("right")
                        Text("Left").tag("left")
                    }
                }
                Toggle("Skip passwords and concealed items", isOn: $clipSkipPrivate)
                if clipSkipPrivate {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Ignore these apps (bundle IDs, one per line):")
                            .font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $clipIgnore)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(height: 74)
                    }
                }
                HStack {
                    Text("Pinned items are never deleted. History is encrypted and stays on this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear History…") { confirmClearClipboard() }
                        .controlSize(.small)
                }
            }
            .onChange(of: clipMaxItems) { _, _ in ClipStore.shared.applyLimitsFromPrefs() }
            .onChange(of: clipMaxDays) { _, _ in ClipStore.shared.applyLimitsFromPrefs() }
            Section("General") {
                Toggle("Show icon in menu bar", isOn: $showStatusItem)
                Text("If the icon isn’t visible, macOS may have hidden it: System Settings → Menu Bar → allow Kadr. On a laptop it can also hide behind the notch. You can always open these settings by launching Kadr again from Applications.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Launch at login", isOn: Binding(get: { login.isOn }, set: { login.set($0) }))
                    .disabled(Profile.name != nil)
                HStack {
                    Text(login.statusText).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if login.status == .requiresApproval {
                        Button("Open System Settings") { SMAppService.openSystemSettingsLoginItems() }
                            .controlSize(.small)
                    }
                }
                Picker("Language", selection: $language.value) {
                    Text("System").tag("system")
                    Text(verbatim: "English").tag("en")
                    Text(verbatim: "Русский").tag("ru")
                }
                Text("Takes effect after you restart Kadr.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Label("Welcome tour", systemImage: "hand.wave")
                    Spacer()
                    Button("Show Welcome Tour") { OnboardingController.show() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: min(760, (NSScreen.main?.visibleFrame.height ?? 800) - 60))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            login.refresh()
        }
        .onAppear { language.reload() }
    }

    private func confirmClearClipboard() {
        let a = NSAlert()
        a.messageText = L("Clear Clipboard History?")
        a.informativeText = L("All items except pinned ones will be deleted. You can’t undo this.")
        a.addButton(withTitle: L("Clear"))
        a.addButton(withTitle: L("Cancel"))
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
        panel.prompt = L("Choose")
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
            win.title = L("Kadr Settings")
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
