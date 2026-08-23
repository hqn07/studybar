import Carbon.HIToolbox
import AppKit

/// System-wide hotkeys (work whether or not StudyBar is focused).
final class HotKeyManager {
    static let shared = HotKeyManager()

    struct Def {
        let id: UInt32
        let keyCode: UInt32
        let mods: UInt32
        let action: () -> Void
    }

    private var defs: [Def] = []
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?
    private(set) var registered = false

    /// Standard modifier for StudyBar globals: ⌃⌥ (control+option).
    static let mods = UInt32(controlKey | optionKey)

    func configure(_ list: [Def]) {
        defs = list
        actions = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0.action) })
        if registered { register() }   // re-apply if already on
    }

    func setEnabled(_ on: Bool) { on ? register() : unregister() }

    func register() {
        unregister()
        installHandlerIfNeeded()
        for d in defs {
            var ref: EventHotKeyRef?
            let hkID = EventHotKeyID(signature: OSType(0x53544259), id: d.id)   // 'STBY'
            if RegisterEventHotKey(d.keyCode, d.mods, hkID, GetApplicationEventTarget(), 0, &ref) == noErr {
                refs[d.id] = ref
            }
        }
        registered = true
    }

    func unregister() {
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        registered = false
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let mgr = Unmanaged<HotKeyManager>.fromOpaque(userData!).takeUnretainedValue()
            let id = hkID.id
            DispatchQueue.main.async { mgr.actions[id]?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
}

/// Carbon virtual key codes used for StudyBar's global hotkeys.
enum Keys {
    static let s = UInt32(kVK_ANSI_S)
    static let n = UInt32(kVK_ANSI_N)
    static let t = UInt32(kVK_ANSI_T)
    static let p = UInt32(kVK_ANSI_P)
    static let f = UInt32(kVK_ANSI_F)
}
