import SwiftUI

@main
struct StudyBarApp: App {
    // The status item, popover, window and URL handling are all owned by AppDelegate.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Accessory (menu bar) app — no primary window scene. A hidden Settings
        // scene satisfies the App protocol; everything visible is AppKit-managed.
        Settings { EmptyView() }
    }
}

enum MenuBarContent: String, CaseIterable, Identifiable {
    case smart = "Smart (recommended)"
    case icon = "Icon only"
    case badge = "Icon + due badge"
    case timer = "Pomodoro countdown"
    case nextClass = "Next class"
    var id: String { rawValue }
}

/// Lets the popover's SwiftUI content resize the `NSPopover` that hosts it.
///
/// A popover is not user-resizable the way a window is, so the three presets below were the
/// only sizes on offer and a new one needed the popover reopened to take effect. The grip in
/// the bottom-right corner drives this instead: it resizes live and remembers the result, and
/// the presets stay as one-click starting points.
@MainActor
enum PopoverSizing {
    /// Set by AppDelegate: applies a size to the live popover and stores it.
    static var apply: ((CGSize) -> Void)?
    /// The popover's current content size, or nil when it isn't on screen.
    static var current: (() -> CGSize)?

    static let key = "popoverCustomSize"
    static let range = (width: CGFloat(360)...CGFloat(720), height: CGFloat(420)...CGFloat(940))

    /// The size a hand-resized popover was left at, if any.
    static var custom: CGSize? {
        guard let raw = UserDefaults.standard.string(forKey: key) else { return nil }
        let size = NSSizeFromString(raw)
        return size.width > 0 && size.height > 0 ? size : nil
    }
    static func clamp(_ size: CGSize) -> CGSize {
        CGSize(width: min(max(size.width, range.width.lowerBound), range.width.upperBound),
               height: min(max(size.height, range.height.lowerBound), range.height.upperBound))
    }
    /// Forget the hand-set size — the presets in Settings take over again.
    static func clearCustom() { UserDefaults.standard.removeObject(forKey: key) }
}

enum PopoverSize: String, CaseIterable, Identifiable {
    case small = "Compact"
    case medium = "Standard"
    case large = "Large"
    var id: String { rawValue }
    var dimensions: CGSize {
        switch self {
        case .small:  return CGSize(width: 420, height: 560)
        case .medium: return CGSize(width: 460, height: 640)
        case .large:  return CGSize(width: 520, height: 720)
        }
    }
}
