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

    @ViewBuilder private func line(_ s: String) -> some View {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("# ") {
            inline(String(t.dropFirst(2))).font(.title2.bold())
        } else if t.hasPrefix("## ") {
            inline(String(t.dropFirst(3))).font(.title3.bold())
        } else if t.hasPrefix("### ") {
            inline(String(t.dropFirst(4))).font(.headline)
        } else if t.hasPrefix("- [ ] ") || t.hasPrefix("- [] ") {
            HStack(alignment: .top, spacing: 6) { Image(systemName: "square"); inline(String(t.drop(while: { $0 != "]" }).dropFirst(2))) }
        } else if t.lowercased().hasPrefix("- [x] ") {
            HStack(alignment: .top, spacing: 6) { Image(systemName: "checkmark.square.fill").foregroundStyle(.green); inline(String(t.dropFirst(6))).strikethrough().foregroundStyle(.secondary) }
        } else if t.hasPrefix("- ") || t.hasPrefix("* ") {
            HStack(alignment: .top, spacing: 6) { Text("•"); inline(String(t.dropFirst(2))) }
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

/// Expands snippet placeholders when copying: {date} {time} {datetime} {clipboard}.
enum SnippetExpand {
    static func run(_ body: String) -> String {
        let now = Date()
        let df = DateFormatter(); df.dateStyle = .medium
        let tf = DateFormatter(); tf.timeStyle = .short
        let dtf = DateFormatter(); dtf.dateStyle = .medium; dtf.timeStyle = .short
        let clip = NSPasteboard.general.string(forType: .string) ?? ""
        return body
            .replacingOccurrences(of: "{date}", with: df.string(from: now))
            .replacingOccurrences(of: "{time}", with: tf.string(from: now))
            .replacingOccurrences(of: "{datetime}", with: dtf.string(from: now))
            .replacingOccurrences(of: "{clipboard}", with: clip)
    }
    static var hasPlaceholders: (String) -> Bool { { $0.contains("{date}") || $0.contains("{time}") || $0.contains("{datetime}") || $0.contains("{clipboard}") } }
}
