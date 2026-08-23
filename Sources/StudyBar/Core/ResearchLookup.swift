import Foundation

/// Free, no-key research lookups: Wikipedia summaries + arXiv paper search.
/// Reference/discovery only — surfaces sources for the student to read and cite.

struct WikiSummary {
    let title: String
    let extract: String
    let url: String
}

struct Paper: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var authors: [String]
    var year: String
    var summary: String
    var url: String
    var pdfURL: String
}

struct OAWork {
    let title: String
    let authors: [String]
    let year: String
    let isOA: Bool
    let pdfURL: String?
    let landingURL: String?
    let doi: String
}

enum ResearchLookup {

    /// OpenAlex lookup by DOI → open-access PDF if one exists. Free, no key.
    static func openAlex(doi: String) async -> OAWork? {
        var clean = doi.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["https://doi.org/", "http://doi.org/", "doi:", "DOI:"] {
            if clean.hasPrefix(p) { clean = String(clean.dropFirst(p.count)) }
        }
        guard !clean.isEmpty,
              let enc = clean.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.openalex.org/works/doi:\(enc)?mailto=studybar@example.com") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("StudyBar/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let title = o["display_name"] as? String ?? o["title"] as? String ?? clean
        let year = (o["publication_year"] as? Int).map(String.init) ?? ""
        let authors = (o["authorships"] as? [[String: Any]] ?? []).compactMap {
            ($0["author"] as? [String: Any])?["display_name"] as? String
        }
        let oa = o["open_access"] as? [String: Any]
        let best = o["best_oa_location"] as? [String: Any]
        let primary = o["primary_location"] as? [String: Any]
        let pdf = (best?["pdf_url"] as? String) ?? (primary?["pdf_url"] as? String) ?? (oa?["oa_url"] as? String)
        let landing = (best?["landing_page_url"] as? String) ?? (primary?["landing_page_url"] as? String)
        return OAWork(title: title, authors: authors, year: year,
                      isOA: (oa?["is_oa"] as? Bool) ?? (pdf != nil),
                      pdfURL: pdf, landingURL: landing, doi: clean)
    }

    /// Wikipedia REST summary for a term. Returns nil on no match / disambiguation.
    static func wikipedia(_ term: String) async -> WikiSummary? {
        let q = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty,
              let slug = q.replacingOccurrences(of: " ", with: "_")
                .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(slug)") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("StudyBar/1.0 (macOS study app)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let type = obj["type"] as? String ?? ""
        guard type != "disambiguation" else { return nil }
        let title = obj["title"] as? String ?? q
        let extract = obj["extract"] as? String ?? ""
        let page = ((obj["content_urls"] as? [String: Any])?["desktop"] as? [String: Any])?["page"] as? String
            ?? "https://en.wikipedia.org/wiki/\(slug)"
        guard !extract.isEmpty else { return nil }
        return WikiSummary(title: title, extract: extract, url: page)
    }

    /// arXiv search (Atom XML). Returns up to `max` recent-matching papers.
    static func arxiv(_ query: String, max: Int = 8) async -> [Paper] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty,
              let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://export.arxiv.org/api/query?search_query=all:\(enc)&start=0&max_results=\(max)&sortBy=relevance") else { return [] }
        guard let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        let parser = XMLParser(data: data)
        let delegate = ArxivParser()
        parser.delegate = delegate
        parser.parse()
        return delegate.papers
    }
}

/// Minimal Atom parser for arXiv `<entry>` elements.
private final class ArxivParser: NSObject, XMLParserDelegate {
    var papers: [Paper] = []
    private var inEntry = false
    private var element = ""
    private var buf = ""
    private var cur = Paper(title: "", authors: [], year: "", summary: "", url: "", pdfURL: "")

    func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes attrs: [String: String]) {
        element = name
        if name == "entry" {
            inEntry = true
            cur = Paper(title: "", authors: [], year: "", summary: "", url: "", pdfURL: "")
        }
        if inEntry, name == "link" {
            if attrs["type"] == "application/pdf" { cur.pdfURL = attrs["href"] ?? cur.pdfURL }
            else if (attrs["rel"] == "alternate" || attrs["type"] == "text/html"), cur.url.isEmpty { cur.url = attrs["href"] ?? "" }
        }
        buf = ""
    }

    func parser(_ p: XMLParser, foundCharacters s: String) { buf += s }

    func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard inEntry else { return }
        let text = buf.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "title":     cur.title = collapse(text)
        case "summary":   cur.summary = collapse(text)
        case "name":      if !text.isEmpty { cur.authors.append(text) }
        case "published": cur.year = String(text.prefix(4))
        case "id":        if cur.url.isEmpty { cur.url = text }
        case "entry":     if !cur.title.isEmpty { papers.append(cur) }; inEntry = false
        default:          break
        }
        buf = ""
    }

    private func collapse(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
