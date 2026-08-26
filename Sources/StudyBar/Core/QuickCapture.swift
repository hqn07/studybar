import AppKit
import SwiftUI

/// A small floating panel for capturing a note or task from anywhere (global hotkey).
@MainActor
final class QuickCapture {
    static let shared = QuickCapture()
    enum Mode { case note, task }

    private var panel: NSPanel?

    func show(_ mode: Mode) {
        close()
        guard let state = AppState.current else { return }
        let view = QuickCaptureView(mode: mode, onClose: { [weak self] in self?.close() })
            .environmentObject(state)
            .tint(Color(hex: UserDefaults.standard.string(forKey: "accentHex") ?? "") ?? .accentColor)

        let hosting = NSHostingView(rootView: view)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 150),
                            styleMask: [.titled, .closable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        panel.center()
        self.panel = panel

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.close()
        panel = nil
        // Return focus to whatever the user was doing.
        NSApp.hide(nil)
    }
}

struct QuickCaptureView: View {
    @EnvironmentObject var state: AppState
    let mode: QuickCapture.Mode
    let onClose: () -> Void
    @State private var text = ""
    @State private var courseID: UUID? = nil
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: mode == .note ? "note.text" : "checkmark.circle").foregroundStyle(.tint)
                Text(mode == .note ? "Quick Note" : "Quick Task").font(.headline)
                Spacer()
                Text(mode == .note ? "⌃⌥N" : "⌃⌥T").font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            TextField(mode == .note ? "Jot something down…" : "e.g. essay due friday for chem", text: $text)
                .textFieldStyle(.plain).font(.title3).focused($focused)
                .onSubmit { save() }
            Divider()
            HStack {
                CoursePicker(courseID: $courseID)
                Spacer()
                Button("Cancel") { onClose() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 480)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true } }
    }

    private func save() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { onClose(); return }
        if mode == .note {
            state.data.notes.append(Note(title: String(t.prefix(60)), body: t, courseID: courseID))
        } else {
            // Natural-language parse: "essay fri for chem" → assignment; else a todo.
            let p = QuickParse.parse(t, courses: state.data.courses)
            let course = courseID ?? p.courseID   // an explicit picker choice wins
            if p.isAssignment {
                state.data.assignments.append(Assignment(title: p.title, courseID: course, due: p.due))
            } else {
                state.data.todos.append(TodoItem(text: p.title, priority: p.priority, courseID: course, due: p.due))
            }
        }
        onClose()
    }
}
