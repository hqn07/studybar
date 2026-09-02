import AppKit
import SwiftUI

/// The assistant as a SUMMONED floating panel (command-bar style), not a sidebar destination.
/// Cross-object AI jobs — "plan my week", "make flashcards from these notes" — live here and
/// are proposed as confirm-cards you accept. Summoned via ⌘K ("Ask Assistant"), the syllabus
/// importer, or the weekly-review button; it floats over whatever you're doing and closes when
/// you're done. Inline, on-object edits stay where the content is (the ✨ menus).
@MainActor
final class AssistantPanel {
    static let shared = AssistantPanel()
    private var panel: NSPanel?
    var isShown: Bool { panel != nil }

    func toggle() { isShown ? close() : show() }

    func show(prompt: String? = nil) {
        guard let state = AppState.current else { return }
        NSApp.activate(ignoringOtherApps: true)
        if panel == nil {
            let accent = Color(hex: UserDefaults.standard.string(forKey: "accentHex") ?? "") ?? .accentColor
            let view = AssistantPanelView(close: { AssistantPanel.shared.close() })
                .environmentObject(state)
                .tint(accent)
            let hosting = NSHostingView(rootView: view)
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                            backing: .buffered, defer: false)
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isMovableByWindowBackground = true
            p.standardWindowButton(.miniaturizeButton)?.isHidden = true
            p.standardWindowButton(.zoomButton)?.isHidden = true
            p.contentView = hosting
            positionTopTrailing(p)
            panel = p
        }
        panel?.makeKeyAndOrderFront(nil)
        if let prompt, !prompt.isEmpty, AIConfig.isReady {
            Task { await state.aiChat.send(prompt, state: state) }
        }
    }

    func close() { panel?.close(); panel = nil }

    private func positionTopTrailing(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let sf = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: sf.maxX - size.width - 40, y: sf.maxY - size.height - 60))
    }
}

/// The panel's contents: a compact header + the existing AssistantChat (proposes confirm-cards).
struct AssistantPanelView: View {
    @EnvironmentObject var state: AppState
    var close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.tint)
                Text("Assistant").font(.headline)
                Spacer()
                if !state.aiChat.isEmpty {
                    Button { state.aiChat.clear() } label: { Image(systemName: "square.and.pencil") }
                        .buttonStyle(.borderless).help("New chat — clears this conversation")
                }
                Text(AIConfig.mode.title).font(.caption2).foregroundStyle(.secondary)
                Button { close() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Close")
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            Divider()
            if AIConfig.isReady {
                AssistantChat(chat: state.aiChat)
            } else {
                notConfigured
            }
        }
        .frame(minWidth: 460, minHeight: 420)
        .background(.regularMaterial)
    }

    private var notConfigured: some View {
        VStack(spacing: 14) {
            EmptyState(symbol: "sparkles", title: "Turn on the assistant",
                       subtitle: "Pick an engine in Settings ▸ Intelligence — free on-device, or your own Claude / ChatGPT key. It organizes your studies; it won't do your homework.")
            Button("Open Intelligence settings") {
                WindowOpener.open?("main"); state.selectedModuleID = "settings"; close()
            }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }
}
