import SwiftUI
import AppKit

/// The empty part of the toolbar row, where a drag moves the window and a double-click does
/// what the titlebar does — what the titlebar did before the row moved into it. Sits behind
/// the row's controls.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        /// A window in the background moves on the first drag, as it does by its titlebar.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 { WindowDragArea.doubleClick(window) } else { window.performDrag(with: event) }
        }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    /// System Settings ▸ Desktop & Dock ▸ "Double-click a window's title bar to": the row's
    /// upper part is the real titlebar and obeys it, so the lower part must too.
    static func doubleClick(_ w: NSWindow) {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": w.performMiniaturize(nil)
        case "None": break
        case "Fill": fill(w)
        default: w.performZoom(nil)   // "Maximize", or never set: Zoom
        }
    }

    /// The frame each window had before Fill, so a second double-click puts it back.
    private static var beforeFill: [ObjectIdentifier: NSRect] = [:]

    /// Fill has no public call: AppKit's own `_zoomFill:` (the Window ▸ Fill command) when it's
    /// there, Zoom when it isn't. Fill animates, so "already filled" is read off the screen.
    private static func fill(_ w: NSWindow) {
        let key = ObjectIdentifier(w)
        if let visible = w.screen?.visibleFrame, w.frame.insetBy(dx: -12, dy: -12).contains(visible),
           let before = beforeFill.removeValue(forKey: key) {
            w.setFrame(before, display: true, animate: true)
            return
        }
        let fill = Selector(("_zoomFill:"))
        guard w.responds(to: fill) else { w.performZoom(nil); return }
        beforeFill[key] = w.frame
        w.perform(fill, with: nil)
    }
}

private struct PrimaryPaneKey: EnvironmentKey { static let defaultValue = false }
private struct TitlebarLeadingKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
private struct TitlebarTrailingKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }

extension EnvironmentValues {
    /// The window's left pane: its module header is the toolbar row, up in the titlebar.
    /// False for the right pane of a split and in the popover, whose headers stay inline.
    var isPrimaryPane: Bool {
        get { self[PrimaryPaneKey.self] }
        set { self[PrimaryPaneKey.self] = newValue }
    }
    /// Room the toolbar row leaves at its leading edge for the traffic lights and sidebar toggle.
    var titlebarLeading: CGFloat {
        get { self[TitlebarLeadingKey.self] }
        set { self[TitlebarLeadingKey.self] = newValue }
    }
    /// Room the toolbar row leaves at its trailing edge for the search field.
    var titlebarTrailing: CGFloat {
        get { self[TitlebarTrailingKey.self] }
        set { self[TitlebarTrailingKey.self] = newValue }
    }
}
