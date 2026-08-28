import SwiftUI
import AppKit

/// A reusable LaTeX symbol/template palette that inserts at the caret of a
/// `MathSourceController` (defined in EquationView). Shared by the Equation module's
/// composer and the Notes equation button so both offer the same clickable math —
/// nobody has to know LaTeX to add an equation.
struct MathPalette: View {
    let editor: MathSourceController

    var body: some View {
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
            }
            .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
        }
    }

    private func ins(_ label: String, _ snippet: String, back: Int = 0) -> some View {
        Button { editor.insert(snippet, back: back) } label: { Text(label).font(.callout) }
            .buttonStyle(.bordered).controlSize(.small)
    }
    private func menu(_ title: String, _ items: [(String, String)]) -> some View {
        Menu(title) {
            ForEach(items, id: \.0) { name, snip in Button(name) { editor.insert(snip) } }
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
}

/// Inline equation composer for the Notes editor: click symbols (or type LaTeX), see it
/// render live, and insert — so math is reachable without knowing `$…$`.
struct NoteEquationComposer: View {
    @State private var latex = ""
    @State private var display = true
    @StateObject private var src = MathSourceController()
    let onInsert: (String, Bool) -> Void
    let onCancel: () -> Void

    private var previewSource: String {
        let l = latex.isEmpty ? "\\square" : latex
        return display ? "$$\(l)$$" : "$\(l)$"
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea().onTapGesture { onCancel() }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Insert equation", systemImage: "function").font(.headline)
                    Spacer()
                    Picker("", selection: $display) {
                        Text("Inline").tag(false); Text("Block").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                MathPalette(editor: src)
                MathSourceEditor(text: $latex, controller: src)
                    .frame(height: 70)
                    .padding(6)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: DS.Radius.control))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(.separator, lineWidth: 0.5))
                VStack(alignment: .leading, spacing: 4) {
                    Text("PREVIEW").font(.caption2.weight(.bold)).tracking(0.6).foregroundStyle(.secondary)
                    ScrollView { RichText(text: previewSource).frame(maxWidth: .infinity, alignment: .leading).padding(6) }
                        .frame(height: 66)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: DS.Radius.control))
                }
                HStack {
                    Text("Tip: type LaTeX, or tap a symbol. No `$` needed.").font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    Button("Cancel") { onCancel() }.keyboardShortcut(.cancelAction)
                    Button("Insert") { onInsert(latex, display) }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                        .disabled(latex.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(16)
            .frame(maxWidth: 480)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.modal))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.modal).stroke(.separator))
            .shadow(radius: 24)
            .padding(20)
        }
    }
}
