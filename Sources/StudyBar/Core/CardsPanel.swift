import AppKit
import SwiftUI

/// Flashcard review in a small panel that floats over other apps — a few cards between other
/// work, without switching to StudyBar. The calculator's panel, holding Flashcards' own review.
@MainActor
final class CardsPanel {
    static let shared = CardsPanel()
    private var panel: NSPanel?

    /// One deck's due cards, or every deck's (`deckID` nil). A new call starts a new session.
    func show(deckID: UUID?) {
        guard let state = AppState.current else { return }
        NSApp.activate(ignoringOtherApps: true)
        let accent = Color(hex: UserDefaults.standard.string(forKey: "accentHex") ?? "") ?? .accentColor
        let view = NavigationStack { StudyView(deckID: deckID, onClose: { CardsPanel.shared.close() }) }
            .environmentObject(state).tint(accent)
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 440),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                            backing: .buffered, defer: false)
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isMovableByWindowBackground = true
            for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { p.standardWindowButton(b)?.isHidden = true }
            p.setFrameAutosaveName("StudyBarCards")
            if !p.setFrameUsingName("StudyBarCards") { p.center() }
            panel = p
        }
        panel?.contentView = NSHostingView(rootView: view)
        panel?.makeKeyAndOrderFront(nil)
    }

    func close() { panel?.close(); panel = nil }
}
