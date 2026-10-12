import SwiftUI

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >> 8) & 0xFF) / 255
        let b = Double(v & 0xFF) / 255
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let r = Int(round(ns.redComponent * 255))
        let g = Int(round(ns.greenComponent * 255))
        let b = Int(round(ns.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

/// Palette used by the course color picker.
enum Palette {
    static let swatches = [
        "#4F8DFD", "#34C759", "#FF9500", "#FF375F", "#AF52DE",
        "#5AC8FA", "#FFCC00", "#FF6482", "#30D158", "#64D2FF",
        "#BF5AF2", "#FF9F0A", "#8E8E93", "#0A84FF"
    ]

    /// Curated accent presets for the app tint (Settings ▸ Appearance). Distinct from
    /// `swatches` (per-course colors), and kept clear of the semantic red / amber used
    /// for state so the accent never reads as an urgency signal.
    static let accents = [
        "#007AFF", "#4F8DFD", "#0EA5E9", "#06B6D4", "#0EA5A4", "#10B981",
        "#6366F1", "#8B5CF6", "#A855F7", "#EC4899", "#F43F5E", "#64748B", "#52525B"
    ]
}

/// A course's color as drawn: tuned for the mode it's in. The stored hex never changes, and the
/// color pickers draw the tuned color too, so what you pick is what you see.
enum CourseColor {
    /// The course color for both modes, resolved at draw time. Made once per hex: every row reads
    /// it on every redraw, and one color object per hex also lets SwiftUI see it hasn't changed.
    static func color(hex: String) -> Color? {
        if let hit = cache.object(forKey: hex as NSString) { return Color(nsColor: hit) }
        guard let base = NSColor(hexString: hex) else { return nil }
        let light = tuned(base, dark: false), dark = tuned(base, dark: true)
        let both = NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
        cache.setObject(both, forKey: hex as NSString)
        return Color(nsColor: both)
    }
    private static let cache = NSCache<NSString, NSColor>()

    /// Light mode: deepened, hue and saturation kept, until it reads on white (3:1, the bar for
    /// dots, bars and edges) — pale yellows and limes otherwise vanish. Dark mode: a touch less
    /// saturated, so bright swatches don't glow on a dark ground.
    static func tuned(_ c: NSColor, dark: Bool) -> NSColor {
        guard let s = c.usingColorSpace(.sRGB) else { return c }
        var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        s.getHue(&h, saturation: &sat, brightness: &b, alpha: &a)
        if dark { return NSColor(colorSpace: .sRGB, hue: h, saturation: sat * 0.85, brightness: b, alpha: a) }
        var out = s
        while contrast(out, .white) < 3, b > 0.2 {
            b -= 0.02
            out = NSColor(colorSpace: .sRGB, hue: h, saturation: sat, brightness: b, alpha: a)
        }
        return out
    }

    /// WCAG contrast ratio between two colors (1…21).
    static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
    static func luminance(_ c: NSColor) -> Double {
        let s = c.usingColorSpace(.sRGB) ?? c
        func lin(_ v: CGFloat) -> Double { let v = Double(v); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(s.redComponent) + 0.7152 * lin(s.greenComponent) + 0.0722 * lin(s.blueComponent)
    }
}
