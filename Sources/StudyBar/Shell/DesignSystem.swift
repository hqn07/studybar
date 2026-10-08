import SwiftUI

/// StudyBar design system — "Quiet Study Desk".
///
/// Refined-native: SF Pro + system materials, respects light/dark and the system
/// accent, with one shared component vocabulary so every module looks the same.
/// **Direction (also in CLAUDE.md):** compose from these primitives — never
/// hand-roll a new chip, row, radius or spacing. Semantic color = state only.
///
/// Not yet adopted by modules (kit-first); migrate module-by-module.
enum DS {
    /// Three radii, nothing else. control = pills/buttons, card = rows/panels, modal = overlays.
    enum Radius { static let control: CGFloat = 6; static let card: CGFloat = 10; static let modal: CGFloat = 14 }
    /// Spacing on a base-4 step.
    enum Space { static let xs: CGFloat = 4; static let s: CGFloat = 6; static let m: CGFloat = 8; static let l: CGFloat = 12; static let xl: CGFloat = 16 }
    /// Column widths. `content` caps a module's lists and dashboards on a wide window (the header
    /// still spans); `prose` is a reading measure for running text, ~70 characters; `form` is
    /// for question-and-answer layouts (quizzes, progress) that are not prose but read as one.
    enum Width { static let content: CGFloat = 1200; static let prose: CGFloat = 680; static let form: CGFloat = 760 }
}

/// How wide a module's page may grow. `ModulePane` holds a module's main page to its column; a
/// page pushed inside the module (an editor, a detail page) has no ModulePane, so it calls
/// `.moduleColumn()` — or `.moduleColumn(DS.Width.form)` for a form — itself.
enum ModuleColumn {
    /// The page's own width, never past the module's cap; with no cap (the popover, a spatial
    /// module) the page is left alone. Pure.
    static func width(_ requested: CGFloat?, cap: CGFloat?) -> CGFloat? {
        guard let cap else { return nil }
        return min(requested ?? cap, cap)
    }
}

private struct ModuleColumnModifier: ViewModifier {
    let width: CGFloat?
    @Environment(\.moduleContentCap) private var cap
    func body(content: Content) -> some View {
        content.frame(maxWidth: ModuleColumn.width(width, cap: cap) ?? .infinity).frame(maxWidth: .infinity)
    }
}

extension View {
    /// Hold this page to its module's column (see `ModuleColumn`).
    func moduleColumn(_ width: CGFloat? = nil) -> some View { modifier(ModuleColumnModifier(width: width)) }
}

private struct ModuleContentCapKey: EnvironmentKey { static let defaultValue: CGFloat? = nil }
extension EnvironmentValues {
    /// How wide a module's content may grow — set by the window for non-spatial modules,
    /// nil (no cap) everywhere else, the popover included. `ModulePane` applies it below its header.
    var moduleContentCap: CGFloat? {
        get { self[ModuleContentCapKey.self] }
        set { self[ModuleContentCapKey.self] = newValue }
    }
}

extension Color {
    /// Semantic status colors — used for state ONLY (urgency, done, overdue), never decoration.
    static let dsNow = Color.red
    static let dsWeek = Color.orange
    static let dsDone = Color(red: 0.21, green: 0.71, blue: 0.67)   // teal
}

// MARK: - Chip — one component, four variants

/// The single chip/pill/tag primitive. Replaces keyword pills, tag chips, urgency
/// pills, filter chips and course chips.
///
/// ```
/// Chip("Email")                              // .tag  — soft accent
/// Chip("Email", .filter, selected: true)     // filter (segmented)
/// Chip(";ext", .key)                         // mono keyboard-key
/// Chip("Now", .status(.now))                 // status (semantic color)
/// Chip("MAP2302", .filter, dot: course.color)// leading course dot
/// ```
struct Chip: View {
    enum Style: Equatable { case tag, filter, key, status(Status) }
    enum Status: Equatable { case now, week, done, neutral
        var color: Color {
            switch self { case .now: .dsNow; case .week: .dsWeek; case .done: .dsDone; case .neutral: .secondary }
        }
    }

    let text: String
    var style: Style = .tag
    var selected: Bool = false
    var systemImage: String? = nil
    var dot: Color? = nil

    init(_ text: String, _ style: Style = .tag, selected: Bool = false,
         systemImage: String? = nil, dot: Color? = nil) {
        self.text = text; self.style = style; self.selected = selected
        self.systemImage = systemImage; self.dot = dot
    }

    var body: some View {
        HStack(spacing: 4) {
            if let dot { Circle().fill(dot).frame(width: 7, height: 7).accessibilityHidden(true) }
            if let systemImage { Image(systemName: systemImage).font(.system(size: 9, weight: .bold)).accessibilityHidden(true) }
            Text(text)
        }
        .font(font)
        .padding(.horizontal, style == .key ? 7 : 8)
        .padding(.vertical, style == .key ? 3 : 2.5)
        .background(background, in: shape)
        .overlay { if style == .key { RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(.separator, lineWidth: 0.5) } }
        .foregroundStyle(foreground)
        .animation(.snappy(duration: 0.18), value: selected)   // filter/tab chips ease on toggle
    }

    private var font: Font {
        switch style {
        case .key: .caption2.weight(.medium).monospaced()
        case .filter: .caption.weight(selected ? .semibold : .regular)
        default: .caption2.weight(.semibold)
        }
    }
    private var shape: AnyShape {
        style == .key ? AnyShape(RoundedRectangle(cornerRadius: DS.Radius.control)) : AnyShape(Capsule())
    }
    private var background: AnyShapeStyle {
        switch style {
        case .tag: AnyShapeStyle(.tint.opacity(0.15))
        case .filter: selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.sbSurface)
        case .key: AnyShapeStyle(.sbSurface2)
        case .status(let s): AnyShapeStyle(s.color.opacity(0.18))
        }
    }
    private var foreground: AnyShapeStyle {
        switch style {
        case .tag: AnyShapeStyle(.tint)
        case .filter: selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary)
        case .key: AnyShapeStyle(.primary)
        case .status(let s): AnyShapeStyle(s.color)
        }
    }
}

// MARK: - SBRow — the canonical list item

/// Icon · title · subtitle · trailing — a plain line, not a card: no fill, a hairline below,
/// the surface only under the pointer. Every module's list row should be this (or carry
/// `.sbRowSeparator()` when its layout is its own). Cards are for things you pick up and act on.
struct SBRow<Trailing: View>: View {
    var systemImage: String? = nil
    let title: String
    var subtitle: String? = nil
    var iconTint: Color = .accentColor
    var separator = true
    @ViewBuilder var trailing: () -> Trailing
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 11) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 14))
                    .foregroundStyle(iconTint)
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)   // decorative — the title carries the meaning
                    .background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.control))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium)).lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: DS.Space.s)
            trailing()
        }
        .padding(DS.Space.m)
        .background(hovering ? AnyShapeStyle(.sbSurface) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: DS.Radius.control))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .modifier(RowSeparator(leading: separator ? DS.Space.m + (systemImage == nil ? 0 : 30 + 11) : nil))
    }
}
extension SBRow where Trailing == EmptyView {
    init(systemImage: String? = nil, title: String, subtitle: String? = nil, iconTint: Color = .accentColor, separator: Bool = true) {
        self.init(systemImage: systemImage, title: title, subtitle: subtitle, iconTint: iconTint, separator: separator) { EmptyView() }
    }
}

/// The hairline under a list row, inset to where its text starts.
private struct RowSeparator: ViewModifier {
    let leading: CGFloat?
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let leading { Divider().padding(.leading, leading) }
        }
    }
}

extension View {
    /// The list-row hairline for a row whose layout `SBRow` can't express.
    func sbRowSeparator(leading: CGFloat = 0) -> some View { modifier(RowSeparator(leading: leading)) }
}

// MARK: - SectionHeader — collapsible group label

/// The uppercase group label + count used above grouped lists (Snippets categories,
/// Files groups, board columns). Pair with a `DisclosureGroup` for collapsibility.
struct SectionHeader: View {
    let title: String
    var count: Int? = nil
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: DS.Space.s) {
            if let systemImage { Image(systemName: systemImage).font(.caption2).foregroundStyle(.tint) }
            Text(title.uppercased())
                .font(.caption2.weight(.bold)).tracking(0.6).foregroundStyle(.secondary)
            if let count {
                Text("\(count)").font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.sbSurface, in: Capsule())
            }
        }
    }
}

// MARK: - Glance numbers

extension Font {
    /// The one style for a number worth seeing at a glance — a GPA, what's due, a streak. Large,
    /// so the hierarchy comes from type rather than from a box drawn around it.
    static let dsGlance = Font.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit()
}

/// A number and what it counts. `isEmpty` marks a zero or a missing value: it is left out
/// rather than drawn as "0" or "—", which take the same room as data and say nothing.
struct GlanceStat: Identifiable {
    let value: String
    let label: String
    var isEmpty = false
    var id: String { label }
}

/// A row of glance numbers, value over label. Stats marked empty are left out; when all are,
/// `emptyText` says so in one line (or the row draws nothing). Wraps to a grid when narrow.
struct GlanceRow: View {
    let stats: [GlanceStat]
    var emptyText: String? = nil

    var body: some View {
        let shown = stats.filter { !$0.isEmpty }
        if shown.isEmpty {
            if let emptyText { Text(emptyText).font(.callout).foregroundStyle(.secondary) }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 32) { ForEach(shown) { stat($0) } }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), alignment: .leading)], alignment: .leading,
                          spacing: DS.Space.l) { ForEach(shown) { stat($0) } }
            }
        }
    }

    private func stat(_ s: GlanceStat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(s.value).font(.dsGlance).lineLimit(1)
            Text(s.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Card container

extension View {
    /// Standard card surface: card radius + secondary background. Use for panels/rows
    /// that aren't an SBRow.
    func dsCard(padding: CGFloat = DS.Space.m) -> some View {
        self.padding(padding)
            .background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(.sbSurfaceStroke, lineWidth: 0.5))
    }
}

// MARK: - Buttons
//
// Use the native styles, mapped consistently:
//   primary   → .buttonStyle(.borderedProminent)
//   secondary → .buttonStyle(.bordered)
//   ghost     → .buttonStyle(.borderless)  (tinted)
//   danger    → Button(role: .destructive)
// No custom button style needed — native gives the right look + accent.

// MARK: - Horizontal strip that admits it scrolls

/// A horizontal scroller that fades its trailing edge while there is more content than fits.
///
/// A plain `ScrollView(.horizontal, showsIndicators: false)` of chips is honest until the window
/// narrows: then the last chip is sliced down the middle with nothing on screen saying the row
/// can be scrolled, which reads as a broken layout rather than a scrollable one. The fade only
/// appears when the content actually overflows, so a row that fits looks untouched.
struct FadingHScroll<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var contentWidth: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0

    private var overflowing: Bool { contentWidth > viewportWidth + 1 }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            content.background(
                GeometryReader { g in Color.clear.preference(key: StripWidth.self, value: g.size.width) })
        }
        .background(
            GeometryReader { g in Color.clear.preference(key: StripViewport.self, value: g.size.width) })
        .onPreferenceChange(StripWidth.self) { contentWidth = $0 }
        .onPreferenceChange(StripViewport.self) { viewportWidth = $0 }
        .mask {
            LinearGradient(stops: overflowing
                           ? [.init(color: .black, location: 0),
                              .init(color: .black, location: 0.9),
                              .init(color: .black.opacity(0.05), location: 1)]
                           : [.init(color: .black, location: 0), .init(color: .black, location: 1)],
                           startPoint: .leading, endPoint: .trailing)
        }
    }
}

private struct StripWidth: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private struct StripViewport: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
