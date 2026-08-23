import AppKit
import SwiftUI

/// A Spotlight-style floating command palette, summonable from any app via the global hotkey.
@MainActor
final class PalettePanel {
    static let shared = PalettePanel()
    private var panel: NSPanel?
    var isShown: Bool { panel != nil }

    func toggle() { isShown ? close() : show() }

    func show() {
        close()
        guard let state = AppState.current else { return }
        let accent = Color(hex: UserDefaults.standard.string(forKey: "accentHex") ?? "") ?? .accentColor
        let view = CommandPalette(isPresented: Binding(get: { true }, set: { if !$0 { PalettePanel.shared.close() } }),
                                  standalone: true)
            .environmentObject(state)
            .tint(accent)
        let hosting = NSHostingView(rootView: view)

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 420),
                            styleMask: [.titled, .closable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        positionTopCenter(panel)
        self.panel = panel

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.close()
        panel = nil
    }

    private func positionTopCenter(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { panel.center(); return }
        let f = panel.frame
        let sf = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: sf.midX - f.width / 2, y: sf.maxY - f.height - sf.height * 0.16))
    }
}
