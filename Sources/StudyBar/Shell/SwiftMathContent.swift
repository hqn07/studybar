import SwiftUI
import AppKit
import SwiftMath

/// Native (SwiftMath) rendering of a note's markdown + LaTeX for previews, flashcards and
/// the Equation module — the same engine the editor uses inline, so what you see rendered
/// matches what you typed. Falls back to the bundled KaTeX web view only when SwiftMath
/// can't parse an expression, so coverage never regresses.

enum SwiftMathRender {
    /// A single LaTeX expression → an image, or nil if SwiftMath can't render it.
    static func image(_ latex: String, display: Bool, color: NSColor, size: CGFloat) -> NSImage? {
        let l = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !l.isEmpty else { return nil }
        var mi = MathImage(latex: l, fontSize: size, textColor: color, labelMode: display ? .display : .text)
        let (err, img, _) = mi.asImage()
        return err == nil ? img : nil
    }

    /// The label color resolved for a light/dark preview (SwiftMath bakes the color into
    /// the image, so it must match the surface).
    static func labelColor(dark: Bool) -> NSColor {
        var c = NSColor.labelColor
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            c = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor
        }
        return c
    }
}

/// Renders `text` (markdown + `$…$` / `$$…$$`) with native math; if any expression fails
/// to parse, the whole block falls back to KaTeX so nothing is ever dropped.
struct SwiftMathContent: View {
    let text: String
    @Environment(\.colorScheme) private var scheme
    @State private var height: CGFloat = 18

    var body: some View {
        let color = SwiftMathRender.labelColor(dark: scheme == .dark)
        if let rows = MathRows.build(text, color: color) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(rows.indices, id: \.self) { rows[$0] }
            }
        } else {
            MathWebView(html: MathMarkdown.html(text, dark: scheme == .dark), height: $height)
                .frame(height: max(18, height))
        }
    }
}

/// Builds the row views. Returns nil if any math span can't be rendered natively → caller
/// falls back to KaTeX.
private enum MathRows {
    static func build(_ text: String, color: NSColor) -> [AnyView]? {
        let ns = text as NSString
        var rows: [AnyView] = []
        var cursor = 0
        for m in MathSupport.displayRE.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > cursor {
                let seg = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                guard appendText(seg, color: color, into: &rows) else { return nil }
            }
            let latex = ns.substring(with: m.range(at: 1))
            guard let img = SwiftMathRender.image(latex, display: true, color: color, size: NotesTypography.size + 5) else { return nil }
            rows.append(AnyView(
                HStack { Spacer(minLength: 0); Image(nsImage: img); Spacer(minLength: 0) }
                    .frame(maxWidth: .infinity)))
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            guard appendText(ns.substring(from: cursor), color: color, into: &rows) else { return nil }
        }
        return rows
    }

    private static func appendText(_ seg: String, color: NSColor, into rows: inout [AnyView]) -> Bool {
        for raw in seg.components(separatedBy: "\n") {
            if raw.trimmingCharacters(in: .whitespaces).isEmpty { rows.append(AnyView(Spacer().frame(height: 3))); continue }
            guard let v = blockLine(raw, color: color) else { return false }
            rows.append(v)
        }
        return true
    }

    /// One line → a styled view (heading / list / quote / divider / paragraph), with inline
    /// math + inline markdown inside it.
    private static func blockLine(_ s: String, color: NSColor) -> AnyView? {
        let t = s.trimmingCharacters(in: .whitespaces)
        func styled(_ body: String, _ f: Font) -> AnyView? { inline(body, color: color).map { AnyView($0.font(f)) } }

        if t.hasPrefix("### ") { return styled(String(t.dropFirst(4)), .headline) }
        if t.hasPrefix("## ")  { return styled(String(t.dropFirst(3)), .title3.bold()) }
        if t.hasPrefix("# ")   { return styled(String(t.dropFirst(2)), .title2.bold()) }

        if t.hasPrefix("☑ ") || t.lowercased().hasPrefix("- [x] ") {
            let body = t.hasPrefix("☑ ") ? String(t.dropFirst(2)) : String(t.dropFirst(6))
            guard let it = inline(body, color: color) else { return nil }
            return AnyView(HStack(alignment: .top, spacing: 6) {
                Image(systemName: "checkmark.square.fill").foregroundStyle(.green)
                it.strikethrough().foregroundStyle(.secondary)
            })
        }
        if t.hasPrefix("☐ ") || t.hasPrefix("- [ ] ") || t.hasPrefix("- [] ") {
            let body = t.hasPrefix("☐ ") ? String(t.dropFirst(2)) : String(t[t.range(of: "] ")!.upperBound...])
            guard let it = inline(body, color: color) else { return nil }
            return AnyView(HStack(alignment: .top, spacing: 6) { Image(systemName: "square"); it })
        }
        if t.hasPrefix("• ") || t.hasPrefix("- ") || t.hasPrefix("* ") {
            guard let it = inline(String(t.dropFirst(2)), color: color) else { return nil }
            return AnyView(HStack(alignment: .top, spacing: 6) { Text("•"); it })
        }
        if t.hasPrefix("> ") {
            guard let it = inline(String(t.dropFirst(2)), color: color) else { return nil }
            return AnyView(it.italic().foregroundStyle(.secondary).padding(.leading, 8)
                .overlay(Rectangle().frame(width: 2).foregroundStyle(.tint), alignment: .leading))
        }
        if t.count >= 3, t.allSatisfy({ $0 == "─" || $0 == "-" || $0 == "*" || $0 == "_" }) { return AnyView(Divider().padding(.vertical, 2)) }
        return inline(s, color: color).map { AnyView($0) }
    }

    /// A line's inline content: markdown emphasis + inline `$…$` math images, concatenated
    /// into one wrapping `Text`. nil if a math span can't render natively.
    private static func inline(_ s: String, color: NSColor) -> Text? {
        let ns = s as NSString
        var result = Text("")
        var cursor = 0
        for m in MathSupport.inlineRE.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > cursor {
                result = result + md(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)))
            }
            guard let img = SwiftMathRender.image(ns.substring(with: m.range(at: 1)), display: false, color: color, size: NotesTypography.size) else { return nil }
            result = result + Text("\(Image(nsImage: img))")
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length { result = result + md(ns.substring(from: cursor)) }
        return result
    }

    private static func md(_ s: String) -> Text {
        if let a = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) { return Text(a) }
        return Text(s)
    }
}
