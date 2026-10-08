import SwiftUI
import AppKit

/// The empty part of the toolbar row, where a drag moves the window and a double-click zooms
/// it — what the titlebar did before the row moved into it. Sits behind the row's controls.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
        }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
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
