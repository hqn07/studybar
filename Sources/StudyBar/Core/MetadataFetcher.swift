import Foundation

/// Fetches public citation metadata. DOI -> CrossRef API; URL -> page <title>.
/// All user-initiated; no keys, no tracking.
enum MetadataFetcher {

    enum FetchError: Error { case badInput, notFound }

    static func fetch(input raw: String) async throws -> Reference {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let doi = extractDOI(s) {
            return try await fromCrossRef(doi: doi)
        } else if s.contains(".") {
            return try await fromURL(s)
        }
        throw FetchError.badInput
    }

    // MARK: DOI

    private static func extractDOI(_ s: String) -> String? {
        if let r = s.range(of: #"10\.\d{4,9}/[-._;()/:A-Za-z0-9]+"#, options: .regularExpression) {
            return String(s[r])
        }
        return nil
    }

    private static func fromCrossRef(doi: String) async throws -> Reference {
        guard let url = URL(string: "https://api.crossref.org/works/\(doi)") else { throw FetchError.badInput }
        var req = URLRequest(url: url)
        req.setValue("StudyBar/0.1 (mailto:studybar@example.com)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let m = json["message"] as? [String: Any] else { throw FetchError.notFound }
        return parseItem(m, doi: doi)
    }

    /// Search academic works by title/keywords (CrossRef). Returns several candidates.
    static func search(title raw: String) async -> [Reference] {
        let q = raw.trimmingCharacters(in: .whitespaces)
        guard q.count >= 3,
              let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.crossref.org/works?query.bibliographic=\(enc)&rows=10&select=title,author,container-title,issued,volume,issue,page,DOI,type")
        else { return [] }
        var req = URLRequest(url: url)
        req.setValue("StudyBar/0.1 (mailto:studybar@example.com)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let items = message["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            let r = parseItem(item, doi: item["DOI"] as? String ?? "")
            return r.title.isEmpty ? nil : r
        }
    }

    private static func parseItem(_ m: [String: Any], doi: String) -> Reference {
        var r = Reference(type: .article, doi: doi)
        r.title = (m["title"] as? [String])?.first ?? ""
        r.container = (m["container-title"] as? [String])?.first ?? ""
        if let authors = m["author"] as? [[String: Any]] {
            r.authors = authors.compactMap { a in
                let fam = a["family"] as? String ?? ""
                let giv = a["given"] as? String ?? ""
                guard !fam.isEmpty else { return nil }
                return giv.isEmpty ? fam : "\(fam), \(giv)"
            }
        }
        if let issued = m["issued"] as? [String: Any],
           let parts = issued["date-parts"] as? [[Int]], let first = parts.first, let y = first.first {
            r.year = String(y)
        }
        r.volume = m["volume"] as? String ?? ""
        r.issue = m["issue"] as? String ?? ""
        r.pages = m["page"] as? String ?? ""
        let type = (m["type"] as? String ?? "").lowercased()
        if type.contains("book") || r.container.lowercased().contains("book") { r.type = .book }
        return r
    }

    /// Best-effort <title> of a web page (for auto-naming saved links).
    static func pageTitle(_ urlString: String) async -> String? {
        let s = urlString.contains("://") ? urlString : "https://\(urlString)"
        guard let url = URL(string: s),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        return html.flatMap { extractTitle($0) }
    }

    // MARK: URL

    private static func fromURL(_ input: String) async throws -> Reference {
        let s = input.contains("://") ? input : "https://\(input)"
        guard let url = URL(string: s) else { throw FetchError.badInput }
        var r = Reference(type: .website, url: s)
        r.container = url.host?.replacingOccurrences(of: "www.", with: "") ?? ""
        r.year = String(Calendar.current.component(.year, from: .now))
        let (data, _) = try await URLSession.shared.data(from: url)
        if let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
            r.title = extractTitle(html) ?? url.host ?? s
        } else {
            r.title = url.host ?? s
        }
        return r
    }

    private static func extractTitle(_ html: String) -> String? {
        if let r = html.range(of: #"<title[^>]*>([\s\S]*?)</title>"#, options: [.regularExpression, .caseInsensitive]) {
            let raw = String(html[r])
            let inner = raw.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            return decodeEntities(inner).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
         .replacingOccurrences(of: "&lt;", with: "<")
         .replacingOccurrences(of: "&gt;", with: ">")
         .replacingOccurrences(of: "&quot;", with: "\"")
         .replacingOccurrences(of: "&#39;", with: "'")
         .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}
