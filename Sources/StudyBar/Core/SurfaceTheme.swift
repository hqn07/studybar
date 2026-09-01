import SwiftUI

/// Surface theme presets — swap the *surface tokens* (base / card / control fills)
/// and nothing else. Accent, status colors (red / amber / teal), radii, spacing and
/// the type scale all hold — see DESIGN.md ("themes swap the accent and surface
/// tokens only, from a curated preset set; every radius, spacing step and component
/// holds").
///
/// `.system` is byte-identical to stock macOS for the default user: the tokens below
/// resolve to the very same `.background.secondary` / `.tertiary` styles the app has
/// always used. A preset only repaints **dark-mode** surfaces; light mode stays
/// native so nobody is dragged off the system look they chose.
///
/// Surfaces route through the `ShapeStyle` helpers `.sbSurface` / `.sbSurface2`
/// (and the hairline `.sbSurfaceStroke`), so a call site reads the *current* preset
/// at render time. `RootView` holds `@AppStorage("surfaceTheme")`, so changing the
/// preset re-renders the tree and every surface re-resolves live.
enum SurfaceTheme: String, CaseIterable, Identifiable {
    case system
    case nearBlack
    case dimGray
    case warmPaper

    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: "System"
        case .nearBlack: "Near-black"
        case .dimGray: "Dim gray"
        case .warmPaper: "Warm paper"
        }
    }

    static let storageKey = "surfaceTheme"

    /// The persisted choice. Cheap — read at render time by the surface tokens.
    static var current: SurfaceTheme {
        SurfaceTheme(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system
    }

    // Surface tiers, base (darkest/backmost) → surface2 (frontmost). `.system` routes to
    // the native hierarchical styles instead (see the ShapeStyle tokens), so its tiers are
    // never read. Dark presets repaint dark mode and leave light native; the light preset
    // (warm paper) repaints light mode and leaves dark native — nobody is dragged off the
    // appearance they chose.
    var base: Color { tiers.base }
    var surface: Color { tiers.surface }
    var surface2: Color { tiers.surface2 }
    /// Hairline separating a card from its base — brighter on dark grounds, ink on light.
    var stroke: Color {
        switch self {
        case .system: .clear
        case .nearBlack, .dimGray: Color.white.opacity(0.06)
        case .warmPaper: Color.black.opacity(0.055)
        }
    }

    private var tiers: (base: Color, surface: Color, surface2: Color) {
        switch self {
        case .system, .nearBlack:
            return (Self.darkPreset(light: .windowBackgroundColor,   dark: "0C0C0F"),
                    Self.darkPreset(light: .controlBackgroundColor,  dark: "17171B"),
                    Self.darkPreset(light: .underPageBackgroundColor, dark: "212127"))
        case .dimGray:
            return (Self.darkPreset(light: .windowBackgroundColor,   dark: "1B1B1F"),
                    Self.darkPreset(light: .controlBackgroundColor,  dark: "27272C"),
                    Self.darkPreset(light: .underPageBackgroundColor, dark: "323238"))
        case .warmPaper:
            return (Self.lightPreset(light: "F1EEE6", dark: .windowBackgroundColor),
                    Self.lightPreset(light: "FBFAF5", dark: .controlBackgroundColor),
                    Self.lightPreset(light: "E7E1D4", dark: .underPageBackgroundColor))
        }
    }

    /// Dark-oriented preset: keep the native `light` NSColor in light mode, use `hex` in dark.
    private static func darkPreset(light: NSColor, dark hex: String) -> Color { dyn(light: light, dark: hex) }
    /// Light-oriented preset: use `hex` in light mode, keep the native `dark` NSColor in dark.
    private static func lightPreset(light hex: String, dark: NSColor) -> Color {
        let l = NSColor(hexString: hex) ?? .white
        return Color(nsColor: NSColor(name: nil) { ap in
            ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : l
        })
    }
    private static func dyn(light: NSColor, dark hex: String) -> Color {
        let d = NSColor(hexString: hex) ?? .black
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? d : light
        })
    }
}

/// Surface-fill tokens. In `.system` they are the native hierarchical styles the app
/// has always used (so the default look is unchanged); in a preset they become the
/// preset's near-black tiers. Use these anywhere a card / row / control fill lives.
extension ShapeStyle where Self == AnyShapeStyle {
    /// Card / row / control-chrome fill. `.system` = the native `.background.secondary`
    /// (unchanged default); any preset = its own surface tier.
    static var sbSurface: AnyShapeStyle {
        let t = SurfaceTheme.current
        return t == .system ? AnyShapeStyle(.background.secondary) : AnyShapeStyle(t.surface)
    }

    /// The tier above `sbSurface` (keyboard keys, insets). Was `.background.tertiary`.
    static var sbSurface2: AnyShapeStyle {
        let t = SurfaceTheme.current
        return t == .system ? AnyShapeStyle(.background.tertiary) : AnyShapeStyle(t.surface2)
    }

    /// Hairline separating a card from its base — `.clear` (no-op) in the system preset.
    static var sbSurfaceStroke: AnyShapeStyle { AnyShapeStyle(SurfaceTheme.current.stroke) }
}

extension NSColor {
    /// 6-digit `RRGGBB` (optionally `#`-prefixed) → sRGB color.
    convenience init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255,
                  alpha: 1)
    }
}
