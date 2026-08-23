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
    case icon = "Icon only"
    case badge = "Icon + due badge"
    case timer = "Pomodoro countdown"
    case nextClass = "Next class"
    var id: String { rawValue }
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
