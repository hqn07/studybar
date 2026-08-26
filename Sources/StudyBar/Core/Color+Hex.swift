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

    // MARK: Dark surface palette
    // Light mode keeps the native system look; dark mode uses a chosen near-black scheme
    // (text & muted already match the system labels, so only the surfaces change). Applied
    // via the `Color.sbSurface` sweep and the RootView base background.
    static let sbBase     = sbDyn(light: .windowBackgroundColor,    darkHex: "#0B0B0E")
    static let sbSurface  = sbDyn(light: .controlBackgroundColor,   darkHex: "#0E0E0E")
    static let sbSurface2 = sbDyn(light: .underPageBackgroundColor, darkHex: "#17171C")

    private static func sbDyn(light: NSColor, darkHex: String) -> Color {
        let dark = NSColor(hex: darkHex) ?? .black
        return Color(nsColor: NSColor(name: nil) { ap in
            ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
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
        "#4F8DFD", "#61AFEF", "#0EA5E9", "#06B6D4", "#0EA5A4", "#10B981",
        "#6366F1", "#8B5CF6", "#A855F7", "#EC4899", "#F43F5E", "#64748B", "#52525B"
    ]
}
