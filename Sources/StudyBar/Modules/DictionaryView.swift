import SwiftUI
import CoreServices

/// (29) Offline definitions via macOS Dictionary Services (DCSCopyTextDefinition).
enum DictionaryService {
    static func define(_ term: String) -> String? {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let range = CFRange(location: 0, length: (t as NSString).length)
        guard let result = DCSCopyTextDefinition(nil, t as CFString, range) else { return nil }
        return result.takeRetainedValue() as String
    }
}

/// Best-effort reformatting of the run-together DCS string into readable Markdown:
/// part-of-speech and section headers on their own bold lines, sub-senses broken
/// out, and (conservatively) numbered senses. Heuristic — DCS returns unstructured
/// text with no schema, so the Dictionary view offers a raw/formatted toggle.
enum DictionaryFormat {
    private static let pos = "noun|verb|adjective|adverb|pronoun|preposition|conjunction|interjection|exclamation|abbreviation|determiner|article|prefix|suffix|symbol|contraction|combining form|plural noun|mass noun|auxiliary verb|modal verb"
    private static let sect = "DERIVATIVES|ORIGIN|PHRASES|PHRASAL VERBS|USAGE|THESAURUS|SYNONYMS|ANTONYMS"
    /// Words that commonly follow a bare number but are NOT sense numbers.
    private static let units: Set<String> = ["percent", "miles", "mile", "pages", "page", "cars", "marathons",
        "meters", "metres", "feet", "yards", "years", "year", "days", "hours", "minutes", "seconds", "km", "kg"]

    static func markdown(_ raw: String) -> String {
        var s = " " + raw + " "
        func rx(_ p: String, _ r: String) {
            guard let re = try? NSRegularExpression(pattern: p) else { return }
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: r)
        }
        // ALL-CAPS section headers → bold on their own line.
        rx("\\s*\\b(\(sect))\\b\\s*", "\n\n**$1** ")
        // Part-of-speech right after a pronunciation close "| " → placeholder header.
        rx("\\|\\s+(\(pos))\\b", "|\n\n@@$1@@\n")
        // Part-of-speech immediately before a sense number → placeholder header.
        rx("\\s(\(pos))\\s+(?=[1-9])", "\n\n@@$1@@\n")
        // Sub-senses onto their own indented line.
        rx("\\s•\\s", "\n   • ")
        s = capitalizeMarkers(s)
        s = breakSenses(s)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// @@noun@@ → **Noun**
    private static func capitalizeMarkers(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "@@(.+?)@@") else { return s }
        var out = s
        let matches = re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed()
        for m in matches {
            guard let full = Range(m.range, in: out), let g = Range(m.range(at: 1), in: out) else { continue }
            out.replaceSubrange(full, with: "**" + out[g].capitalized + "**")
        }
        return out
    }

    /// Newline before a numbered sense (1–19), guarding against ordinals ("16th")
    /// and units ("42 marathons") that are not sense markers.
    private static func breakSenses(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "(^|[ \n])([1-9]|1[0-9]) ([A-Za-z\\[(])") else { return s }
        let ns = s as NSString
        var result = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let numRange = m.range(at: 2), tailRange = m.range(at: 3)
            let tailChar = ns.substring(with: tailRange)
            // Peek the following word for ordinal suffix / unit.
            let afterIdx = tailRange.location
            let rest = ns.substring(from: afterIdx)
            let word = rest.prefix { $0.isLetter }.lowercased()
            let isOrdinal = ["th", "st", "nd", "rd"].contains { word.hasPrefix($0) && word.count <= 3 }
            let isUnit = units.contains(word)
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            if isOrdinal || isUnit {
                result += ns.substring(with: m.range)               // leave as-is
            } else {
                result += "\n" + ns.substring(with: numRange) + ". " + tailChar
            }
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}

struct DictionaryView: View {
    @State private var term = ""
    @State private var definition: String?
    @State private var searched = false
    @AppStorage("dictRecents") private var recentsRaw = ""
    @AppStorage("dictFormatted") private var formatted = true

    private var recents: [String] { recentsRaw.split(separator: "\n").map(String.init) }

    var body: some View {
        ModulePane(title: "Dictionary") {
            HStack(spacing: 8) {
                Button { formatted.toggle() } label: {
                    Image(systemName: formatted ? "text.alignleft" : "text.justify")
                }.help(formatted ? "Show raw definition" : "Show formatted definition")
                Button { defineClipboard() } label: { Image(systemName: "doc.on.clipboard") }
                    .help("Define word on clipboard")
            }
        } content: {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "character.book.closed").foregroundStyle(.secondary)
                    TextField("Look up a word…", text: $term, onCommit: lookup)
                        .textFieldStyle(.plain)
                    Button("Define", action: lookup).disabled(term.isEmpty)
                }.padding(10)
                if !recents.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(recents, id: \.self) { w in
                                Button { term = w; lookup() } label: {
                                    Text(w).font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(.sbSurface, in: Capsule())
                                }.buttonStyle(.plain)
                            }
                            Button { recentsRaw = "" } label: { Image(systemName: "xmark.circle").font(.caption2) }
                                .buttonStyle(.borderless).foregroundStyle(.secondary)
                        }.padding(.horizontal, 10).padding(.bottom, 6)
                    }
                }
                Divider()
                ScrollView {
                    if let def = definition, !def.isEmpty {
                        Group {
                            if formatted { MarkdownText(text: DictionaryFormat.markdown(def)) }
                            else { Text(def).font(.body) }
                        }
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    } else if searched {
                        VStack(spacing: 8) {
                            EmptyState(symbol: "questionmark.circle", title: "No definition",
                                       subtitle: "“\(term)” isn’t in the active dictionaries. Enable more in Dictionary.app.")
                            Button("Open Dictionary.app") { openInDictionary() }
                        }
                    } else {
                        EmptyState(symbol: "character.book.closed", title: "Dictionary & Thesaurus",
                                   subtitle: "Uses macOS’s built-in dictionaries. Works offline.")
                    }
                }
                if let def = definition, !def.isEmpty {
                    Divider()
                    HStack {
                        Button { copy(def) } label: { Label("Copy", systemImage: "doc.on.doc") }
                            .buttonStyle(.borderless).font(.caption)
                        Spacer()
                        Button { openInDictionary() } label: {
                            Label("Open in Dictionary.app", systemImage: "arrow.up.right.square")
                        }.buttonStyle(.borderless).font(.caption)
                    }.padding(.horizontal, 12).padding(.vertical, 6)
                }
            }
        }
    }

    private func lookup() {
        let t = term.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        definition = DictionaryService.define(t)
        searched = true
        if definition != nil { addRecent(t) }
    }

    private func defineClipboard() {
        guard let s = NSPasteboard.general.string(forType: .string) else { return }
        let firstWord = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline }).first.map(String.init) ?? ""
        guard !firstWord.isEmpty else { return }
        term = firstWord
        lookup()
    }

    private func addRecent(_ t: String) {
        var list = recents.filter { $0.caseInsensitiveCompare(t) != .orderedSame }
        list.insert(t, at: 0)
        recentsRaw = list.prefix(15).joined(separator: "\n")
    }
    private func copy(_ s: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
    }

    private func openInDictionary() {
        let t = term.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? term
        if let url = URL(string: "dict://\(t)") { NSWorkspace.shared.open(url) }
    }
}
