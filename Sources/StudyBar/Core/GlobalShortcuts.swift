import Carbon.HIToolbox
import AppKit

enum HotAction: String, CaseIterable, Identifiable {
    case palette, note, task, pomodoro
    var id: String { rawValue }
    var title: String {
        switch self {
        case .palette: return "Command palette"
        case .note: return "Quick note"
        case .task: return "Quick task"
        case .pomodoro: return "Start / pause Pomodoro"
        }
    }
    var hotID: UInt32 {
        switch self { case .palette: return 1; case .note: return 2; case .task: return 3; case .pomodoro: return 4 }
    }
    var defaultKeyCode: UInt32 {
        switch self { case .palette: return Keys.s; case .note: return Keys.n; case .task: return Keys.t; case .pomodoro: return Keys.p }
    }
}

struct HotBinding: Equatable { var keyCode: UInt32; var mods: UInt32 }

enum HotKeyStore {
    private static func key(_ a: HotAction) -> String { "hotkey.\(a.rawValue)" }

    static func binding(_ a: HotAction) -> HotBinding {
        if let s = UserDefaults.standard.string(forKey: key(a)) {
            let p = s.split(separator: ":")
            if p.count == 2, let kc = UInt32(p[0]), let m = UInt32(p[1]) { return HotBinding(keyCode: kc, mods: m) }
        }
        return HotBinding(keyCode: a.defaultKeyCode, mods: HotKeyManager.mods)
    }
    static func set(_ a: HotAction, _ b: HotBinding) {
        UserDefaults.standard.set("\(b.keyCode):\(b.mods)", forKey: key(a))
    }
    static func reset(_ a: HotAction) { UserDefaults.standard.removeObject(forKey: key(a)) }

    /// Human display like "⌃⌥N".
    static func display(_ b: HotBinding) -> String {
        var s = ""
        if b.mods & UInt32(controlKey) != 0 { s += "⌃" }
        if b.mods & UInt32(optionKey) != 0 { s += "⌥" }
        if b.mods & UInt32(shiftKey) != 0 { s += "⇧" }
        if b.mods & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyLabel(b.keyCode)
    }

    static func carbonMods(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        return m
    }
}

/// Maps a virtual key code to a readable label (letters, digits, common keys).
func keyLabel(_ code: UInt32) -> String {
    let map: [Int: String] = [
        kVK_ANSI_A:"A",kVK_ANSI_B:"B",kVK_ANSI_C:"C",kVK_ANSI_D:"D",kVK_ANSI_E:"E",kVK_ANSI_F:"F",
        kVK_ANSI_G:"G",kVK_ANSI_H:"H",kVK_ANSI_I:"I",kVK_ANSI_J:"J",kVK_ANSI_K:"K",kVK_ANSI_L:"L",
        kVK_ANSI_M:"M",kVK_ANSI_N:"N",kVK_ANSI_O:"O",kVK_ANSI_P:"P",kVK_ANSI_Q:"Q",kVK_ANSI_R:"R",
        kVK_ANSI_S:"S",kVK_ANSI_T:"T",kVK_ANSI_U:"U",kVK_ANSI_V:"V",kVK_ANSI_W:"W",kVK_ANSI_X:"X",
        kVK_ANSI_Y:"Y",kVK_ANSI_Z:"Z",
        kVK_ANSI_0:"0",kVK_ANSI_1:"1",kVK_ANSI_2:"2",kVK_ANSI_3:"3",kVK_ANSI_4:"4",kVK_ANSI_5:"5",
        kVK_ANSI_6:"6",kVK_ANSI_7:"7",kVK_ANSI_8:"8",kVK_ANSI_9:"9",
        kVK_Space:"Space", kVK_Return:"↩", kVK_ANSI_Period:".", kVK_ANSI_Comma:",", kVK_ANSI_Slash:"/",
    ]
    return map[Int(code)] ?? "key\(code)"
}

/// Builds and applies the global hotkey set from stored bindings.
@MainActor
enum GlobalShortcuts {
    static func action(_ a: HotAction) -> () -> Void {
        switch a {
        case .palette:
            return { PalettePanel.shared.toggle() }
        case .note: return { QuickCapture.shared.show(.note) }
        case .task: return { QuickCapture.shared.show(.task) }
        case .pomodoro: return { AppActions.togglePomodoro() }
        }
    }

    static func configure() {
        HotKeyManager.shared.configure(HotAction.allCases.map { a in
            let b = HotKeyStore.binding(a)
            return HotKeyManager.Def(id: a.hotID, keyCode: b.keyCode, mods: b.mods, action: action(a))
        })
    }
}
