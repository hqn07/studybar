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
            if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
            if let systemImage { Image(systemName: systemImage).font(.system(size: 9, weight: .bold)) }
            Text(text)
        }
        .font(font)
        .padding(.horizontal, style == .key ? 7 : 8)
        .padding(.vertical, style == .key ? 3 : 2.5)
        .background(background, in: shape)
        .overlay { if style == .key { RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(.separator, lineWidth: 0.5) } }
        .foregroundStyle(foreground)
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
        case .filter: selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.background.secondary)
        case .key: AnyShapeStyle(.background.tertiary)
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

/// Icon · title · subtitle · trailing. One height, one radius, one surface.
/// Every module's list row should be this.
struct SBRow<Trailing: View>: View {
    var systemImage: String? = nil
    let title: String
    var subtitle: String? = nil
    var iconTint: Color = .accentColor
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 11) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 14))
                    .foregroundStyle(iconTint)
                    .frame(width: 30, height: 30)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: DS.Radius.control))
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
        .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.m + 1)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }
}
extension SBRow where Trailing == EmptyView {
    init(systemImage: String? = nil, title: String, subtitle: String? = nil, iconTint: Color = .accentColor) {
        self.init(systemImage: systemImage, title: title, subtitle: subtitle, iconTint: iconTint) { EmptyView() }
    }
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
                    .background(.background.secondary, in: Capsule())
            }
        }
    }
}

// MARK: - Card container

extension View {
    /// Standard card surface: card radius + secondary background. Use for panels/rows
    /// that aren't an SBRow.
    func dsCard(padding: CGFloat = DS.Space.m) -> some View {
        self.padding(padding)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: DS.Radius.card))
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
