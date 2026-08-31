import Foundation

/// Fetches and parses RSS 2.0 and Atom feeds (professor blogs, journal TOC alerts,
/// course news). No key, no cloud — plain HTTP + XML.
struct Article: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var link: String
    var date: Date?
    var summary: String
    var source: String
    var content: String = ""        // fuller body (RSS content:encoded) for the in-app reader
    /// The best readable body available — full content if the feed shipped it, else the summary.
    var readable: String { content.isEmpty ? summary : content }
}

enum RSSService {

    /// Fetch one feed → (discovered feed title, its recent articles).
    static func fetch(_ feed: RSSFeed) async -> (title: String, items: [Article]) {
        guard let url = URL(string: feed.url) else { return (feed.title, []) }
        var req = URLRequest(url: url)
        req.setValue("StudyBar/1.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return (feed.title, []) }
        let parser = XMLParser(data: data)
        let d = FeedParser()
        parser.delegate = d
        parser.parse()
        let source = feed.title.isEmpty ? d.feedTitle : feed.title
        let items = d.items.map { a -> Article in var x = a; x.source = source.isEmpty ? a.source : source; return x }
        return (d.feedTitle.isEmpty ? feed.title : d.feedTitle, items)
    }

    /// Fetch every feed concurrently, merged newest-first.
    static func fetchAll(_ feeds: [RSSFeed]) async -> [Article] {
        await withTaskGroup(of: [Article].self) { group in
            for f in feeds { group.addTask { await fetch(f).items } }
            var all: [Article] = []
            for await items in group { all += items }
            return all.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        }
    }

    /// Probe a URL for its feed title (used when adding a subscription).
    static func probeTitle(_ urlString: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        let parser = XMLParser(data: data); let d = FeedParser(); parser.delegate = d; parser.parse()
        return d.feedTitle.isEmpty ? nil : d.feedTitle
    }
}

/// Handles both RSS (`channel`/`item`) and Atom (`feed`/`entry`).
private final class FeedParser: NSObject, XMLParserDelegate {
    var feedTitle = ""
    var items: [Article] = []

    private var buf = ""
    private var inItem = false
    private var atomHeaderDone = false
    private var cur = Article(title: "", link: "", date: nil, summary: "", source: "")
    private var atomLinkHref: String?

    private static let rfc822: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"; return f
    }()
    private static let iso = ISO8601DateFormatter()

    func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes attrs: [String: String]) {
        buf = ""
        switch name {
        case "item", "entry":
            inItem = true; atomHeaderDone = true
            cur = Article(title: "", link: "", date: nil, summary: "", source: "")
            atomLinkHref = nil
        case "link":
            // Atom uses <link href="…"/>; RSS puts the URL in the element text.
            if inItem, let href = attrs["href"], attrs["rel"] != "self" { atomLinkHref = href }
        default: break
        }
    }

    func parser(_ p: XMLParser, foundCharacters s: String) { buf += s }
    func parser(_ p: XMLParser, foundCDATA CDATABlock: Data) { if let s = String(data: CDATABlock, encoding: .utf8) { buf += s } }

    func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let text = buf.trimmingCharacters(in: .whitespacesAndNewlines)
        if !inItem {
            if name == "title", feedTitle.isEmpty { feedTitle = text }
            return
        }
        switch name {
        case "title":       cur.title = text
        case "link":        if cur.link.isEmpty { cur.link = atomLinkHref ?? text }
        case "description", "summary", "content":
            if cur.summary.isEmpty { cur.summary = stripHTML(text) }
            if name == "content", cur.content.isEmpty { cur.content = stripHTMLKeepingBreaks(text) }
        case "content:encoded", "encoded":
            if cur.content.isEmpty { cur.content = stripHTMLKeepingBreaks(text) }
        case "pubDate", "published", "updated":
            if cur.date == nil { cur.date = parseDate(text) }
        case "item", "entry":
            if cur.link.isEmpty { cur.link = atomLinkHref ?? "" }
            if !cur.title.isEmpty { items.append(cur) }
            inItem = false
        default: break
        }
        buf = ""
    }

    private func parseDate(_ s: String) -> Date? {
        FeedParser.rfc822.date(from: s) ?? FeedParser.iso.date(from: s)
    }
    private func stripHTML(_ s: String) -> String {
        let noTags = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return noTags.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }
    /// Strip tags but turn paragraph / break / list boundaries into newlines so the
    /// reader keeps its shape. Collapses runs of blank lines.
    private func stripHTMLKeepingBreaks(_ s: String) -> String {
        var t = s
        for (pat, rep) in [("(?i)</p>", "\n\n"), ("(?i)<br\\s*/?>", "\n"),
                           ("(?i)</li>", "\n"), ("(?i)</h[1-6]>", "\n\n"), ("(?i)</div>", "\n")] {
            t = t.replacingOccurrences(of: pat, with: rep, options: .regularExpression)
        }
        t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "&nbsp;", with: " ")
             .replacingOccurrences(of: "&amp;", with: "&")
             .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&quot;", with: "\"")
        t = t.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - OPML import / export + Google News

extension RSSService {
    /// Build a Google News RSS URL for a topic search — turns a plain query into a feed.
    static func googleNews(topic: String) -> String {
        let q = topic.trimmingCharacters(in: .whitespaces)
        let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        return "https://news.google.com/rss/search?q=\(enc)&hl=en-US&gl=US&ceid=US:en"
    }

    /// Parse an OPML document into (title, url, folder) feed rows. Folders come from a
    /// parent `<outline>` with no `xmlUrl`.
    static func parseOPML(_ data: Data) -> [(title: String, url: String, folder: String)] {
        let d = OPMLParser(); let p = XMLParser(data: data); p.delegate = d; p.parse()
        return d.feeds
    }

    /// Serialize subscriptions to OPML 2.0, grouping by folder.
    static func exportOPML(_ feeds: [RSSFeed]) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
             .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        func line(_ f: RSSFeed, indent: String) -> String {
            "\(indent)<outline type=\"rss\" text=\"\(esc(f.title.isEmpty ? f.url : f.title))\" title=\"\(esc(f.title.isEmpty ? f.url : f.title))\" xmlUrl=\"\(esc(f.url))\"/>"
        }
        let byFolder = Dictionary(grouping: feeds, by: { $0.folder })
        var body = ""
        for folder in byFolder.keys.sorted(by: { ($0.isEmpty ? "~" : $0) < ($1.isEmpty ? "~" : $1) }) {
            let group = byFolder[folder] ?? []
            if folder.isEmpty {
                body += group.map { line($0, indent: "    ") }.joined(separator: "\n") + "\n"
            } else {
                body += "    <outline text=\"\(esc(folder))\" title=\"\(esc(folder))\">\n"
                body += group.map { line($0, indent: "      ") }.joined(separator: "\n") + "\n"
                body += "    </outline>\n"
            }
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head><title>StudyBar News</title></head>
          <body>
        \(body)  </body>
        </opml>
        """
    }
}

private final class OPMLParser: NSObject, XMLParserDelegate {
    var feeds: [(title: String, url: String, folder: String)] = []
    // One entry per open <outline>: the folder name it contributes, or nil for a feed
    // outline. XMLParser fires didEnd for every element (even self-closing), so pushing on
    // every start and popping on every end keeps the stack balanced.
    private var stack: [String?] = []

    private var currentFolder: String { stack.compactMap { $0 }.last ?? "" }

    func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        guard name == "outline" else { return }
        let title = a["title"] ?? a["text"] ?? ""
        if let url = a["xmlUrl"], !url.isEmpty {
            feeds.append((title: title, url: url, folder: currentFolder))
            stack.append(nil)                       // feed outline contributes no folder
        } else {
            stack.append(title.isEmpty ? nil : title)   // container outline = a folder
        }
    }
    func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "outline", !stack.isEmpty { stack.removeLast() }
    }
}
