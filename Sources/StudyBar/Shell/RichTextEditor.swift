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

    // MARK: Wikilinks — `[[Note Title]]` note-to-note links
    /// The text typed after an open `[[` at the caret (drives the autocomplete strip);
    /// nil when the caret isn't inside an unclosed `[[`.
    @Published var linkQuery: String?
    /// The `[[query` span the autocomplete would replace when a suggestion is picked.
    private var linkReplaceRange: NSRange?
    /// Called when a `[[link]]` is clicked (title passed up so the view can navigate).
    var onOpenLink: (String) -> Void = { _ in }

    static let baseFont = NSFont.systemFont(ofSize: 13)

    /// Undo/redo the text view's own edits (typing + formatting). Backs the
    /// toolbar buttons and the ⌘Z / ⌘⇧Z shortcuts.
    func undo() { if let um = textView?.undoManager, um.canUndo { textView?.window?.makeFirstResponder(textView); um.undo() } }
    func redo() { if let um = textView?.undoManager, um.canRedo { textView?.window?.makeFirstResponder(textView); um.redo() } }

    /// Resolve the dynamic label color to a concrete color for a view's appearance —
    /// so rendered math matches the text (white in dark mode, not a dynamic gray).
    static func resolvedLabel(_ view: NSView) -> NSColor {
        var c = NSColor.labelColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            c = NSColor.labelColor.usingColorSpace(.sRGB) ?? NSColor.labelColor
        }
        return c
    }

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
        // Foreground color also re-renders any math in the selection (the image bakes
        // its color, so a color attribute alone wouldn't change it).
        if key == .foregroundColor {
            var maths: [(NSRange, MathAttachment)] = []
            ts.enumerateAttribute(.attachment, in: range) { val, r, _ in
                if let ma = val as? MathAttachment { maths.append((r, ma)) }
            }
            for (r, ma) in maths.reversed() {
                let n = MathAttachment(latex: ma.latex, display: ma.display,
                                       color: color ?? .labelColor, userColored: color != nil)
                ts.replaceCharacters(in: r, with: NSAttributedString(attachment: n))
            }
        }
        if let color { ts.addAttribute(key, value: color, range: range) }
        else { ts.removeAttribute(key, range: range) }
        ts.endEditing()
        tv.didChangeText()
    }

    // MARK: Lists

    func toggleBullet() { togglePrefix("• ", alts: []) }
    /// Tappable checklist — prefixes each line with ☐; clicking the box (see
    /// FoldingTextView) flips ☐⇄☑ and strikes the item through.
    func toggleChecklist() { togglePrefix("☐ ", alts: ["☑ "]) }

    /// Numbered list: adds `1. 2. 3.` across the selected lines, or strips an existing
    /// `N. ` prefix off them. Doesn't live-renumber on edit (kept simple, like bullets).
    func toggleNumbered() {
        withParagraphStarts { starts, ts, full in
            let re = try! NSRegularExpression(pattern: #"^\d+\.\s"#)
            func marker(at loc: Int) -> Int? {
                let rest = NSRange(location: loc, length: min(12, full.length - loc))
                return re.firstMatch(in: full as String, range: rest)?.range.length
            }
            let removing = starts.first.flatMap { marker(at: $0) } != nil
            ts.beginEditing()
            for (n, loc) in starts.enumerated().reversed() {
                if removing {
                    if let len = marker(at: loc) { ts.replaceCharacters(in: NSRange(location: loc, length: len), with: "") }
                } else if marker(at: loc) == nil {
                    ts.replaceCharacters(in: NSRange(location: loc, length: 0),
                        with: NSAttributedString(string: "\(n + 1). ", attributes: typingAttrs))
                }
            }
            ts.endEditing()
        }
    }

    /// Blockquote: indents the selected paragraphs and greys them (a pure paragraph-style
    /// change, so inline formatting and images survive). Toggles off when already quoted.
    func toggleQuote() {
        guard let tv = textView, let ts = tv.textStorage else { return }
        let para = (tv.string as NSString).paragraphRange(for: tv.selectedRange())
        guard para.length >= 0 else { return }
        let existing = (ts.length > para.location
            ? ts.attribute(.paragraphStyle, at: para.location, effectiveRange: nil) as? NSParagraphStyle : nil)
        let quoted = (existing?.headIndent ?? 0) > 0
        let ps = NSMutableParagraphStyle()
        if !quoted { ps.headIndent = 18; ps.firstLineHeadIndent = 18 }
        ts.beginEditing()
        ts.addAttribute(.paragraphStyle, value: ps, range: para)
        ts.addAttribute(.foregroundColor, value: quoted ? NSColor.labelColor : NSColor.secondaryLabelColor, range: para)
        ts.endEditing()
        tv.didChangeText()
    }

    /// Insert a horizontal divider on its own line.
    func insertDivider() {
        guard let tv = textView, let ts = tv.textStorage else { return }
        let loc = tv.selectedRange().location
        let atLineStart = loc == 0 || (ts.string as NSString).substring(with: NSRange(location: loc - 1, length: 1)) == "\n"
        let rule = NSMutableAttributedString(string: (atLineStart ? "" : "\n") + "──────────\n",
            attributes: [.font: Self.baseFont, .foregroundColor: NSColor.tertiaryLabelColor])
        if tv.shouldChangeText(in: NSRange(location: loc, length: 0), replacementString: rule.string) {
            ts.insert(rule, at: loc)
            tv.didChangeText()
        }
    }

    private var typingAttrs: [NSAttributedString.Key: Any] {
        textView?.typingAttributes ?? [.font: Self.baseFont, .foregroundColor: NSColor.labelColor]
    }

    /// Add/remove a line prefix on every paragraph intersecting the selection, by pure
    /// insert/delete at line starts — preserving each paragraph's inline formatting
    /// (unlike a full-paragraph rewrite). Removes if the first line already carries the
    /// prefix (or one of `alts`), else adds.
    private func togglePrefix(_ prefix: String, alts: [String]) {
        withParagraphStarts { starts, ts, full in
            let markers = [prefix] + alts
            func existing(at loc: Int) -> Int? {
                for m in markers where loc + m.count <= full.length &&
                    full.substring(with: NSRange(location: loc, length: m.count)) == m { return m.count }
                return nil
            }
            let removing = starts.first.flatMap { existing(at: $0) } != nil
            ts.beginEditing()
            for loc in starts.reversed() {
                if removing {
                    if let len = existing(at: loc) { ts.replaceCharacters(in: NSRange(location: loc, length: len), with: "") }
                } else if existing(at: loc) == nil {
                    ts.replaceCharacters(in: NSRange(location: loc, length: 0),
                        with: NSAttributedString(string: prefix, attributes: typingAttrs))
                }
            }
            ts.endEditing()
        }
    }

    /// Run `body` with the start index of every paragraph the selection touches (absolute,
    /// pre-mutation — iterate reversed so edits don't shift later indices).
    private func withParagraphStarts(_ body: ([Int], NSTextStorage, NSString) -> Void) {
        guard let tv = textView, let ts = tv.textStorage else { return }
        let full = ts.string as NSString
        let para = full.paragraphRange(for: tv.selectedRange())
        var starts: [Int] = []
        full.enumerateSubstrings(in: para, options: [.byParagraphs, .substringNotRequired]) { _, r, _, _ in
            starts.append(r.location)
        }
        if starts.isEmpty { starts = [para.location] }
        body(starts, ts, full)
        tv.didChangeText()
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

    // MARK: Wikilink autocomplete

    /// Refresh `linkQuery` from the text just before the caret: set it to whatever
    /// follows the nearest unclosed `[[` on the line, else clear it. Called on every
    /// edit and caret move.
    func detectLinkContext() {
        guard let tv = textView, tv.selectedRange().length == 0 else { linkQuery = nil; return }
        let ns = tv.string as NSString
        let caret = min(tv.selectedRange().location, ns.length)
        let open = ns.range(of: "[[", options: .backwards, range: NSRange(location: 0, length: caret))
        guard open.location != NSNotFound else { linkQuery = nil; return }
        let queryRange = NSRange(location: open.location + 2, length: caret - (open.location + 2))
        let query = ns.substring(with: queryRange)
        if query.contains("]") || query.contains("\n") { linkQuery = nil; return }
        linkReplaceRange = NSRange(location: open.location, length: caret - open.location)
        linkQuery = query
    }

    /// Replace the open `[[query` with a finished `[[title]]` link and dismiss the strip.
    func completeLink(_ title: String) {
        guard let tv = textView, let r = linkReplaceRange else { linkQuery = nil; return }
        let text = "[[\(title)]]"
        if tv.shouldChangeText(in: r, replacementString: text) {
            tv.textStorage?.replaceCharacters(in: r, with: NSAttributedString(string: text, attributes: typingAttrs))
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: r.location + (text as NSString).length, length: 0))
        }
        linkQuery = nil; linkReplaceRange = nil
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
        let installed = initial.installingFolds().installingMath(defaultColor: RichTextController.resolvedLabel(tv)).installingWikilinks()
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
            controller.detectLinkContext()
            controller.onEdit()
        }

        /// When the caret leaves a math expression it was editing, re-render it in place.
        func textViewDidChangeSelection(_ notification: Notification) {
            controller.detectLinkContext()
            guard controller.mathEditing, let tv = notification.object as? NSTextView,
                  let ts = tv.textStorage else { return }
            if MathSupport.caretInsideMath(tv.string, tv.selectedRange().location) { return }
            let caret = tv.selectedRange().location
            let rebuilt = tv.attributedString().installingMath(defaultColor: RichTextController.resolvedLabel(tv))
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
                if event.clickCount >= 2 {
                    revealMath(math, at: cand)               // double-click → edit its source
                } else {
                    setSelectedRange(NSRange(location: cand, length: 1))  // single click → select it (ready to recolor)
                    window?.makeFirstResponder(self)
                }
                return
            }
            if let fold = ts.attribute(.attachment, at: cand, effectiveRange: nil) as? FoldAttachment {
                toggle(fold, at: cand)
                return   // consume — don't move the caret
            }
        }
        // Tap a ☐/☑ checkbox to flip it.
        for cand in [idx, idx - 1] where cand >= 0 && cand < ts.length {
            let ch = (ts.string as NSString).substring(with: NSRange(location: cand, length: 1))
            if ch == "☐" || ch == "☑" { toggleCheckbox(at: cand, done: ch == "☑"); return }
        }
        // Tap a [[wikilink]] to open (or create) that note.
        if let title = wikilinkTitle(at: idx) { mathController?.onOpenLink(title); return }
        super.mouseDown(with: event)
    }

    /// The link title if `idx` falls inside a `[[…]]` span on its line, else nil.
    private func wikilinkTitle(at idx: Int) -> String? {
        guard let ts = textStorage, ts.length > 0 else { return nil }
        let ns = ts.string as NSString
        let para = ns.paragraphRange(for: NSRange(location: min(idx, ns.length - 1), length: 0))
        let line = ns.substring(with: para) as NSString
        for m in NSAttributedString.wikilinkRegex.matches(in: line as String, range: NSRange(location: 0, length: line.length)) {
            let abs = NSRange(location: para.location + m.range.location, length: m.range.length)
            if idx >= abs.location && idx < abs.location + abs.length {
                return line.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Flip a checklist box and strike/unstrike the rest of its line.
    private func toggleCheckbox(at loc: Int, done: Bool) {
        guard let ts = textStorage else { return }
        let ns = ts.string as NSString
        let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
        var bodyStart = loc + 1
        if bodyStart < ns.length, ns.substring(with: NSRange(location: bodyStart, length: 1)) == " " { bodyStart += 1 }
        var bodyEnd = para.location + para.length
        if bodyEnd > para.location, ns.substring(with: NSRange(location: bodyEnd - 1, length: 1)) == "\n" { bodyEnd -= 1 }
        let attrs = ts.attributes(at: loc, effectiveRange: nil)
        ts.beginEditing()
        ts.replaceCharacters(in: NSRange(location: loc, length: 1),
                             with: NSAttributedString(string: done ? "☐" : "☑", attributes: attrs))
        let body = NSRange(location: bodyStart, length: max(0, bodyEnd - bodyStart))
        if body.length > 0 {
            if done {   // was checked → uncheck: clear strike + restore color
                ts.removeAttribute(.strikethroughStyle, range: body)
                ts.addAttribute(.foregroundColor, value: NSColor.labelColor, range: body)
            } else {
                ts.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: body)
                ts.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: body)
            }
        }
        ts.endEditing()
        didChangeText()
    }

    /// The app has no menu bar (menu-bar accessory), so ⌘Z / ⌘⇧Z have no menu key
    /// equivalent — drive this text view's own undo manager directly.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "z", let um = undoManager {
            if event.modifierFlags.contains(.shift) {
                if um.canRedo { um.redo(); return true }
            } else if um.canUndo { um.undo(); return true }
        }
        return super.performKeyEquivalent(with: event)
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

// MARK: - Wikilinks — style `[[Note Title]]` spans on load

extension NSAttributedString {
    static let wikilinkRegex = try! NSRegularExpression(pattern: #"\[\[([^\]\n]+?)\]\]"#)

    /// Tint + underline every `[[…]]` span so links read as links. The text stays literal
    /// `[[Title]]` (so it round-trips through RTFD/search untouched); clicks are resolved
    /// by scanning the line (see FoldingTextView.wikilinkTitle), not by an attribute.
    func installingWikilinks() -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: self)
        let ns = m.string as NSString
        for match in Self.wikilinkRegex.matches(in: m.string, range: NSRange(location: 0, length: ns.length)) {
            m.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: match.range)
            m.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: match.range)
        }
        return m
    }
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
    let color: NSColor
    /// True when the color is a deliberate user choice (persist it); false = follow
    /// the current text color (re-resolved on each load, so it adapts to the theme).
    let userColored: Bool
    init(latex: String, display: Bool, color: NSColor, userColored: Bool) {
        self.latex = latex; self.display = display; self.color = color; self.userColored = userColored
        super.init(data: nil, ofType: nil)
        render()
    }
    required init?(coder: NSCoder) { latex = ""; display = false; color = .labelColor; userColored = false; super.init(coder: coder) }

    private func render() {
        var mi = MathImage(latex: latex, fontSize: display ? 19 : 15,
                           textColor: color, labelMode: display ? .display : .text)
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
    /// `$…$` / `$$…$$` spans → rendered math attachments, in place. Spans that carry
    /// an explicit `.foregroundColor` render in that color (persisted); others follow
    /// `defaultColor` (the current text color).
    func installingMath(defaultColor: NSColor = .labelColor) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: self)
        func pass(_ re: NSRegularExpression, display: Bool) {
            let ns = m.string as NSString
            for match in re.matches(in: m.string, range: NSRange(location: 0, length: ns.length)).reversed() {
                // Don't re-render a span that already holds an attachment.
                if m.attributedSubstring(from: match.range).string.contains("\u{FFFC}") { continue }
                let latex = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
                guard !latex.isEmpty else { continue }
                let explicit = m.attribute(.foregroundColor, at: match.range.location, effectiveRange: nil) as? NSColor
                let att = MathAttachment(latex: latex, display: display,
                                         color: explicit ?? defaultColor, userColored: explicit != nil)
                m.replaceCharacters(in: match.range, with: NSAttributedString(attachment: att))
            }
        }
        pass(MathSupport.displayRE, display: true)
        pass(MathSupport.inlineRE, display: false)
        return m
    }

    /// Math attachments → `$…$` source text (for save / preview / search). A
    /// user-chosen color is preserved on the source run so it round-trips.
    func expandingMath() -> NSAttributedString {
        let out = NSMutableAttributedString()
        enumerateAttribute(.attachment, in: NSRange(location: 0, length: length)) { val, range, _ in
            if let ma = val as? MathAttachment {
                let src = ma.display ? "$$\(ma.latex)$$" : "$\(ma.latex)$"
                var attrs: [NSAttributedString.Key: Any] = [.font: RichTextController.baseFont]
                if ma.userColored { attrs[.foregroundColor] = ma.color }
                out.append(NSAttributedString(string: src, attributes: attrs))
            } else {
                out.append(attributedSubstring(from: range))
            }
        }
        return out
    }
}
