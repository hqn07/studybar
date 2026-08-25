import SwiftUI
import AppKit

// MARK: - RTFD (de)serialization helpers

extension NSAttributedString {
    /// Full-length RTFD data (embeds images), or nil if empty.
    func rtfdData() -> Data? {
        guard length > 0 else { return nil }
        return rtfd(from: NSRange(location: 0, length: length),
                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
    }
    static func fromRTFD(_ data: Data) -> NSAttributedString? {
        try? NSAttributedString(data: data,
                                options: [.documentType: NSAttributedString.DocumentType.rtfd],
                                documentAttributes: nil)
    }
}

// MARK: - Controller (toolbar → NSTextView bridge)

/// Bridges the SwiftUI formatting toolbar to the underlying NSTextView. The text
/// view owns the content; `persist` reads `attributedString` back on save. This
/// one-way flow avoids SwiftUI ↔︎ AppKit binding loops that reset the caret.
@MainActor
final class RichTextController: ObservableObject {
    weak var textView: NSTextView?
    var onEdit: () -> Void = {}
    /// Latest content, kept fresh on every edit so persistence survives the text
    /// view being torn down (preview toggle, module switch) — avoids data loss.
    var snapshot: NSAttributedString?

    static let baseFont = NSFont.systemFont(ofSize: 13)

    var attributedString: NSAttributedString {
        textView?.attributedString() ?? snapshot ?? NSAttributedString()
    }
    var plainText: String { textView?.string ?? snapshot?.string ?? "" }

    /// Selected text, or the word under the caret — for "Define".
    var wordToDefine: String {
        let sel = selectedString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sel.isEmpty { return sel }
        guard let tv = textView else { return "" }
        let ns = tv.string as NSString
        guard ns.length > 0 else { return "" }
        let letters = CharacterSet.alphanumerics
        var start = min(tv.selectedRange().location, ns.length)
        var end = start
        func isLetter(_ i: Int) -> Bool {
            guard let u = ns.substring(with: NSRange(location: i, length: 1)).unicodeScalars.first else { return false }
            return letters.contains(u)
        }
        while start > 0, isLetter(start - 1) { start -= 1 }
        while end < ns.length, isLetter(end) { end += 1 }
        return ns.substring(with: NSRange(location: start, length: end - start))
    }
    var selectedString: String {
        guard let tv = textView else { return "" }
        return (tv.string as NSString).substring(with: tv.selectedRange())
    }
    var hasSelection: Bool { (textView?.selectedRange().length ?? 0) > 0 }

    // MARK: Traits (bold / italic)

    func toggleTrait(_ trait: NSFontTraitMask) {
        guard let tv = textView else { return }
        let fm = NSFontManager.shared
        let range = tv.selectedRange()
        if range.length == 0 {
            var attrs = tv.typingAttributes
            let f = (attrs[.font] as? NSFont) ?? Self.baseFont
            let has = fm.traits(of: f).contains(trait)
            attrs[.font] = has ? fm.convert(f, toNotHaveTrait: trait) : fm.convert(f, toHaveTrait: trait)
            tv.typingAttributes = attrs
            return
        }
        guard let ts = tv.textStorage else { return }
        let first = (ts.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont) ?? Self.baseFont
        let makeOn = !fm.traits(of: first).contains(trait)
        ts.beginEditing()
        ts.enumerateAttribute(.font, in: range) { val, r, _ in
            let f = (val as? NSFont) ?? Self.baseFont
            ts.addAttribute(.font, value: makeOn ? fm.convert(f, toHaveTrait: trait) : fm.convert(f, toNotHaveTrait: trait), range: r)
        }
        ts.endEditing()
        tv.didChangeText()
    }

    // MARK: Attribute toggles (underline / strikethrough)

    func toggleAttribute(_ key: NSAttributedString.Key) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        let style = NSUnderlineStyle.single.rawValue
        if range.length == 0 {
            var attrs = tv.typingAttributes
            let on = (attrs[key] as? Int ?? 0) != 0
            attrs[key] = on ? 0 : style
            tv.typingAttributes = attrs
            return
        }
        guard let ts = tv.textStorage else { return }
        let cur = (ts.attribute(key, at: range.location, effectiveRange: nil) as? Int ?? 0) != 0
        ts.beginEditing()
        ts.addAttribute(key, value: cur ? 0 : style, range: range)
        ts.endEditing()
        tv.didChangeText()
    }

    // MARK: Heading / body size

    enum Heading { case body, h1, h2, h3
        var font: NSFont {
            switch self {
            case .body: return .systemFont(ofSize: 13)
            case .h1:   return .systemFont(ofSize: 22, weight: .bold)
            case .h2:   return .systemFont(ofSize: 18, weight: .bold)
            case .h3:   return .systemFont(ofSize: 15, weight: .semibold)
            }
        }
    }
    func setHeading(_ h: Heading) {
        guard let tv = textView else { return }
        let range = paragraphRange()
        if range.length == 0 { var a = tv.typingAttributes; a[.font] = h.font; tv.typingAttributes = a; return }
        tv.textStorage?.addAttribute(.font, value: h.font, range: range)
        tv.didChangeText()
    }

    // MARK: Colors (fixed palette — no NSColorPanel, which would dismiss the popover)

    func setForeground(_ color: NSColor?) { applyColor(.foregroundColor, color) }
    func setHighlight(_ color: NSColor?) { applyColor(.backgroundColor, color) }

    private func applyColor(_ key: NSAttributedString.Key, _ color: NSColor?) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        if range.length == 0 {
            var a = tv.typingAttributes
            if let color { a[key] = color } else { a.removeValue(forKey: key) }
            tv.typingAttributes = a
            return
        }
        guard let ts = tv.textStorage else { return }
        ts.beginEditing()
        if let color { ts.addAttribute(key, value: color, range: range) }
        else { ts.removeAttribute(key, range: range) }
        ts.endEditing()
        tv.didChangeText()
    }

    // MARK: Lists

    func toggleBullet() {
        guard let tv = textView, let ts = tv.textStorage else { return }
        let para = paragraphRange()
        let str = (ts.string as NSString).substring(with: para)
        let bulleted = str.hasPrefix("• ")
        let replacement = bulleted ? String(str.dropFirst(2)) : "• " + str
        if tv.shouldChangeText(in: para, replacementString: replacement) {
            ts.replaceCharacters(in: para, with: replacement)
            tv.didChangeText()
        }
    }

    // MARK: Collapsible section

    /// Wrap the current selection in a titled fold marker. Stored as plain text so
    /// it round-trips through RTFD/search untouched; the note Preview renders it as
    /// an expandable section.
    func wrapFold(title: String) {
        guard let tv = textView, let ts = tv.textStorage else { return }
        let range = tv.selectedRange()
        guard range.length > 0 else { return }
        let inner = (ts.string as NSString).substring(with: range)
        let t = title.trimmingCharacters(in: .whitespaces).isEmpty ? "Section" : title
        let wrapped = "[[fold: \(t)]]\n\(inner)\n[[/fold]]\n"
        if tv.shouldChangeText(in: range, replacementString: wrapped) {
            ts.replaceCharacters(in: range, with: NSAttributedString(
                string: wrapped, attributes: [.font: Self.baseFont, .foregroundColor: NSColor.labelColor]))
            tv.didChangeText()
        }
    }

    // MARK: Images

    func insertImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Insert"
        guard panel.runModal() == .OK, let url = panel.url,
              let image = NSImage(contentsOf: url), let tv = textView else { return }
        // Scale to fit the popover width.
        let maxW: CGFloat = 260
        let size = image.size
        let scale = size.width > maxW ? maxW / size.width : 1
        let att = NSTextAttachment()
        att.image = image
        att.bounds = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
        let attr = NSMutableAttributedString(attachment: att)
        attr.append(NSAttributedString(string: "\n"))
        let range = tv.selectedRange()
        if tv.shouldChangeText(in: range, replacementString: nil) {
            tv.textStorage?.replaceCharacters(in: range, with: attr)
            tv.didChangeText()
        }
    }

    // MARK: Helpers

    /// The range of the paragraph(s) intersecting the selection.
    private func paragraphRange() -> NSRange {
        guard let tv = textView else { return NSRange(location: 0, length: 0) }
        return (tv.string as NSString).paragraphRange(for: tv.selectedRange())
    }
}

// MARK: - NSTextView host

struct RichTextEditor: NSViewRepresentable {
    let initial: NSAttributedString
    let controller: RichTextController

    func makeCoordinator() -> Coordinator { Coordinator(controller) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.isRichText = true
        tv.importsGraphics = true
        tv.allowsImageEditing = true
        tv.isEditable = true
        tv.isSelectable = true
        tv.allowsUndo = true
        tv.usesFontPanel = false
        tv.font = RichTextController.baseFont
        tv.textContainerInset = NSSize(width: 4, height: 8)
        tv.drawsBackground = false
        tv.delegate = context.coordinator
        if initial.length > 0 { tv.textStorage?.setAttributedString(initial) }
        tv.typingAttributes = [.font: RichTextController.baseFont,
                               .foregroundColor: NSColor.labelColor]
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        controller.textView = tv
        controller.snapshot = initial
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}

    final class Coordinator: NSObject, NSTextViewDelegate {
        let controller: RichTextController
        init(_ c: RichTextController) { controller = c }
        func textDidChange(_ notification: Notification) {
            if let tv = notification.object as? NSTextView { controller.snapshot = tv.attributedString() }
            controller.onEdit()
        }
    }
}
