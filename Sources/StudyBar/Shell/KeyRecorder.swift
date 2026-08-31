import SwiftUI
import AppKit

/// Records a keyboard shortcut. SwiftUI-drawn (no manual text drawing); an invisible
/// NSView captures the keystroke only while recording.
struct KeyRecorder: View {
    let display: String
    let onCapture: (HotBinding) -> Void
    @State private var recording = false

    var body: some View {
        Button { recording.toggle() } label: {
            Text(recording ? "Type…" : (display.isEmpty ? "Record" : display))
                .font(.system(.caption, design: .monospaced))
                .frame(minWidth: 72)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .foregroundStyle(recording ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .background(RoundedRectangle(cornerRadius: 5).fill(.sbSurface))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(recording ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator),
                                                                  lineWidth: recording ? 2 : 1))
        }
        .buttonStyle(.plain)
        .background {
            if recording {
                KeyCatcher { binding in onCapture(binding); recording = false }
                    .frame(width: 0, height: 0)
            }
        }
    }
}

private struct KeyCatcher: NSViewRepresentable {
    let onCapture: (HotBinding) -> Void
    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView(); v.onCapture = onCapture
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }
    func updateNSView(_ v: CatcherView, context: Context) {
        v.onCapture = onCapture
        DispatchQueue.main.async { if v.window?.firstResponder !== v { v.window?.makeFirstResponder(v) } }
    }
}

private final class CatcherView: NSView {
    var onCapture: ((HotBinding) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCapture = nil; window?.makeFirstResponder(nil); return } // Esc cancels
        let mods = HotKeyStore.carbonMods(from: event.modifierFlags)
        guard mods != 0 else { NSSound.beep(); return }
        onCapture?(HotBinding(keyCode: UInt32(event.keyCode), mods: mods))
        window?.makeFirstResponder(nil)
    }
}
