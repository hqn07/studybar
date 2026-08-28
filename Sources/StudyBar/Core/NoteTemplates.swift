import AppKit

/// Ready-made note structures for common study tasks. Built as attributed text (real
/// headings/bullets) so a new note opens already formatted — no markdown to type.
enum NoteTemplates {
    struct Template: Identifiable {
        let id = UUID()
        let name: String
        let symbol: String
        let title: String
        let build: () -> NSAttributedString
    }

    static let all: [Template] = [
        .init(name: "Lecture notes", symbol: "person.wave.2", title: "Lecture — ") {
            let b = Builder()
            b.h2("Key ideas"); b.bullet(); b.bullet()
            b.blank(); b.h2("Details"); b.body();
            b.blank(); b.h2("Questions to follow up"); b.bullet()
            b.blank(); b.h2("Summary"); b.body()
            return b.result
        },
        .init(name: "Cornell notes", symbol: "rectangle.split.2x1", title: "") {
            let b = Builder()
            b.h2("Cues / Questions"); b.bullet()
            b.blank(); b.h2("Notes"); b.body(); b.body()
            b.blank(); b.h2("Summary"); b.body()
            return b.result
        },
        .init(name: "Reading summary", symbol: "book", title: "") {
            let b = Builder()
            b.h2("Source"); b.body()
            b.blank(); b.h2("Main argument"); b.body()
            b.blank(); b.h2("Key points"); b.bullet(); b.bullet()
            b.blank(); b.h2("Quotes"); b.quote()
            b.blank(); b.h2("My takeaways"); b.bullet()
            return b.result
        },
    ]

    /// Small attributed-string builder using the editor's live typography.
    final class Builder {
        let result = NSMutableAttributedString()
        private func line(_ text: String, font: NSFont, indent: CGFloat = 0) {
            let ps = NSMutableParagraphStyle()
            ps.lineSpacing = NotesTypography.lineSpacing; ps.paragraphSpacing = 4
            if indent > 0 { ps.headIndent = indent; ps.firstLineHeadIndent = indent }
            result.append(NSAttributedString(string: text + "\n",
                attributes: [.font: font, .paragraphStyle: ps, .foregroundColor: NSColor.labelColor]))
        }
        func h2(_ t: String) { line(t, font: NotesTypography.font(.h2)) }
        func body(_ t: String = "") { line(t, font: NotesTypography.font(.body)) }
        func bullet(_ t: String = "") { line("• " + t, font: NotesTypography.font(.body)) }
        func quote(_ t: String = "") { line("" + t, font: NotesTypography.font(.body), indent: 18) }
        func blank() { line("", font: NotesTypography.font(.body)) }
    }
}
