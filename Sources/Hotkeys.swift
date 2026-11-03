// Kadr — глобальные горячие клавиши через Carbon RegisterEventHotKey.
import AppKit
import Carbon.HIToolbox

final class HotkeyCenter {
    static let shared = HotkeyCenter()

    var onAction: ((HotkeyAction) -> Void)?
    private(set) var failed: Set<HotkeyAction> = []
    private var refs: [EventHotKeyRef] = []
    private var handlerInstalled = false
    private let signature: OSType = 0x4B41_4452 // 'KADR'

    func reload() {
        unregisterAll()
        installHandler()
        failed = []
        for (i, a) in HotkeyAction.allCases.enumerated() {
            guard let spec = Prefs.hotkey(a) else { continue }
            var ref: EventHotKeyRef?
            let hid = EventHotKeyID(signature: signature, id: UInt32(i + 1))
            let st = RegisterEventHotKey(spec.keyCode, spec.carbonModifiers, hid, GetApplicationEventTarget(), 0, &ref)
            if st == noErr, let ref { refs.append(ref) } else { failed.insert(a) }
        }
    }

    /// Снимает все сочетания (на время записи нового сочетания в настройках).
    func unregisterAll() {
        for r in refs { UnregisterEventHotKey(r) }
        refs = []
    }

    fileprivate func fire(_ id: UInt32) {
        let idx = Int(id) - 1
        guard HotkeyAction.allCases.indices.contains(idx) else { return }
        onAction?(HotkeyAction.allCases[idx])
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            let st = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            if st == noErr {
                let id = hk.id
                DispatchQueue.main.async { HotkeyCenter.shared.fire(id) }
            }
            return noErr
        }, 1, &spec, nil, nil)
        handlerInstalled = (status == noErr)
    }
}
