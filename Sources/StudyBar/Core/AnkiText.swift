import Foundation

/// Import/export flashcards in Anki's plain-text ("Notes in Plain Text") format —
/// a superset of simple CSV/TSV. Pure + testable: no UI, no dependencies.
///
/// Handles leading `#directive:value` headers (separator / html / tags column /
/// deck column), quoted CSV fields with embedded separators+newlines, Anki cloze
/// `{{c1::text::hint}}` ⇄ StudyBar `{{text}}`, and HTML field stripping.
enum AnkiText {
    struct Card: Equatable { var front: String; var back: String; var tags: [String] }

    // MARK: - Import

    static func parse(_ raw: String) -> [Card] {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")

        var sep: Character = "\t"       // Anki default
        var html = false
        var tagsCol: Int?               // 1-based, per Anki directives
        var deckCol: Int?
        var sawSeparatorDirective = false

        // Peel off leading #directive lines.
        var body = ""
        var inHeader = true
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = String(line)
            if inHeader && l.hasPrefix("#") {
                let kv = l.dropFirst().split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard kv.count == 2 else { continue }
                switch kv[0].lowercased() {
                case "separator":    sep = separatorChar(kv[1]); sawSeparatorDirective = true
                case "html":         html = kv[1].lowercased() == "true"
                case "tags column":  tagsCol = Int(kv[1])
                case "deck column":  deckCol = Int(kv[1])
                default: break
                }
                continue
            }
            inHeader = false
            body += l + "\n"
        }

        // No #separator? Sniff: tab, else semicolon-only, else comma.
        if !sawSeparatorDirective {
            if body.contains("\t") { sep = "\t" }
            else if body.contains(";") && !body.contains(",") { sep = ";" }
            else { sep = "," }
        }

        let tagIdx = tagsCol.map { $0 - 1 }
        let deckIdx = deckCol.map { $0 - 1 }

        var cards: [Card] = []
        for fields in records(body, sep: sep) {
            // Content = fields minus the tags/deck columns, in order.
            let contentIdx = fields.indices.filter { $0 != tagIdx && $0 != deckIdx }
            guard let fi = contentIdx.first else { continue }

            let front = clean(fields[fi], html: html)
            guard !front.isEmpty else { continue }
            let back = contentIdx.count > 1 ? clean(fields[contentIdx[1]], html: html) : ""

            var tags: [String] = []
            if let ti = tagIdx, ti < fields.count {
                tags = splitTags(fields[ti])
            } else if tagIdx == nil && contentIdx.count > 2 {
                // Legacy CSV with no header: 3rd field = tags.
                tags = splitTags(fields[contentIdx[2]])
            }
            cards.append(Card(front: fromAnkiCloze(front), back: back, tags: tags))
        }
        return cards
    }

    // MARK: - Export (Anki-round-trippable)

    static func export(_ cards: [Card]) -> String {
        var out = "#separator:tab\n#html:false\n#tags column:3\n"
        for c in cards {
            out += esc(toAnkiCloze(c.front)) + "\t" + esc(c.back) + "\t" + esc(c.tags.joined(separator: " ")) + "\n"
        }
        return out
    }

    // MARK: - Cloze conversion

    /// Anki `{{c1::answer::hint}}` / `{{c1::answer}}` → StudyBar `{{answer}}` (drops cN + hint).
    static func fromAnkiCloze(_ s: String) -> String {
        s.replacingOccurrences(of: #"\{\{c\d+::(.*?)(?:::[^}]*)?\}\}"#, with: "{{$1}}", options: .regularExpression)
    }

    /// StudyBar `{{answer}}` → Anki `{{c1::answer}}`, numbered sequentially.
    static func toAnkiCloze(_ s: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\{\{(.*?)\}\}"#) else { return s }
        let ns = s as NSString
        var result = ""; var last = 0; var n = 0
        for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            n += 1
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            result += "{{c\(n)::\(ns.substring(with: m.range(at: 1)))}}"
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    // MARK: - Internals

    private static func separatorChar(_ s: String) -> Character {
        switch s.lowercased() {
        case "tab", "\\t": return "\t"
        case "comma", ",": return ","
        case "semicolon", ";": return ";"
        case "space": return " "
        case "pipe", "|": return "|"
        default: return s.first ?? "\t"
        }
    }

    private static func splitTags(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == ";" }).map(String.init).filter { !$0.isEmpty }
    }

    /// Strip HTML/entities when a field looks like markup (or html:true was declared).
    private static func clean(_ s: String, html: Bool) -> String {
        var t = s
        if html || t.contains("<") || t.contains("&") { t = stripHTML(t) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripHTML(_ s: String) -> String {
        var t = s
        for br in ["<br>", "<br/>", "<br />", "</div>", "</p>", "</li>"] {
            t = t.replacingOccurrences(of: br, with: "\n", options: .caseInsensitive)
        }
        t = t.replacingOccurrences(of: #"\[sound:[^\]]*\]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (k, v) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'"] {
            t = t.replacingOccurrences(of: k, with: v)
        }
        return t.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
    }

    /// RFC4180-ish record splitter: honors `"`-quoted fields (opened only at field
    /// start), `""` escapes, and separators/newlines inside quotes.
    private static func records(_ text: String, sep: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 2; continue }
                    inQuotes = false; i += 1; continue
                }
                field.append(c); i += 1
            } else {
                if c == "\"" && field.isEmpty { inQuotes = true; i += 1; continue }
                if c == sep { row.append(field); field = ""; i += 1; continue }
                if c == "\n" { row.append(field); rows.append(row); row = []; field = ""; i += 1; continue }
                field.append(c); i += 1
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        // Drop blank rows.
        return rows.filter { !($0.count == 1 && $0[0].trimmingCharacters(in: .whitespaces).isEmpty) }
    }

    private static func esc(_ s: String) -> String {
        (s.contains("\t") || s.contains("\n") || s.contains("\""))
            ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            : s
    }
}
