import Foundation

enum CiteStyle: String, CaseIterable, Identifiable {
    case apa = "APA", mla = "MLA", chicago = "Chicago"
    case ieee = "IEEE", harvard = "Harvard", vancouver = "Vancouver"
    case bibtex = "BibTeX"
    var id: String { rawValue }
}

enum CitationFormatter {

    /// In-text citation, e.g. "(Smith, 2020)", "(Smith & Jones, 2020)", "(Smith et al., 2020)".
    static func inText(_ r: Reference) -> String {
        let last = r.authors.map { $0.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? $0 }.filter { !$0.isEmpty }
        let who = last.isEmpty ? "Author" : last.count == 1 ? last[0] : last.count == 2 ? "\(last[0]) & \(last[1])" : "\(last[0]) et al."
        return "(\(who), \(r.year.isEmpty ? "n.d." : r.year))"
    }

    static func format(_ r: Reference, style: CiteStyle) -> String {
        switch style {
        case .apa:       return apa(r)
        case .mla:       return mla(r)
        case .chicago:   return chicago(r)
        case .ieee:      return ieee(r)
        case .harvard:   return harvard(r)
        case .vancouver: return vancouver(r)
        case .bibtex:    return bibtex(r)
        }
    }

    // MARK: - Author helpers for the added styles

    /// "Last, First M" → "F. M. Last" (IEEE).
    private static func initialsFirst(_ name: String) -> String {
        let p = name.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard p.count == 2 else { return name }
        let inits = p[1].split(separator: " ").compactMap { $0.first }.map { "\($0)." }.joined(separator: " ")
        return "\(inits) \(p[0])"
    }
    /// "Last, First M" → "Last, F." (Harvard).
    private static func lastInitials(_ name: String) -> String {
        let p = name.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard p.count == 2 else { return name }
        let inits = p[1].split(separator: " ").compactMap { $0.first }.map { "\($0)." }.joined(separator: " ")
        return "\(p[0]), \(inits)"
    }
    /// "Last, First M" → "Last FM" (Vancouver — no periods).
    private static func lastInitialsCompact(_ name: String) -> String {
        let p = name.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard p.count == 2 else { return name }
        let inits = p[1].split(separator: " ").compactMap { $0.first }.map(String.init).joined()
        return "\(p[0]) \(inits)"
    }
    private static func joinAnd(_ names: [String]) -> String {
        if names.count <= 1 { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    // MARK: - IEEE

    private static func ieee(_ r: Reference) -> String {
        var s = joinAnd(r.authors.map(initialsFirst)); if !s.isEmpty { s += ", " }
        switch r.type {
        case .article:
            s += "\"\(r.title),\" *\(r.container)*"
            if !r.volume.isEmpty { s += ", vol. \(r.volume)" }
            if !r.issue.isEmpty { s += ", no. \(r.issue)" }
            if !r.pages.isEmpty { s += ", pp. \(r.pages)" }
            if !r.year.isEmpty { s += ", \(r.year)" }
            s += "."
            if !r.doi.isEmpty { s += " doi: \(r.doi)." }
        case .book:
            s += "*\(r.title)*. \(r.container), \(r.year)."
        case .website:
            s += "\"\(r.title).\" \(r.container)."
            if !r.url.isEmpty { s += " [Online]. Available: \(r.url)" }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Harvard (author–date)

    private static func harvard(_ r: Reference) -> String {
        var s = joinAnd(r.authors.map(lastInitials)); if !s.isEmpty { s += " " }
        s += "(\(r.year.isEmpty ? "n.d." : r.year)) "
        switch r.type {
        case .article:
            s += "'\(r.title)', *\(r.container)*"
            if !r.volume.isEmpty { s += ", \(r.volume)" }
            if !r.issue.isEmpty { s += "(\(r.issue))" }
            if !r.pages.isEmpty { s += ", pp. \(r.pages)" }
            s += "."
        case .book:
            s += "*\(r.title)*. \(r.container)."
        case .website:
            s += "*\(r.title)*. Available at: \(r.url) (Accessed: \(r.year))."
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Vancouver (numeric bibliographies; entry form)

    private static func vancouver(_ r: Reference) -> String {
        let names = r.authors.prefix(6).map(lastInitialsCompact)
        var s = names.joined(separator: ", ")
        if r.authors.count > 6 { s += ", et al" }
        if !s.isEmpty { s += ". " }
        switch r.type {
        case .article:
            s += "\(r.title). \(r.container). \(r.year)"
            if !r.volume.isEmpty { s += ";\(r.volume)" }
            if !r.issue.isEmpty { s += "(\(r.issue))" }
            if !r.pages.isEmpty { s += ":\(r.pages)" }
            s += "."
        case .book:
            s += "\(r.title). \(r.container); \(r.year)."
        case .website:
            s += "\(r.title) [Internet]. \(r.container); \(r.year). Available from: \(r.url)"
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    // "Last, First" list -> style-specific author string
    private static func authorsAPA(_ a: [String]) -> String {
        guard !a.isEmpty else { return "" }
        let names = a.map { name -> String in
            let parts = name.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 {
                let initials = parts[1].split(separator: " ").compactMap { $0.first }.map { "\($0)." }.joined(separator: " ")
                return "\(parts[0]), \(initials)"
            }
            return name
        }
        if names.count == 1 { return names[0] }
        return names.dropLast().joined(separator: ", ") + ", & " + names.last!
    }

    private static func authorsMLA(_ a: [String]) -> String {
        guard let first = a.first else { return "" }
        if a.count == 1 { return first }
        if a.count == 2 { return "\(first), and \(flip(a[1]))" }
        return "\(first), et al"
    }

    private static func flip(_ lastFirst: String) -> String {
        let p = lastFirst.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return p.count == 2 ? "\(p[1]) \(p[0])" : lastFirst
    }

    private static func apa(_ r: Reference) -> String {
        var s = authorsAPA(r.authors)
        if !s.isEmpty { s += " " }
        if !r.year.isEmpty { s += "(\(r.year)). " }
        switch r.type {
        case .article:
            s += "\(r.title). *\(r.container)*"
            if !r.volume.isEmpty { s += ", \(r.volume)" }
            if !r.issue.isEmpty { s += "(\(r.issue))" }
            if !r.pages.isEmpty { s += ", \(r.pages)" }
            s += "."
            if !r.doi.isEmpty { s += " https://doi.org/\(r.doi)" }
        case .book:
            s += "*\(r.title)*. \(r.container)."
        case .website:
            s += "\(r.title). *\(r.container)*."
            if !r.url.isEmpty { s += " \(r.url)" }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func mla(_ r: Reference) -> String {
        var s = authorsMLA(r.authors)
        if !s.isEmpty { s += ". " }
        switch r.type {
        case .article:
            s += "\"\(r.title).\" *\(r.container)*"
            if !r.volume.isEmpty { s += ", vol. \(r.volume)" }
            if !r.issue.isEmpty { s += ", no. \(r.issue)" }
            if !r.year.isEmpty { s += ", \(r.year)" }
            if !r.pages.isEmpty { s += ", pp. \(r.pages)" }
            s += "."
        case .book:
            s += "*\(r.title)*. \(r.container), \(r.year)."
        case .website:
            s += "\"\(r.title).\" *\(r.container)*, \(r.year), \(r.url)."
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func chicago(_ r: Reference) -> String {
        var s = r.authors.first ?? ""
        if !s.isEmpty { s += ". " }
        switch r.type {
        case .article:
            s += "\"\(r.title).\" *\(r.container)* \(r.volume), no. \(r.issue) (\(r.year)): \(r.pages)."
        case .book:
            s += "*\(r.title)*. \(r.container), \(r.year)."
        case .website:
            s += "\"\(r.title).\" \(r.container). Accessed \(r.year). \(r.url)."
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func bibtex(_ r: Reference) -> String {
        let key = (r.authors.first?.split(separator: ",").first.map(String.init) ?? "ref")
            .replacingOccurrences(of: " ", with: "") + r.year
        let entryType = r.type == .article ? "article" : (r.type == .book ? "book" : "misc")
        var fields: [String] = []
        fields.append("  title = {\(r.title)}")
        // A name with no comma is an organization: braced, or BibTeX reads its last word as a surname.
        if !r.authors.isEmpty { fields.append("  author = {\(r.authors.map { $0.contains(",") ? $0 : "{\($0)}" }.joined(separator: " and "))}") }
        if !r.year.isEmpty { fields.append("  year = {\(r.year)}") }
        if !r.container.isEmpty {
            fields.append("  \(r.type == .book ? "publisher" : "journal") = {\(r.container)}")
        }
        if !r.volume.isEmpty { fields.append("  volume = {\(r.volume)}") }
        if !r.issue.isEmpty { fields.append("  number = {\(r.issue)}") }
        if !r.pages.isEmpty { fields.append("  pages = {\(r.pages)}") }
        if !r.doi.isEmpty { fields.append("  doi = {\(r.doi)}") }
        if !r.url.isEmpty { fields.append("  url = {\(r.url)}") }
        return "@\(entryType){\(key),\n" + fields.joined(separator: ",\n") + "\n}"
    }
}

// MARK: - Interchange: BibTeX, RIS and CSL-JSON

/// The formats reference managers trade in — Zotero, Mendeley, EndNote, Google Scholar's "Cite"
/// — read in and written out, so a library moves both ways without retyping.
extension CitationFormatter {
    /// References in whichever of the three formats the text is; empty when it is none of them.
    static func parse(_ text: String) -> [Reference] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("[") || t.hasPrefix("{") { return parseCSL(t) }
        if t.range(of: #"(?m)^TY  - "#, options: .regularExpression) != nil { return parseRIS(t) }
        if t.range(of: #"@\w+\s*[{(]"#, options: .regularExpression) != nil { return parseBibTeX(t) }
        return []
    }

    // MARK: BibTeX

    static func parseBibTeX(_ s: String) -> [Reference] {
        let c = Array(s)
        var out: [Reference] = [], i = 0
        while let at = c[i...].firstIndex(of: "@") {
            var j = at + 1
            while j < c.count, c[j].isLetter { j += 1 }
            let type = String(c[(at + 1)..<j]).lowercased()
            while j < c.count, c[j].isWhitespace { j += 1 }
            guard j < c.count, c[j] == "{" || c[j] == "(" else { i = j; continue }
            let close: Character = c[j] == "{" ? "}" : ")"
            var depth = 0, k = j
            repeat {
                if c[k] == "{" || (close == ")" && c[k] == "(") { depth += 1 }
                if c[k] == "}" || (close == ")" && c[k] == ")") { depth -= 1 }
                k += 1
            } while k < c.count && depth > 0
            i = k
            guard !["comment", "string", "preamble"].contains(type) else { continue }
            let body = String(c[(j + 1)..<max(j + 1, k - 1)])
            var f: [String: String] = [:]
            for part in topLevel(body, splitBy: ",").dropFirst() {          // the first is the cite key
                guard let eq = part.firstIndex(of: "=") else { continue }
                f[part[..<eq].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] = part[part.index(after: eq)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            func v(_ keys: String...) -> String { keys.lazy.compactMap { f[$0].map(untex) }.first { !$0.isEmpty } ?? "" }
            var r = Reference()
            r.type = type == "article" ? .article : ["book", "inbook", "incollection", "booklet"].contains(type) ? .book
                : ["inproceedings", "conference"].contains(type) ? .article : .website
            r.title = v("title")
            r.authors = f["author"].map(bibAuthors) ?? []
            r.year = String(v("year", "date").prefix(4))
            r.container = r.type == .book ? v("publisher", "booktitle") : v("journal", "journaltitle", "booktitle", "howpublished", "publisher", "organization", "institution", "school")
            r.volume = v("volume"); r.issue = v("number", "issue"); r.pages = v("pages")
            r.doi = v("doi").replacingOccurrences(of: #"^https?://(dx\.)?doi\.org/"#, with: "", options: .regularExpression)
            r.url = v("url")
            if !r.title.isEmpty { out.append(r) }
        }
        return out
    }

    /// `Last, First and First Last and {World Health Organization}` → each "Last, First".
    private static func bibAuthors(_ raw: String) -> [String] {
        topLevel(strip(raw).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression), splitBy: " and ").map { a in
            let t = a.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("{") && t.hasSuffix("}") { return untex(t) }     // a body, not a person
            let name = untex(t)
            guard !name.contains(","), let last = name.split(separator: " ").last, name.contains(" ") else { return name }
            return "\(last), \(name.split(separator: " ").dropLast().joined(separator: " "))"
        }.filter { !$0.isEmpty }
    }

    /// Splits on `sep` outside braces and quotes.
    private static func topLevel(_ s: String, splitBy sep: String) -> [String] {
        var out: [String] = [], cur = "", depth = 0, quoted = false
        var rest = Substring(s)
        while let ch = rest.first {
            if depth == 0, !quoted, rest.hasPrefix(sep) { out.append(cur); cur = ""; rest = rest.dropFirst(sep.count); continue }
            if ch == "{" { depth += 1 } else if ch == "}" { depth -= 1 } else if ch == "\"", depth == 0 { quoted.toggle() }
            cur.append(ch); rest = rest.dropFirst()
        }
        out.append(cur)
        return out
    }

    /// A field value's outer `{…}` or `"…"`, and `#` joins.
    private static func strip(_ v: String) -> String {
        topLevel(v, splitBy: "#").map { p in
            var t = p.trimmingCharacters(in: .whitespacesAndNewlines)
            if (t.hasPrefix("{") && t.hasSuffix("}")) || (t.hasPrefix("\"") && t.hasSuffix("\"")), t.count >= 2 { t = String(t.dropFirst().dropLast()) }
            return t
        }.joined()
    }

    /// LaTeX as plain text: `{\"o}` → ö, `\&` → &, `--` → –, braces gone.
    static func untex(_ v: String) -> String {
        var t = strip(v)
        let marks: [String: String] = ["\"": "\u{308}", "'": "\u{301}", "`": "\u{300}", "^": "\u{302}", "~": "\u{303}", "=": "\u{304}",
                                       ".": "\u{307}", "c": "\u{327}", "v": "\u{30C}", "u": "\u{306}", "H": "\u{30B}", "k": "\u{328}"]
        t = t.replacing(/\\(["'`^~=.]|[cvuHk](?=[\s{]))\s*\{?\s*\\?([A-Za-z])\}?/) { m in
            String(m.output.2) + (marks[String(m.output.1)] ?? "")
        }
        for (a, b) in [("\\ss", "ß"), ("\\o", "ø"), ("\\O", "Ø"), ("\\ae", "æ"), ("\\AE", "Æ"), ("\\aa", "å"), ("\\l", "ł"),
                       ("\\&", "&"), ("\\%", "%"), ("\\$", "$"), ("\\_", "_"), ("---", "—"), ("--", "–"), ("~", " ")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces).precomposedStringWithCanonicalMapping
    }

    // MARK: RIS

    static func parseRIS(_ s: String) -> [Reference] {
        var out: [Reference] = [], f: [String: [String]] = [:]
        for line in s.components(separatedBy: .newlines) {
            guard let m = line.firstMatch(of: /^([A-Z][A-Z0-9])  -\s?(.*)$/) else { continue }
            let tag = String(m.output.1), val = String(m.output.2).trimmingCharacters(in: .whitespaces)
            guard tag == "ER" else { f[tag, default: []].append(val); continue }
            func v(_ tags: String...) -> String { tags.lazy.compactMap { f[$0]?.first }.first { !$0.isEmpty } ?? "" }
            var r = Reference()
            let ty = v("TY")
            r.type = ["JOUR", "JFULL", "MGZN", "NEWS", "CONF", "CPAPER"].contains(ty) ? .article
                : ["BOOK", "CHAP", "EBOOK", "ECHAP", "EDBOOK"].contains(ty) ? .book : .website
            r.title = v("TI", "T1", "CT")
            r.authors = (f["AU"] ?? []) + (f["A1"] ?? [])
            r.year = v("PY", "Y1", "DA").firstMatch(of: /\d{4}/).map { String($0.output) } ?? ""
            r.container = r.type == .book ? v("PB", "T2") : v("T2", "JF", "JO", "JA", "J2", "PB")
            r.volume = v("VL"); r.issue = v("IS")
            r.pages = [v("SP"), v("EP")].filter { !$0.isEmpty }.joined(separator: "–")
            r.doi = v("DO"); r.url = v("UR")
            if !r.title.isEmpty { out.append(r) }
            f = [:]
        }
        return out
    }

    static func ris(_ r: Reference) -> String {
        var l = ["TY  - " + (r.type == .article ? "JOUR" : r.type == .book ? "BOOK" : "ELEC")]
        l += r.authors.map { "AU  - " + $0 }
        l.append("TI  - " + r.title)
        if !r.year.isEmpty { l.append("PY  - " + r.year) }
        if !r.container.isEmpty { l.append((r.type == .book ? "PB  - " : "T2  - ") + r.container) }
        if !r.volume.isEmpty { l.append("VL  - " + r.volume) }
        if !r.issue.isEmpty { l.append("IS  - " + r.issue) }
        let pages = r.pages.split(whereSeparator: { "–-".contains($0) }).map(String.init)
        if let sp = pages.first { l.append("SP  - " + sp) }
        if pages.count > 1 { l.append("EP  - " + pages[1]) }
        if !r.doi.isEmpty { l.append("DO  - " + r.doi) }
        if !r.url.isEmpty { l.append("UR  - " + r.url) }
        return (l + ["ER  - "]).joined(separator: "\n")
    }

    // MARK: CSL-JSON

    static func parseCSL(_ s: String) -> [Reference] {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) else { return [] }
        let items = obj as? [[String: Any]] ?? (obj as? [String: Any]).map { [$0] } ?? []
        return items.compactMap { d in
            func str(_ k: String) -> String {
                let v = d[k]
                return ((v as? String) ?? (v as? [String])?.first ?? (v as? NSNumber)?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
            }
            var r = Reference()
            let type = str("type")
            r.type = type.hasPrefix("article") || type == "paper-conference" ? .article : ["book", "chapter"].contains(type) ? .book : .website
            r.title = str("title")
            r.authors = (d["author"] as? [[String: Any]] ?? []).compactMap { a in
                if let lit = a["literal"] as? String { return lit }
                let fam = a["family"] as? String ?? "", giv = a["given"] as? String ?? ""
                return fam.isEmpty ? nil : giv.isEmpty ? fam : "\(fam), \(giv)"
            }
            let issued = d["issued"] as? [String: Any]
            r.year = ((issued?["date-parts"] as? [[Any]])?.first?.first).map { "\($0)" }
                ?? (issued?["raw"] as? String).flatMap { $0.firstMatch(of: /\d{4}/).map { String($0.output) } } ?? ""
            r.container = r.type == .book ? str("publisher") : [str("container-title"), str("publisher")].first { !$0.isEmpty } ?? ""
            r.volume = str("volume"); r.issue = str("issue"); r.pages = str("page")
            r.doi = str("DOI"); r.url = str("URL")
            return r.title.isEmpty ? nil : r
        }
    }

    static func cslJSON(_ refs: [Reference]) -> String {
        let items: [[String: Any]] = refs.enumerated().map { n, r in
            var d: [String: Any] = ["id": "ref\(n + 1)", "type": r.type == .article ? "article-journal" : r.type == .book ? "book" : "webpage",
                                    "title": r.title]
            d["author"] = r.authors.map { a -> [String: String] in
                let p = a.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                return p.count == 2 ? ["family": p[0], "given": p[1]] : ["literal": a]
            }
            if let y = Int(r.year) { d["issued"] = ["date-parts": [[y]]] }
            if !r.container.isEmpty { d[r.type == .book ? "publisher" : "container-title"] = r.container }
            for (k, v) in [("volume", r.volume), ("issue", r.issue), ("page", r.pages), ("DOI", r.doi), ("URL", r.url)] where !v.isEmpty { d[k] = v }
            return d
        }
        let data = (try? JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Already in the library: the same DOI, or the same title in the same year.
    static func isDuplicate(_ r: Reference, of library: [Reference]) -> Bool {
        library.contains { o in
            (!r.doi.isEmpty && o.doi.caseInsensitiveCompare(r.doi) == .orderedSame)
                || (o.title.caseInsensitiveCompare(r.title) == .orderedSame && o.year == r.year)
        }
    }
}

// MARK: - Headless self-test (StudyBar --cite-selftest)

enum CitationSelfTest {
    static func run() -> Int32 {
        var fail = 0
        func check(_ n: String, _ ok: Bool, _ d: String = "") { print("  \(ok ? "ok  " : "FAIL") \(n) \(d)"); if !ok { fail += 1 } }

        // As Google Scholar, Zotero and a hand-written .bib give it.
        let bib = #"""
        @article{gauss1813theoria,
          title={Theoria attractionis corporum sphaeroidicorum},
          author={Gauss, Carl Friedrich and M{\"o}bius, August F.},
          journal={Commentationes Societatis Regiae Scientiarum Gottingensis},
          volume={2}, pages={355--378}, year={1813}
        }
        @comment{not a reference}
        @book{griffiths2017,
          title = {{Introduction to Electrodynamics}},
          author = {David J. Griffiths},
          publisher = {Cambridge University Press},
          year = 2017,
          doi = {https://doi.org/10.1017/9781108333511}
        }
        @misc{who2020, title = "Coronavirus " # "disease", author = {{World Health Organization}}, year = {2020}, url = {https://who.int}}
        """#
        let b = CitationFormatter.parse(bib)
        check("BibTeX: three entries, the comment skipped", b.count == 3, "\(b.count)")
        if b.count == 3 {
            check("BibTeX: accents, page ranges, journals", b[0].authors == ["Gauss, Carl Friedrich", "Möbius, August F."]
                  && b[0].pages == "355–378" && b[0].year == "1813" && b[0].type == .article && b[0].container.hasPrefix("Commentationes"), "\(b[0].authors) \(b[0].pages)")
            check("BibTeX: a book — First Last flipped, double braces, bare year, DOI link", b[1].type == .book && b[1].authors == ["Griffiths, David J."]
                  && b[1].title == "Introduction to Electrodynamics" && b[1].year == "2017" && b[1].container == "Cambridge University Press"
                  && b[1].doi == "10.1017/9781108333511", "\(b[1])")
            check("BibTeX: an organization as author, # joins", b[2].authors == ["World Health Organization"] && b[2].title == "Coronavirus disease" && b[2].url == "https://who.int")
        }

        let ris = "TY  - JOUR\r\nAU  - Purcell, Edward M.\r\nAU  - Morin, David J.\r\nTI  - Electricity and Magnetism\r\nT2  - Am. J. Phys.\r\nPY  - 2013/01/01/\r\nVL  - 3\r\nIS  - 2\r\nSP  - 10\r\nEP  - 20\r\nDO  - 10.1/abc\r\nER  - \r\nTY  - BOOK\r\nTI  - A Book\r\nPB  - Pub\r\nPY  - 1999\r\nER  - \r\n"
        let r = CitationFormatter.parse(ris)
        check("RIS: two records", r.count == 2)
        if r.count == 2 {
            check("RIS: authors, year from a date, pages, journal", r[0].authors == ["Purcell, Edward M.", "Morin, David J."] && r[0].year == "2013"
                  && r[0].pages == "10–20" && r[0].container == "Am. J. Phys." && r[0].doi == "10.1/abc" && r[1].type == .book && r[1].container == "Pub")
        }

        // Out and back in, each format.
        let all = b + r
        func same(_ x: [Reference], _ y: [Reference]) -> Bool {
            x.count == y.count && zip(x, y).allSatisfy { $0.title == $1.title && $0.authors == $1.authors && $0.year == $1.year
                && $0.container == $1.container && $0.type == $1.type && $0.doi == $1.doi }
        }
        check("RIS round trip", same(CitationFormatter.parse(all.map(CitationFormatter.ris).joined(separator: "\n")), all))
        check("CSL-JSON round trip", same(CitationFormatter.parse(CitationFormatter.cslJSON(all)), all))
        let back = CitationFormatter.parse(all.map(CitationFormatter.bibtex).joined(separator: "\n\n"))
        check("BibTeX round trip", zip(back, all).allSatisfy { $0.title == $1.title && $0.authors == $1.authors && $0.year == $1.year } && back.count == all.count,
              "\(back.map(\.authors))")
        check("not a format → nothing", CitationFormatter.parse("electric flux through a surface").isEmpty && CitationFormatter.parse("10.1017/9781108333511").isEmpty)
        check("a duplicate by DOI or by title and year", CitationFormatter.isDuplicate(b[1], of: back) && !CitationFormatter.isDuplicate(Reference(title: "New", year: "2024"), of: all))

        // Essay help: a draft is offered the library to cite from, and told never to invent one.
        let draft = NoteAI.draft.user("Point 2: Gauss's law makes symmetric fields easy", sources: Array(b.prefix(2)))
        check("in-text: one author, two, three or more", CitationFormatter.inText(b[1]) == "(Griffiths, 2017)"
              && CitationFormatter.inText(b[0]) == "(Gauss & Möbius, 1813)" && CitationFormatter.inText(Reference(authors: ["A, B", "C, D", "E, F"], year: "2015")) == "(A et al., 2015)")
        check("a draft may cite the library, as it's written there", draft.contains("SOURCES") && draft.contains("- (Gauss & Möbius, 1813) Theoria")
              && NoteAI.draft.system().contains("Never invent a source"))
        check("other actions aren't handed the library", !NoteAI.thesis.user("x", sources: b).contains("SOURCES") && !NoteAI.summarize.system().contains("coach"))

        print(fail == 0 ? "CITE SELFTEST: ALL PASS" : "CITE SELFTEST: \(fail) FAILED")
        return fail == 0 ? 0 : 1
    }
}
