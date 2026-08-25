import SwiftUI
import AppKit
import SwiftMath

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
/// (Not @MainActor: all use is on the main thread, but the AppKit delegate
/// callbacks that touch it are nonisolated.)
final class RichTextController: ObservableObject {
    weak var textView: NSTextView?
    var onEdit: () -> Void = {}
    /// Latest content, kept fresh on every edit so persistence survives the text
    /// view being torn down (preview toggle, module switch) — avoids data loss.
    var snapshot: NSAttributedString?
    /// True while the caret is inside a math expression the user clicked to edit,
    /// so we know to re-render it when they move away.
    var mathEditing = false

    static let baseFont = NSFont.systemFont(ofSize: 13)

    /// The contiguous run tagged as a given fold's revealed body, or nil.
    static func memberRange(_ uuid: String, from: Int, in s: NSAttributedString) -> NSRange? {
        guard from < s.length,
              (s.attribute(.foldMember, at: from, effectiveRange: nil) as? String) == uuid else { return nil }
        var end = from
        while end < s.length, (s.attribute(.foldMember, at: end, effectiveRange: nil) as? String) == uuid { end += 1 }
        return NSRange(location: from, length: end - from)
    }
    static func stripped(_ a: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: a)
        m.removeAttribute(.foldMember, range: NSRange(location: 0, length: m.length))
        return m
    }

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

    /// Collapse the current selection into a titled, clickable fold chip. The
    /// selected rich content is moved into the chip and hidden; clicking the chip
    /// toggles it. Persisted as `[[fold: …]]` markers (see expandingFolds), so the
    /// Preview, search and inner formatting all round-trip.
    func wrapFold(title: String) {
        guard let tv = textView, let ts = tv.textStorage else { return }
        let range = tv.selectedRange()
        guard range.length > 0 else { return }
        let t = title.trimmingCharacters(in: .whitespaces).isEmpty ? "Section" : title
        let inner = ts.attributedSubstring(from: range)
        let chip = NSAttributedString(attachment: FoldAttachment(title: t, body: inner, collapsed: true))
        let replacement = NSMutableAttributedString(attributedString: chip)
        replacement.append(NSAttributedString(string: "\n", attributes: [.font: Self.baseFont]))
        if tv.shouldChangeText(in: range, replacementString: nil) {
            ts.replaceCharacters(in: range, with: replacement)
            tv.didChangeText()
            snapshot = tv.attributedString()
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
        // Build an explicit TextKit 1 stack: NSTextAttachmentCell drawing (the fold
        // chips) is TextKit 1 only, and the FoldingTextView subclass intercepts
        // clicks to toggle folds (clickedOnCell is unreliable in editable views).
        let scroll = NSScrollView()
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let big = CGFloat.greatestFiniteMagnitude
        let container = NSTextContainer(size: NSSize(width: 0, height: big))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let tv = FoldingTextView(frame: .zero, textContainer: container)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: big, height: big)
        scroll.documentView = tv
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
        tv.mathController = controller
        let installed = initial.installingFolds().installingMath()
        if installed.length > 0 { tv.textStorage?.setAttributedString(installed) }
        tv.typingAttributes = [.font: RichTextController.baseFont,
                               .foregroundColor: NSColor.labelColor]
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        controller.textView = tv
        controller.snapshot = installed
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

        /// When the caret leaves a math expression it was editing, re-render it in place.
        func textViewDidChangeSelection(_ notification: Notification) {
            guard controller.mathEditing, let tv = notification.object as? NSTextView,
                  let ts = tv.textStorage else { return }
            if MathSupport.caretInsideMath(tv.string, tv.selectedRange().location) { return }
            let caret = tv.selectedRange().location
            let rebuilt = tv.attributedString().installingMath()
            if rebuilt.length != ts.length {           // something rendered → apply
                ts.setAttributedString(rebuilt)
                tv.setSelectedRange(NSRange(location: min(caret, rebuilt.length), length: 0))
                tv.didChangeText()
            }
            controller.mathEditing = false
        }
    }
}

/// NSTextView that toggles a fold chip when clicked. `clickedOnCell` is unreliable
/// in an editable text view (a click just places the caret), so we intercept
/// `mouseDown`, hit-test the character, and toggle if it's a fold.
final class FoldingTextView: NSTextView {
    weak var mathController: RichTextController?

    override func mouseDown(with event: NSEvent) {
        guard let ts = textStorage, let lm = layoutManager, let tc = textContainer else {
            super.mouseDown(with: event); return
        }
        let pt = convert(event.locationInWindow, from: nil)
        let origin = textContainerOrigin
        let glyph = lm.glyphIndex(for: NSPoint(x: pt.x - origin.x, y: pt.y - origin.y), in: tc)
        let idx = lm.characterIndexForGlyph(at: glyph)
        for cand in [idx, idx - 1] where cand >= 0 && cand < ts.length {
            if let math = ts.attribute(.attachment, at: cand, effectiveRange: nil) as? MathAttachment {
                revealMath(math, at: cand); return   // click rendered math → edit its source
            }
            if let fold = ts.attribute(.attachment, at: cand, effectiveRange: nil) as? FoldAttachment {
                toggle(fold, at: cand)
                return   // consume — don't move the caret
            }
        }
        super.mouseDown(with: event)
    }

    private func toggle(_ fold: FoldAttachment, at charIndex: Int) {
        guard let ts = textStorage else { return }
        ts.beginEditing()
        if fold.collapsed {
            let member = NSMutableAttributedString(string: "\n")
            member.append(fold.body)
            member.addAttribute(.foldMember, value: fold.uuid, range: NSRange(location: 0, length: member.length))
            ts.insert(member, at: charIndex + 1)
            fold.collapsed = false
        } else if let mr = RichTextController.memberRange(fold.uuid, from: charIndex + 1, in: ts) {
            var cap = ts.attributedSubstring(from: mr)
            if cap.string.hasPrefix("\n") { cap = cap.attributedSubstring(from: NSRange(location: 1, length: cap.length - 1)) }
            fold.body = RichTextController.stripped(cap).expandingMath()   // store math as source
            ts.deleteCharacters(in: mr)
            fold.collapsed = true
        }
        ts.endEditing()
        let r = NSRange(location: max(0, charIndex - 1), length: 2)
        layoutManager?.invalidateLayout(forCharacterRange: r, actualCharacterRange: nil)
        layoutManager?.invalidateDisplay(forCharacterRange: r)
        didChangeText()
    }

    /// Replace a rendered math attachment with its `$…$` source so it can be edited;
    /// it re-renders when the caret leaves (see textViewDidChangeSelection).
    private func revealMath(_ math: MathAttachment, at charIndex: Int) {
        guard let ts = textStorage else { return }
        let src = math.display ? "$$\(math.latex)$$" : "$\(math.latex)$"
        let attr = NSAttributedString(string: src, attributes: [
            .font: RichTextController.baseFont, .foregroundColor: NSColor.labelColor])
        let range = NSRange(location: charIndex, length: 1)
        if shouldChangeText(in: range, replacementString: src) {
            ts.replaceCharacters(in: range, with: attr)
            didChangeText()
            // caret just before the closing delimiter, ready to edit
            setSelectedRange(NSRange(location: charIndex + src.count - (math.display ? 2 : 1), length: 0))
            mathController?.mathEditing = true
            window?.makeFirstResponder(self)
        }
    }
}

// MARK: - Collapsible fold chip (clickable NSTextAttachment)

extension NSAttributedString.Key {
    static let foldMember = NSAttributedString.Key("sbFoldMember")
}

/// A collapsed section: a clickable chip carrying its (hidden) rich body.
final class FoldAttachment: NSTextAttachment {
    let uuid = UUID().uuidString
    var title: String
    var body: NSAttributedString
    var collapsed: Bool
    init(title: String, body: NSAttributedString, collapsed: Bool) {
        self.title = title; self.body = body; self.collapsed = collapsed
        super.init(data: nil, ofType: nil)
        self.attachmentCell = FoldCell()
    }
    required init?(coder: NSCoder) {
        title = "Section"; body = NSAttributedString(); collapsed = true
        super.init(coder: coder)
        self.attachmentCell = FoldCell()
    }
}

final class FoldCell: NSTextAttachmentCell {
    private var fold: FoldAttachment? { attachment as? FoldAttachment }
    private var label: String { ((fold?.collapsed ?? true) ? "▸ " : "▾ ") + (fold?.title ?? "Section") }
    private let chipFont = NSFont.systemFont(ofSize: 12, weight: .semibold)

    override func cellSize() -> NSSize {
        NSSize(width: (label as NSString).size(withAttributes: [.font: chipFont]).width + 22, height: 20)
    }
    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -4) }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let rect = cellFrame.insetBy(dx: 1, dy: 1)
        NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        (label as NSString).draw(at: NSPoint(x: rect.minX + 8, y: rect.minY + 2),
            withAttributes: [.font: chipFont, .foregroundColor: NSColor.controlAccentColor])
    }
    override func wantsToTrackMouse() -> Bool { true }
}

// MARK: - Fold ⇄ marker conversion (persistence)

extension NSAttributedString {
    private static let foldRegex = try! NSRegularExpression(
        pattern: #"\[\[fold:\s*(.*?)\]\][ \t]*\n([\s\S]*?)\n[ \t]*\[\[/fold\]\][ \t]*\n?"#)

    /// Marker text → collapsed fold chips (for display in the editor).
    func installingFolds() -> NSAttributedString {
        let ns = string as NSString
        let matches = NSAttributedString.foldRegex.matches(in: string, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return self }
        let out = NSMutableAttributedString()
        var cursor = 0
        for m in matches {
            if m.range.location > cursor {
                out.append(attributedSubstring(from: NSRange(location: cursor, length: m.range.location - cursor)))
            }
            let title = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let body = attributedSubstring(from: m.range(at: 2))
            out.append(NSAttributedString(attachment: FoldAttachment(
                title: title.isEmpty ? "Section" : title, body: body, collapsed: true)))
            out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 13)]))
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            out.append(attributedSubstring(from: NSRange(location: cursor, length: ns.length - cursor)))
        }
        return out
    }

    /// Fold chips → `[[fold: …]]` marker text (for saving / search / preview).
    func expandingFolds() -> NSAttributedString {
        let out = NSMutableAttributedString()
        let full = string as NSString
        var i = 0
        while i < length {
            var r = NSRange()
            let att = attribute(.attachment, at: i, effectiveRange: &r)
            if let fold = att as? FoldAttachment {
                var body = fold.body
                var advance = r.location + r.length
                if let mr = RichTextController.memberRange(fold.uuid, from: advance, in: self) {
                    var cap = attributedSubstring(from: mr)
                    if cap.string.hasPrefix("\n") { cap = cap.attributedSubstring(from: NSRange(location: 1, length: cap.length - 1)) }
                    body = RichTextController.stripped(cap)
                    advance = mr.location + mr.length
                }
                out.append(NSAttributedString(string: "[[fold: \(fold.title)]]\n"))
                out.append(body)
                out.append(NSAttributedString(string: body.string.hasSuffix("\n") ? "[[/fold]]\n" : "\n[[/fold]]\n"))
                if advance < length, full.substring(with: NSRange(location: advance, length: 1)) == "\n" { advance += 1 }
                i = advance
            } else if att != nil {
                out.append(attributedSubstring(from: NSRange(location: i, length: r.length)))   // image, etc.
                i += r.length
            } else {
                let next = NSAttributedString.nextAttachment(in: self, from: i) ?? length
                out.append(attributedSubstring(from: NSRange(location: i, length: next - i)))
                i = next
            }
        }
        return out
    }

    private static func nextAttachment(in s: NSAttributedString, from: Int) -> Int? {
        var idx = from
        while idx < s.length {
            if s.attribute(.attachment, at: idx, effectiveRange: nil) != nil { return idx }
            idx += 1
        }
        return nil
    }
}

// MARK: - In-place inline math (SwiftMath — native typesetter)

/// A rendered LaTeX expression sitting inline in the editor. Clicking it reveals
/// its `$…$` source for editing (see FoldingTextView.revealMath); it re-renders
/// when the caret leaves. Persisted as `$…$` source via expandingMath.
final class MathAttachment: NSTextAttachment {
    let latex: String
    let display: Bool
    init(latex: String, display: Bool) {
        self.latex = latex; self.display = display
        super.init(data: nil, ofType: nil)
        render()
    }
    required init?(coder: NSCoder) { latex = ""; display = false; super.init(coder: coder) }

    private func render() {
        var mi = MathImage(latex: latex, fontSize: display ? 19 : 15,
                           textColor: NSColor.labelColor, labelMode: display ? .display : .text)
        let (_, img, layout) = mi.asImage()
        guard let img else { return }
        image = img
        // Sit the image on the text baseline (descent below the line).
        bounds = CGRect(x: 0, y: -(layout?.descent ?? 0), width: img.size.width, height: img.size.height)
    }
}

enum MathSupport {
    static let displayRE = try! NSRegularExpression(pattern: #"\$\$(.+?)\$\$"#, options: [.dotMatchesLineSeparators])
    static let inlineRE  = try! NSRegularExpression(pattern: #"(?<!\\)\$([^$\n]+?)\$"#)

    /// Is the caret strictly inside a `$…$` / `$$…$$` source span (i.e. being edited)?
    static func caretInsideMath(_ s: String, _ caret: Int) -> Bool {
        let ns = s as NSString
        for re in [displayRE, inlineRE] {
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                if caret > m.range.location && caret < m.range.location + m.range.length { return true }
            }
        }
        return false
    }
}

extension NSAttributedString {
    /// `$…$` / `$$…$$` spans → rendered math attachments, in place.
    func installingMath() -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: self)
        func pass(_ re: NSRegularExpression, display: Bool) {
            let ns = m.string as NSString
            for match in re.matches(in: m.string, range: NSRange(location: 0, length: ns.length)).reversed() {
                // Don't re-render a span that already holds an attachment.
                if m.attributedSubstring(from: match.range).string.contains("\u{FFFC}") { continue }
                let latex = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
                guard !latex.isEmpty else { continue }
                m.replaceCharacters(in: match.range,
                                    with: NSAttributedString(attachment: MathAttachment(latex: latex, display: display)))
            }
        }
        pass(MathSupport.displayRE, display: true)
        pass(MathSupport.inlineRE, display: false)
        return m
    }

    /// Math attachments → `$…$` source text (for save / preview / search).
    func expandingMath() -> NSAttributedString {
        let out = NSMutableAttributedString()
        enumerateAttribute(.attachment, in: NSRange(location: 0, length: length)) { val, range, _ in
            if let ma = val as? MathAttachment {
                out.append(NSAttributedString(string: ma.display ? "$$\(ma.latex)$$" : "$\(ma.latex)$"))
            } else {
                out.append(attributedSubstring(from: range))
            }
        }
        return out
    }
}
