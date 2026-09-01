import SwiftUI
import AppKit

/// Shared LaTeX source editing — a cursor-aware monospaced NSTextView controller and its
/// NSViewRepresentable. Used by the Notes math composer (Shell/MathComposer.swift).
/// Extracted from the retired Equation module.

final class MathSourceController: ObservableObject {
    weak var tv: NSTextView?
    /// Insert a snippet at the caret; `back` moves the caret left afterward (to land inside braces).
    func insert(_ s: String, back: Int = 0) {
        guard let tv else { return }
        let range = tv.selectedRange()
        if tv.shouldChangeText(in: range, replacementString: s) {
            tv.insertText(s, replacementRange: range)
            if back > 0 {
                let loc = max(0, tv.selectedRange().location - back)
                tv.setSelectedRange(NSRange(location: loc, length: 0))
            }
            tv.didChangeText()
        }
        tv.window?.makeFirstResponder(tv)
    }
}

struct MathSourceEditor: NSViewRepresentable {
    @Binding var text: String
    let controller: MathSourceController

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.isRichText = false
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.string = text
        tv.delegate = context.coordinator
        controller.tv = tv
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // Keep external programmatic changes (e.g. wrapDisplay) in sync without clobbering the caret.
        if let tv = nsView.documentView as? NSTextView, tv.string != text {
            let sel = tv.selectedRange()
            tv.string = text
            tv.setSelectedRange(NSRange(location: min(sel.location, text.utf16.count), length: 0))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: MathSourceEditor
        init(_ p: MathSourceEditor) { parent = p }
        func textDidChange(_ notification: Notification) {
            if let tv = notification.object as? NSTextView { parent.text = tv.string }
        }
    }
}
