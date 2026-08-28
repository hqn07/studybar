import AppKit

/// The Notes editor's typography, driven by user settings (Settings ▸ Appearance ▸ Notes).
/// One source for the body font, heading scale and line spacing so the whole editor moves
/// together when the reader picks a size / face / density.
enum NotesTypography {
    enum Family: String, CaseIterable { case system, serif, mono
        var label: String { switch self { case .system: "System"; case .serif: "Serif"; case .mono: "Mono" } }
    }
    enum Role { case body, h1, h2, h3 }

    static var family: Family { Family(rawValue: UserDefaults.standard.string(forKey: "notesFont") ?? "") ?? .system }
    /// Body point size (13 / 15 / 17 = Small / Medium / Large). Default 15.
    static var size: CGFloat { CGFloat((UserDefaults.standard.object(forKey: "notesFontSize") as? Double) ?? 15) }
    /// Extra line spacing in points (2 / 3.5 / 6 = Tight / Normal / Relaxed). Default 3.5.
    static var lineSpacing: CGFloat { CGFloat((UserDefaults.standard.object(forKey: "notesLineSpacing") as? Double) ?? 3.5) }

    static func font(_ role: Role) -> NSFont {
        switch role {
        case .body: return styled(size, .regular)
        case .h1:   return styled(size + 10, .bold)
        case .h2:   return styled(size + 5,  .bold)
        case .h3:   return styled(size + 2,  .semibold)
        }
    }

    static func styled(_ s: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        switch family {
        case .mono: return .monospacedSystemFont(ofSize: s, weight: weight)
        case .serif:
            let base = NSFont.systemFont(ofSize: s, weight: weight)
            if let d = base.fontDescriptor.withDesign(.serif) { return NSFont(descriptor: d, size: s) ?? base }
            return base
        case .system: return .systemFont(ofSize: s, weight: weight)
        }
    }

    static var paragraph: NSParagraphStyle {
        let p = NSMutableParagraphStyle(); p.lineSpacing = lineSpacing; p.paragraphSpacing = 4
        return p
    }
}
