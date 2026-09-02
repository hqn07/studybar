import Foundation
import PDFKit

/// On-device text layer for a book's PDF — the foundation for searching and (later) AI Q&A
/// over the actual content. Extracts text per page with PDFKit, stores the chunks beside the
/// app's other assets (App Support/StudyBar/Books/<id>.json — NOT in the synced data.json, so
/// the store stays small), and ranks pages against a query with simple keyword scoring: no
/// cloud, no embeddings. Scanned/image PDFs have no text layer and extract nothing (OCR would
/// be a later add). The whole book is never sent to a model; retrieval feeds only relevant
/// chunks (see `topChunks`).
enum BookText {
    struct Chunk: Codable, Hashable { let page: Int; let text: String }
    struct Hit: Identifiable { let id = UUID(); let page: Int; let snippet: String; let score: Double }

    static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StudyBar/Books", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static func chunksURL(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).json") }
    static func pdfURL(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).pdf") }

    /// Copy + extract a PDF for a book. Returns the page count on success, or nil if the PDF
    /// has no extractable text (scanned image). Runs off the main thread — call from a Task.
    static func attach(_ src: URL, to id: UUID) -> Int? {
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        guard let doc = PDFDocument(url: src) else { return nil }
        var chunks: [Chunk] = []
        for i in 0..<doc.pageCount {
            let t = (doc.page(at: i)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { chunks.append(Chunk(page: i + 1, text: t)) }
        }
        guard !chunks.isEmpty else { return nil }
        try? FileManager.default.removeItem(at: pdfURL(id))
        try? FileManager.default.copyItem(at: src, to: pdfURL(id))
        if let data = try? JSONEncoder().encode(chunks) { try? data.write(to: chunksURL(id), options: .atomic) }
        return doc.pageCount
    }

    static func chunks(_ id: UUID) -> [Chunk] {
        guard let data = try? Data(contentsOf: chunksURL(id)),
              let c = try? JSONDecoder().decode([Chunk].self, from: data) else { return [] }
        return c
    }
    static func hasText(_ id: UUID) -> Bool { FileManager.default.fileExists(atPath: chunksURL(id).path) }
    static func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: chunksURL(id))
        try? FileManager.default.removeItem(at: pdfURL(id))
    }

    /// Keyword search across the book's pages — ranked, one snippet per matching page.
    static func search(_ id: UUID, query: String, limit: Int = 15) -> [Hit] {
        let terms = tokenize(query)
        guard !terms.isEmpty else { return [] }
        var hits: [Hit] = []
        for c in chunks(id) {
            let lower = c.text.lowercased()
            var score = 0.0
            for t in terms {
                let n = occurrences(of: t, in: lower)
                if n > 0 { score += Double(n) }
            }
            if score > 0 { hits.append(Hit(page: c.page, snippet: snippet(c.text, terms: terms), score: score)) }
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// Top-K most relevant chunks for a query — the retrieval step that feeds AI Q&A (P2),
    /// so the model reads only relevant pages, never the whole book.
    static func topChunks(_ id: UUID, query: String, k: Int = 5) -> [Chunk] {
        let terms = tokenize(query)
        guard !terms.isEmpty else { return [] }
        let scored = chunks(id).map { c -> (Chunk, Double) in
            let lower = c.text.lowercased()
            return (c, terms.reduce(0.0) { $0 + Double(occurrences(of: $1, in: lower)) })
        }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
        return Array(scored.prefix(k).map(\.0))
    }

    // MARK: helpers
    private static func tokenize(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 }
    }
    private static func occurrences(of term: String, in text: String) -> Int {
        guard !term.isEmpty else { return 0 }
        var count = 0, idx = text.startIndex
        while let r = text.range(of: term, range: idx..<text.endIndex) { count += 1; idx = r.upperBound }
        return count
    }
    private static func snippet(_ text: String, terms: [String], radius: Int = 90) -> String {
        let lower = text.lowercased()
        guard let first = terms.compactMap({ lower.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) else {
            return String(text.prefix(radius * 2))
        }
        let start = text.index(first.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(first.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        let mid = text[start..<end].replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return (start > text.startIndex ? "…" : "") + mid + (end < text.endIndex ? "…" : "")
    }
}
