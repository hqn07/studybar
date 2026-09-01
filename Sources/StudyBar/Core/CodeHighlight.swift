import AppKit

/// Lightweight, language-agnostic code tokenizer for the Notes editor's code blocks.
/// Native, no dependency — colors strings, comments, numbers, and a curated union of
/// keywords across the languages students actually write (Python, Java, C-family, JS,
/// Swift, SQL). Applied as *temporary* (display-only) attributes, so it never touches the
/// note's stored content. "Good enough" highlighting, not a full parser.
enum CodeHighlight {
    enum Kind { case string, comment, number, keyword }

    /// Keyword union — deliberately broad, so one set lights up most languages.
    private static let keywords: Set<String> = [
        "let", "var", "val", "const", "func", "fun", "def", "function", "class", "struct",
        "enum", "interface", "protocol", "extension", "import", "from", "package", "namespace",
        "public", "private", "protected", "internal", "static", "final", "abstract", "override",
        "void", "return", "yield", "async", "await", "throws", "throw", "try", "catch", "except",
        "finally", "defer", "guard", "if", "else", "elif", "for", "while", "do", "switch", "case",
        "default", "break", "continue", "in", "is", "as", "new", "delete", "this", "self", "super",
        "true", "false", "none", "null", "nil", "undefined", "and", "or", "not", "with", "lambda",
        "int", "float", "double", "char", "bool", "boolean", "string", "long", "short", "byte",
        "print", "println", "echo", "select", "insert", "update", "delete", "where", "join",
        "group", "order", "by", "extends", "implements", "typedef", "using", "template", "const",
    ]

    /// (range, kind) spans for a snippet of code, in priority order (strings/comments claim
    /// first so keywords inside them aren't recolored).
    static func spans(_ code: String) -> [(NSRange, Kind)] {
        let ns = code as NSString
        var out: [(NSRange, Kind)] = []
        var claimed = IndexSet()

        func pass(_ pattern: String, _ kind: Kind, _ opts: NSRegularExpression.Options = []) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return }
            for m in re.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
                let r = m.range
                let end = r.location + r.length
                if (r.location..<end).contains(where: { claimed.contains($0) }) { continue }
                claimed.insert(integersIn: r.location..<end)
                out.append((r, kind))
            }
        }

        pass(#""(\\.|[^"\\\n])*""#, .string)      // "double"
        pass(#"'(\\.|[^'\\\n])*'"#, .string)       // 'single'
        pass("`[^`\n]*`", .string)                  // `template`
        pass(#"/\*[\s\S]*?\*/"#, .comment)          // /* block */
        pass(#"(//|#|--).*"#, .comment)             // line comments
        pass(#"\b\d+(\.\d+)?\b"#, .number)
        pass("\\b[A-Za-z_][A-Za-z0-9_]*\\b", .keyword, [])   // words → filtered to keywords below

        // Keep only real keywords from the word pass.
        out = out.filter { span in
            span.1 != .keyword || keywords.contains(ns.substring(with: span.0).lowercased())
        }
        return out
    }

    static func color(_ kind: Kind) -> NSColor {
        switch kind {
        case .string:  return dyn(light: "1A7F37", dark: "9ECE6A")
        case .comment: return dyn(light: "6A737D", dark: "7C818C")
        case .number:  return dyn(light: "B5690C", dark: "E5945B")
        case .keyword: return dyn(light: "8250DF", dark: "BB9AF7")
        }
    }

    private static func dyn(light: String, dark: String) -> NSColor {
        NSColor(name: nil) { ap in
            (ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(hexString: dark) : NSColor(hexString: light)) ?? .textColor
        }
    }
}
