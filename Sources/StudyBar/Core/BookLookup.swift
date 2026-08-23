import Foundation
import AppKit

struct BookInfo: Sendable {
    var title: String
    var author: String
    var publisher: String
    var year: String
    var pageCount: Int
    var isbn: String
    var coverURL: String
}

/// Looks up book metadata by ISBN (Google Books, falls back to Open Library).
enum BookLookup {
    static func fetch(isbn raw: String) async -> BookInfo? {
        let isbn = raw.filter { $0.isNumber || $0 == "X" || $0 == "x" }
        guard isbn.count >= 10 else { return nil }
        // Open Library first — free, no API key/quota. Google Books as a fallback.
        if let ol = await openLibrary(isbn) { return ol }
        return await google(isbn)
    }

    // MARK: Title search (Open Library) — returns several candidates

    private struct OLSearch: Codable { let docs: [OLDoc] }
    private struct OLDoc: Codable {
        let title: String?
        let author_name: [String]?
        let first_publish_year: Int?
        let cover_i: Int?
        let isbn: [String]?
        let number_of_pages_median: Int?
        let publisher: [String]?
    }

    static func search(title raw: String) async -> [BookInfo] {
        let q = raw.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2,
              let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://openlibrary.org/search.json?q=\(enc)&limit=12&fields=title,author_name,first_publish_year,cover_i,isbn,number_of_pages_median,publisher")
        else { return [] }
        guard let data = try? await URLSession.shared.data(from: url).0,
              let resp = try? JSONDecoder().decode(OLSearch.self, from: data) else { return [] }
        return resp.docs.compactMap { d in
            guard let title = d.title else { return nil }
            let cover = d.cover_i.map { "https://covers.openlibrary.org/b/id/\($0)-L.jpg" } ?? ""
            return BookInfo(title: title,
                            author: d.author_name?.prefix(2).joined(separator: ", ") ?? "",
                            publisher: d.publisher?.first ?? "",
                            year: d.first_publish_year.map(String.init) ?? "",
                            pageCount: d.number_of_pages_median ?? 0,
                            isbn: d.isbn?.first ?? "",
                            coverURL: cover)
        }
    }

    // MARK: Google Books

    private struct GBResponse: Codable { let items: [GBItem]? }
    private struct GBItem: Codable { let volumeInfo: GBVolume }
    private struct GBVolume: Codable {
        let title: String?
        let subtitle: String?
        let authors: [String]?
        let publisher: String?
        let publishedDate: String?
        let pageCount: Int?
        let imageLinks: GBImages?
    }
    private struct GBImages: Codable { let thumbnail: String?; let smallThumbnail: String? }

    private static func google(_ isbn: String) async -> BookInfo? {
        guard let url = URL(string: "https://www.googleapis.com/books/v1/volumes?q=isbn:\(isbn)") else { return nil }
        guard let data = try? await URLSession.shared.data(from: url).0,
              let resp = try? JSONDecoder().decode(GBResponse.self, from: data),
              let v = resp.items?.first?.volumeInfo, let title = v.title else { return nil }
        var cover = v.imageLinks?.thumbnail ?? v.imageLinks?.smallThumbnail ?? ""
        if cover.hasPrefix("http://") { cover = "https://" + cover.dropFirst("http://".count) }
        return BookInfo(title: title,
                        author: v.authors?.joined(separator: ", ") ?? "",
                        publisher: v.publisher ?? "",
                        year: String((v.publishedDate ?? "").prefix(4)),
                        pageCount: v.pageCount ?? 0,
                        isbn: isbn, coverURL: cover)
    }

    // MARK: Open Library fallback

    private static func openLibrary(_ isbn: String) async -> BookInfo? {
        guard let url = URL(string: "https://openlibrary.org/api/books?bibkeys=ISBN:\(isbn)&format=json&jscmd=data") else { return nil }
        guard let data = try? await URLSession.shared.data(from: url).0,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let book = obj["ISBN:\(isbn)"] as? [String: Any] else { return nil }
        let title = book["title"] as? String ?? "Unknown"
        let authors = (book["authors"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        let publishers = (book["publishers"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        let pages = book["number_of_pages"] as? Int ?? 0
        let cover = "https://covers.openlibrary.org/b/isbn/\(isbn)-L.jpg"
        return BookInfo(title: title, author: authors.joined(separator: ", "),
                        publisher: publishers.first ?? "",
                        year: String((book["publish_date"] as? String ?? "").suffix(4)),
                        pageCount: pages, isbn: isbn, coverURL: cover)
    }
}

/// Downloads and caches book cover images locally.
enum CoverStore {
    static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StudyBar/Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Downloads a cover to `<id>.jpg`; returns the filename, or nil.
    static func download(from urlString: String, id: UUID) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        guard let data = try? await URLSession.shared.data(from: url).0, data.count > 200 else { return nil }
        let name = "\(id.uuidString).jpg"
        try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
        return name
    }

    static func image(_ name: String) -> NSImage? {
        guard !name.isEmpty else { return nil }
        return NSImage(contentsOf: dir.appendingPathComponent(name))
    }
}
