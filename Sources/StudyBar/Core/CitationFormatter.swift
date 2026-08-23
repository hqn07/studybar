import Foundation

enum CiteStyle: String, CaseIterable, Identifiable {
    case apa = "APA", mla = "MLA", chicago = "Chicago", bibtex = "BibTeX"
    var id: String { rawValue }
}

enum CitationFormatter {

    /// In-text citation, e.g. "(Smith, 2020)".
    static func inText(_ r: Reference) -> String {
        let author = r.authors.first?.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "Author"
        return "(\(author.isEmpty ? "Author" : author), \(r.year.isEmpty ? "n.d." : r.year))"
    }

    static func format(_ r: Reference, style: CiteStyle) -> String {
        switch style {
        case .apa:     return apa(r)
        case .mla:     return mla(r)
        case .chicago: return chicago(r)
        case .bibtex:  return bibtex(r)
        }
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
        if !r.authors.isEmpty { fields.append("  author = {\(r.authors.joined(separator: " and "))}") }
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
