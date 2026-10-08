import SwiftUI

/// Lightweight Markdown preview: headings, bullets, checkboxes, quotes + inline emphasis.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, raw in
                line(String(raw))
            }
        }
    }

    /// Indentation is read before the line is trimmed — trimming first is what made every
    /// sub-bullet a sibling of the point it belongs under. `NoteFormat` owns the depth rule so
    /// this, the reading view and print all agree on what "nested" means.
    @ViewBuilder private func line(_ s: String) -> some View {
        let t = s.trimmingCharacters(in: .whitespaces)
        let depth = NoteFormat.indentLevel(s)
        let inset = CGFloat(depth) * 14
        if t.hasPrefix("# ") {
            inline(String(t.dropFirst(2))).font(.title2.bold())
        } else if t.hasPrefix("## ") {
            inline(String(t.dropFirst(3))).font(.title3.bold()).padding(.top, 10)
        } else if t.hasPrefix("### ") {
            inline(String(t.dropFirst(4))).font(.headline)
        } else if t.hasPrefix("- [ ] ") || t.hasPrefix("- [] ") {
            HStack(alignment: .top, spacing: 6) { Image(systemName: "square"); inline(String(t.drop(while: { $0 != "]" }).dropFirst(2))) }
                .padding(.leading, inset)
        } else if t.lowercased().hasPrefix("- [x] ") {
            HStack(alignment: .top, spacing: 6) { Image(systemName: "checkmark.square.fill").foregroundStyle(.green); inline(String(t.dropFirst(6))).strikethrough().foregroundStyle(.secondary) }
                .padding(.leading, inset)
        } else if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("• ") {
            HStack(alignment: .top, spacing: 6) { Text(NoteFormat.bulletGlyph(depth)); inline(String(t.dropFirst(2))) }
                .padding(.leading, inset)
        } else if t.hasPrefix("> "), let kind = Callout(quote: String(t.dropFirst(2))) {
            CalloutBox(kind: kind) { inline(String(t.dropFirst(2))) }
        } else if t.hasPrefix("> ") {
            inline(String(t.dropFirst(2))).italic().foregroundStyle(.secondary)
                .padding(.leading, 8).overlay(Rectangle().frame(width: 2).foregroundStyle(.tint), alignment: .leading)
        } else if t.isEmpty {
            Spacer().frame(height: 4)
        } else {
            inline(s)
        }
    }

    private func inline(_ s: String) -> Text {
        if let attr = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attr)
        }
        return Text(s)
    }
}

/// The boxes study notes point things out with — `> **In short:** …`, `> **Key idea:** …`,
/// `> **Watch out:** …` and `> 💡 **Added:** …` — drawn as tinted boxes, so they stand out from
/// the paragraphs around them (signaling) instead of fading into a grey quote. Any other quote
/// stays a quote.
enum Callout: String {
    case short, key, watch, added

    init?(quote: String) {
        let t = quote.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("💡") { self = .added }
        else if t.hasPrefix("**In short") { self = .short }
        else if t.hasPrefix("**Key idea") { self = .key }
        else if t.hasPrefix("**Watch out") { self = .watch }
        else { return nil }
    }

    var color: Color {
        switch self {
        case .short: return .gray
        case .key: return .blue
        case .watch: return .orange
        case .added: return .yellow
        }
    }
}

struct CalloutBox<Content: View>: View {
    let kind: Callout
    @ViewBuilder let content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 7).padding(.leading, 12).padding(.trailing, 10)
            .background(kind.color.opacity(0.13), in: RoundedRectangle(cornerRadius: 7))
            .overlay(alignment: .leading) { UnevenRoundedRectangle(topLeadingRadius: 7, bottomLeadingRadius: 7).fill(kind.color).frame(width: 3) }
            .padding(.vertical, 2)
    }
}

/// Expands snippet placeholders when copying: {date} {time} {datetime} {clipboard} {course} {week}.
/// {course} is the class in session (or starting within half an hour) and {week} the term
/// week; both are empty when there's nothing to say.
enum SnippetExpand {
    @MainActor
    static func run(_ body: String) -> String {
        let now = Date()
        let state = AppState.current
        let course = state?.course(state?.currentCourseID).map { $0.code.isEmpty ? $0.name : $0.code } ?? ""
        let week = SemesterWeek.number(for: now, termStart: state?.data.termStart).map(String.init) ?? ""
        let df = DateFormatter(); df.dateStyle = .medium
        let tf = DateFormatter(); tf.timeStyle = .short
        let dtf = DateFormatter(); dtf.dateStyle = .medium; dtf.timeStyle = .short
        let clip = NSPasteboard.general.string(forType: .string) ?? ""
        return body
            .replacingOccurrences(of: "{date}", with: df.string(from: now))
            .replacingOccurrences(of: "{time}", with: tf.string(from: now))
            .replacingOccurrences(of: "{datetime}", with: dtf.string(from: now))
            .replacingOccurrences(of: "{clipboard}", with: clip)
            .replacingOccurrences(of: "{course}", with: course)
            .replacingOccurrences(of: "{week}", with: week)
    }
    static var hasPlaceholders: (String) -> Bool {
        { s in ["{date}", "{time}", "{datetime}", "{clipboard}", "{course}", "{week}"].contains { s.contains($0) } }
    }
}
