import SwiftUI
import AppKit

/// Live LaTeX playground: type math, see it render instantly (KaTeX), with a
/// symbol palette and one-tap insert into a note. Bare LaTeX is auto-wrapped in
/// `$$…$$` for the preview, so `\frac{1}{2}` renders without typing delimiters.
struct EquationView: View {
    @EnvironmentObject var state: AppState
    @AppStorage("equationSource") private var source =
        "$$\\int_0^1 x^2\\,dx = \\frac{1}{3}$$\n\nInline works too: $E = mc^2$"
    @StateObject private var editor = MathSourceController()
    @State private var savedNote = false

    /// Bare LaTeX (no `$`) is wrapped so it renders; mixed markdown+math passes through.
    private var previewText: String {
        source.contains("$") ? source : "$$\n\(source)\n$$"
    }

    var body: some View {
        NavigationStack {
            ModulePane(title: "Equation") {
                HStack(spacing: 8) {
                    Button { copyLatex() } label: { Image(systemName: "doc.on.doc") }
                        .help("Copy LaTeX")
                    Button { saveAsNote() } label: {
                        Image(systemName: savedNote ? "checkmark" : "note.text.badge.plus")
                    }
                    .foregroundStyle(savedNote ? AnyShapeStyle(.green) : AnyShapeStyle(.primary))
                    .help("Save as a note")
                }
            } content: {
                VStack(spacing: 0) {
                    palette
                    Divider()
                    // Source
                    MathSourceEditor(text: $source, controller: editor)
                        .frame(minHeight: 90, maxHeight: 150)
                        .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
                    Divider()
                    // Live render
                    SectionHeaderRow()
                    ScrollView {
                        RichText(text: previewText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(DS.Space.l)
                    }
                }
            }
        }
    }

    // Symbol / template palette — inserts at the cursor.
    private var palette: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ins("½", "\\frac{}{}", back: 3)
                ins("√", "\\sqrt{}", back: 1)
                ins("xⁿ", "^{}", back: 1)
                ins("xₙ", "_{}", back: 1)
                ins("Σ", "\\sum_{}^{}", back: 3)
                ins("∫", "\\int_{}^{}", back: 3)
                ins("∂", "\\partial ")
                ins("∞", "\\infty ")
                ins("→", "\\to ")
                ins("≤", "\\leq ")
                ins("≥", "\\geq ")
                ins("≠", "\\neq ")
                ins("≈", "\\approx ")
                ins("±", "\\pm ")
                ins("·", "\\cdot ")
                ins("⃗", "\\vec{}", back: 1)
                menu("Greek", greek)
                menu("Structures", structures)
                Button { wrapDisplay() } label: { Text("$$").font(.caption.monospaced()) }
                    .buttonStyle(.bordered).controlSize(.small).help("Wrap in a display block")
            }
            .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
        }
    }

    private func ins(_ label: String, _ snippet: String, back: Int = 0) -> some View {
        Button { editor.insert(snippet, back: back) } label: {
            Text(label).font(.callout)
        }.buttonStyle(.bordered).controlSize(.small)
    }
    private func menu(_ title: String, _ items: [(String, String)]) -> some View {
        Menu(title) {
            ForEach(items, id: \.0) { name, snip in
                Button(name) { editor.insert(snip) }
            }
        }.menuStyle(.borderlessButton).fixedSize().font(.caption)
    }

    private let greek: [(String, String)] = [
        ("α alpha", "\\alpha "), ("β beta", "\\beta "), ("γ gamma", "\\gamma "), ("δ delta", "\\delta "),
        ("ε epsilon", "\\varepsilon "), ("θ theta", "\\theta "), ("λ lambda", "\\lambda "), ("μ mu", "\\mu "),
        ("π pi", "\\pi "), ("ρ rho", "\\rho "), ("σ sigma", "\\sigma "), ("φ phi", "\\varphi "),
        ("ω omega", "\\omega "), ("Δ Delta", "\\Delta "), ("Σ Sigma", "\\Sigma "), ("Ω Omega", "\\Omega "),
    ]
    private let structures: [(String, String)] = [
        ("Matrix", "\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}"),
        ("Cases", "\\begin{cases} x & x>0 \\\\ 0 & x\\le 0 \\end{cases}"),
        ("Limit", "\\lim_{x \\to 0} "),
        ("Overline", "\\overline{}"),
        ("Hat", "\\hat{}"),
        ("Text in math", "\\text{}"),
    ]

    private func wrapDisplay() {
        source = source.contains("$") ? source : "$$\n\(source)\n$$"
    }
    private func copyLatex() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(source, forType: .string)
    }
    private func saveAsNote() {
        let title = source.split(separator: "\n").first.map { String($0).prefix(40) }.map(String.init) ?? "Equation"
        state.data.notes.append(Note(title: title.isEmpty ? "Equation" : title, body: source, tags: ["equation"]))
        savedNote = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { savedNote = false }
    }
}

/// "PREVIEW" label above the live render.
private struct SectionHeaderRow: View {
    var body: some View {
        HStack {
            SectionHeader(title: "Preview", systemImage: "function")
            Spacer()
        }.padding(.horizontal, DS.Space.l).padding(.top, DS.Space.m)
    }
}

// MARK: - Plain source editor (monospaced NSTextView with cursor-aware insert)

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
