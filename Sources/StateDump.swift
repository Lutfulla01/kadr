// Kadr — состояние для сквозных проверок: работающий экземпляр профиля пишет runtime-state.json,
// `KADR_PROFILE=<имя> Kadr --profile-state` печатает сводку JSON (только чтение).
import AppKit
import ApplicationServices

enum RuntimeState {
    private static var timer: Timer?
    private static var last = Data()
    private static let iso = ISO8601DateFormatter()

    /// Только для тестового профиля: настоящий Kadr ничего лишнего не пишет.
    static func start() {
        guard Profile.name != nil else { return }
        try? FileManager.default.createDirectory(at: Profile.dataDir, withIntermediateDirectories: true)
        let t = Timer(timeInterval: 0.5, repeats: true) { _ in write() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        write()
    }

    static func snapshot(running: Bool = true) -> [String: Any] {
        let shelves: [[String: Any]] = ShelfPanel.all.filter { $0.isVisible }.map {
            ["items": $0.items.count, "expanded": $0.expanded, "openedByShake": $0.openedByShake,
             "titles": $0.items.prefix(10).map { $0.title }]
        }
        let windows = NSApp.windows.filter { $0.isVisible }
        return [
            "pid": Int(getpid()),
            "running": running,
            "updated": "",
            "openShelves": shelves,
            "textShelfVisible": TextShelfPanel.shared.isVisible,
            "textShelfPinned": TextShelfPanel.shared.pinned,
            "clipHistoryVisible": ClipHistoryPanel.shared.isVisible,
            "clipEdgeVisible": ClipHistoryPanel.edgeIfCreated?.isVisible ?? false,
            "clipEdgeOpens": EdgeTrigger.shared.opens,
            "clipEdgeSticky": ClipHistoryPanel.edgeIfCreated?.sticky ?? false,
            "clipEdgeFilter": ClipHistoryPanel.edgeIfCreated?.view.filter.title ?? "",
            "clipEdgePinnedTab": ClipHistoryPanel.edgeIfCreated?.view.pinnedTab ?? false,
            "clipEdgeSearching": ClipHistoryPanel.edgeIfCreated?.view.searching ?? false,
            "clipEdgeShown": ClipHistoryPanel.edgeIfCreated.map { $0.isVisible ? $0.view.shown.count : -1 } ?? -1,
            "gestureAvailable": GestureTrigger.shared.available,
            "gestureTap": GestureTrigger.shared.tapActive,
            "gestureDevices": GestureTrigger.shared.deviceCount,
            "gestureToggles": GestureTrigger.shared.toggles,
            "gestureCopies": GestureTrigger.shared.copies,
            "gestureLast": GestureTrigger.shared.lastDecision,
            "hudCount": HUD.shownCount,
            "copySound": Prefs.copySound,
            "tickPlays": CopySound.plays,
            "tickLimited": CopySound.limited,
            "tickLatencyMs": CopySound.lastLatencyMs,
            "hudText": HUD.lastText,
            "clipEdgeKey": ClipHistoryPanel.edgeIfCreated?.isKeyWindow ?? false,
            "clipEdgeSelection": ClipHistoryPanel.edgeIfCreated.map { $0.isVisible ? $0.view.selectedItems.map { $0.shownTitle(revealed: false) } : [] } ?? [],
            "clipHistorySelection": ClipHistoryPanel.shared.isVisible ? ClipHistoryPanel.shared.view.selectedItems.map { $0.shownTitle(revealed: false) } : [],
            "editorWindows": windows.filter { $0 is EditorWindow }.count,
            "pinWindows": windows.filter { $0 is PinWindow }.count,
            "settingsVisible": windows.contains { $0.identifier?.rawValue == "kadr.settings" },
            "axTrusted": AXIsProcessTrusted(),
            "screenRecording": CGPreflightScreenCaptureAccess(),
            "clipPaused": ClipMonitor.shared.paused,
            "clipKey": ClipStore.shared.keyState.rawValue,
            "pasting": SequentialPaster.busy,
        ]
    }

    static func write(running: Bool = true) {
        guard Profile.name != nil else { return }
        var snap = snapshot(running: running)
        // Пишем только при изменении (время обновления в сравнении не участвует).
        snap["updated"] = nil
        guard let core = try? JSONSerialization.data(withJSONObject: snap, options: [.sortedKeys]), core != last else { return }
        last = core
        snap["updated"] = iso.string(from: Date())
        if let d = try? JSONSerialization.data(withJSONObject: snap, options: [.sortedKeys]) {
            try? d.write(to: Profile.runtimeStateURL, options: .atomic)
        }
    }

    static func stop() {
        timer?.invalidate()
        write(running: false)
    }
}

enum ProfileState {
    static func dump() -> Int32 {
        guard let name = Profile.name else {
            FileHandle.standardError.write("нужен KADR_PROFILE=<имя>\n".data(using: .utf8)!)
            return 2
        }
        var out: [String: Any] = [
            "profile": name,
            "dataDir": Profile.dataDir.path,
            "defaultsSuite": Profile.suiteName ?? "",
            "saveFolder": Prefs.saveFolder.path,
        ]
        // Работающий экземпляр.
        var runtime: [String: Any]?
        if let d = try? Data(contentsOf: Profile.runtimeStateURL),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            let pid = (j["pid"] as? Int) ?? 0
            let alive = pid > 0 && kill(pid_t(pid), 0) == 0 && (j["running"] as? Bool ?? false)
            var r = j
            r["alive"] = alive
            runtime = r
        }
        out["running"] = runtime?["alive"] as? Bool ?? false
        out["runtime"] = runtime ?? NSNull()
        out["openShelves"] = (runtime?["alive"] as? Bool ?? false) ? (runtime?["openShelves"] ?? []) : []
        // Текстовая полка.
        let snippets = TextShelfStore.load()
        out["textShelf"] = ["count": snippets.count, "selected": snippets.filter { $0.selected }.count,
                            "titles": snippets.prefix(10).map { $0.title }]
        // История буфера (только чтение, ключ не создаётся).
        let store = ClipStore(dir: ClipStore.defaultDir, readOnly: true)
        out["clipboard"] = [
            "count": store.items.count,
            "pinned": store.items.filter { $0.pinned }.count,
            "key": store.keyState.rawValue,
            "last": store.items.prefix(5).map { ["kind": $0.kind.rawValue, "title": $0.shownTitle(revealed: false),
                                                 "concealed": $0.concealed, "pinned": $0.pinned,
                                                 "source": $0.sourceName ?? ""] as [String: Any] },
        ] as [String: Any]
        var hk: [String: String] = [:]
        for a in HotkeyAction.allCases { hk[a.rawValue] = Prefs.hotkey(a)?.display ?? "нет" }
        out["hotkeys"] = hk
        out["prefs"] = ["idleShakeEnabled": Prefs.idleShakeEnabled, "shakeEnabled": Prefs.shakeEnabled,
                        "clipMaxItems": Prefs.d.integer(forKey: "clipMaxItems"), "clipMaxDays": Prefs.d.integer(forKey: "clipMaxDays"),
                        "clipSkipPrivate": Prefs.clipSkipPrivate, "clipPasteSeparator": Prefs.clipPasteSeparator,
                        "pasteSeparator": Prefs.pasteSeparator, "textShelfAutoHide": Prefs.textShelfAutoHide,
                        "clipPaused": Prefs.d.bool(forKey: "clipPaused")] as [String: Any]
        let screenshots = (try? FileManager.default.contentsOfDirectory(atPath: Prefs.saveFolder.path))?.filter { $0.hasPrefix("Kadr ") } ?? []
        out["screenshots"] = ["count": screenshots.count, "last": screenshots.sorted().last ?? ""] as [String: Any]
        // Разрешения: сначала по словам работающего экземпляра (у него своя запись в TCC), иначе — этого процесса.
        out["axTrusted"] = runtime?["axTrusted"] ?? AXIsProcessTrusted()
        out["screenRecording"] = runtime?["screenRecording"] ?? CGPreflightScreenCaptureAccess()
        guard let d = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return 1 }
        print(s)
        return 0
    }
}
