import SwiftUI

/// Keyboard list navigation — the "pro Mac app" feel. Attach to a scroll container over a
/// list of `UUID`-identified rows: once the list has focus (click a row, or Tab into it),
///   • `j` / ↓ move the selection down, `k` / ↑ move it up (clamped at the ends),
///   • `Return` activates the selected row, `Esc` runs the escape hook (deselect / back).
/// The caller highlights the row whose id == `selection` and scrolls it into view.
struct KeyboardListNav: ViewModifier {
    let ids: [UUID]
    @Binding var selection: UUID?
    let onActivate: (UUID) -> Void
    var onEscape: (() -> Void)? = nil

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { move(1) }
            .onKeyPress(KeyEquivalent("j")) { move(1) }
            .onKeyPress(.upArrow) { move(-1) }
            .onKeyPress(KeyEquivalent("k")) { move(-1) }
            .onKeyPress(.return) {
                guard let s = selection else { return .ignored }
                onActivate(s); return .handled
            }
            .onKeyPress(.escape) {
                guard let e = onEscape else { return .ignored }
                e(); return .handled
            }
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard !ids.isEmpty else { return .ignored }
        if let cur = selection, let i = ids.firstIndex(of: cur) {
            selection = ids[min(max(0, i + delta), ids.count - 1)]
        } else {
            selection = delta > 0 ? ids.first : ids.last
        }
        return .handled
    }
}

extension View {
    func keyboardListNav(ids: [UUID], selection: Binding<UUID?>,
                         onActivate: @escaping (UUID) -> Void,
                         onEscape: (() -> Void)? = nil) -> some View {
        modifier(KeyboardListNav(ids: ids, selection: selection, onActivate: onActivate, onEscape: onEscape))
    }
}

/// A subtle selection ring for a keyboard-selected row — accent tint, no fill change, so it
/// reads as "focused here" without shouting. Compose over the row's own background.
extension View {
    @ViewBuilder func kbSelected(_ on: Bool, radius: CGFloat = DS.Radius.card) -> some View {
        overlay {
            if on {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(.tint, lineWidth: 2)
            }
        }
    }
}
