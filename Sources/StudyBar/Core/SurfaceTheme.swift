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

    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: "System"
        case .nearBlack: "Near-black"
        }
    }

    static let storageKey = "surfaceTheme"

    /// The persisted choice. Cheap — read at render time by the surface tokens.
    static var current: SurfaceTheme {
        SurfaceTheme(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system
    }

    // Near-black tiers. base is darkest; surface and surface2 step up in real value
    // jumps so a card reads on the base even before its hairline border. Light stays
    // native (the preset is dark-oriented; a light user who picks it keeps the system
    // look, only nudged toward the app's own neutrals).
    static var base: Color { dyn(light: .windowBackgroundColor, dark: "0C0C0F") }
    static var surface: Color { dyn(light: .controlBackgroundColor, dark: "17171B") }
    static var surface2: Color { dyn(light: .underPageBackgroundColor, dark: "212127") }

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
    /// Card / row / control-chrome fill. Was `.background.secondary`.
    static var sbSurface: AnyShapeStyle {
        switch SurfaceTheme.current {
        case .system: AnyShapeStyle(.background.secondary)
        case .nearBlack: AnyShapeStyle(SurfaceTheme.surface)
        }
    }

    /// The tier above `sbSurface` (keyboard keys, insets). Was `.background.tertiary`.
    static var sbSurface2: AnyShapeStyle {
        switch SurfaceTheme.current {
        case .system: AnyShapeStyle(.background.tertiary)
        case .nearBlack: AnyShapeStyle(SurfaceTheme.surface2)
        }
    }

    /// Hairline that separates a near-black card from the near-black base. Invisible
    /// (`.clear`) in the system preset, so it is a no-op for the default user.
    static var sbSurfaceStroke: AnyShapeStyle {
        switch SurfaceTheme.current {
        case .system: AnyShapeStyle(.clear)
        case .nearBlack: AnyShapeStyle(Color.white.opacity(0.055))
        }
    }
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
