import SwiftUI

/// What Esc does in a list: a filter is undone first, then the selection. Pure.
enum ListKeys {
    enum Escape: Equatable { case clearFilter, clearSelection, none }
    static func escape(filterActive: Bool, hasSelection: Bool) -> Escape {
        filterActive ? .clearFilter : (hasSelection ? .clearSelection : .none)
    }
}

/// Keyboard list navigation — the "pro Mac app" feel. Attach to a scroll container over a
/// list of `UUID`-identified rows. In the window's left pane the list takes the keyboard when
/// it appears (and again when the filter field hands it over); elsewhere, once clicked:
///   • `j` / ↓ move the selection down, `k` / ↑ move it up (clamped at the ends),
///   • `Return` opens the selected row, `Space` does its main thing (`onPrimary`, else open),
///   • `⌫` removes it (`onRemove`, which goes through Undo) and selects its neighbour,
///   • `/` and ⌘F go to the toolbar's filter field, `Esc` clears the filter, then the selection.
/// The caller highlights the row whose id == `selection` and scrolls it into view.
struct KeyboardListNav: ViewModifier {
    let ids: [UUID]
    @Binding var selection: UUID?
    let onActivate: (UUID) -> Void
    var onPrimary: ((UUID) -> Void)? = nil
    var onRemove: ((UUID) -> Void)? = nil
    var onEscape: (() -> Void)? = nil

    @Environment(\.listFilter) private var filter
    @Environment(\.listFocusRequest) private var focusRequest
    @Environment(\.workspace) private var workspace
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(.downArrow) { move(1) }
            .onKeyPress(KeyEquivalent("j")) { move(1) }
            .onKeyPress(.upArrow) { move(-1) }
            .onKeyPress(KeyEquivalent("k")) { move(-1) }
            .onKeyPress(.return) {
                guard let s = selection else { return .ignored }
                onActivate(s); return .handled
            }
            .onKeyPress(.space) {
                guard let s = selection else { return .ignored }
                (onPrimary ?? onActivate)(s); return .handled
            }
            .onKeyPress(.delete) {
                guard let s = selection, let remove = onRemove, let i = ids.firstIndex(of: s) else { return .ignored }
                let next = i + 1 < ids.count ? ids[i + 1] : (i > 0 ? ids[i - 1] : nil)
                remove(s)
                selection = next
                return .handled
            }
            .onKeyPress(KeyEquivalent("/")) { toFilter() }
            .onKeyPress(KeyEquivalent("f"), phases: .down) { press in
                press.modifiers == .command ? toFilter() : .ignored
            }
            .onKeyPress(.escape) {
                switch ListKeys.escape(filterActive: filter.isActive, hasSelection: selection != nil) {
                case .clearFilter: workspace?.filter = ListFilter()
                case .clearSelection: if let e = onEscape { e() } else { selection = nil }
                case .none: return .ignored
                }
                return .handled
            }
            // Deferred a turn, as the palette's field is: focused at once, the list isn't in
            // the window yet. Not while a filter is being typed — the field keeps the keys.
            .onAppear {
                guard focusRequest != nil, !filter.isActive else { return }
                DispatchQueue.main.async { focused = true }
            }
            .onChange(of: focusRequest) { _, r in
                guard r != nil else { return }
                focused = true
                if selection == nil { selection = ids.first }
            }
    }

    private func toFilter() -> KeyPress.Result {
        guard let w = workspace, focusRequest != nil else { return .ignored }
        w.focusFilter = true
        return .handled
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
                         onPrimary: ((UUID) -> Void)? = nil,
                         onRemove: ((UUID) -> Void)? = nil,
                         onEscape: (() -> Void)? = nil) -> some View {
        modifier(KeyboardListNav(ids: ids, selection: selection, onActivate: onActivate,
                                 onPrimary: onPrimary, onRemove: onRemove, onEscape: onEscape))
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
