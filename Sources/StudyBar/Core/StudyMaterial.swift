import AppKit
import NaturalLanguage
import PDFKit
import Vision

// MARK: - Course material the study tools read

/// A file attached to a course for studying — slides, a handout, a problem set. Its text is
/// extracted once into App Support/StudyBar/StudyFiles/<id>.json (not the synced store), and
/// the file itself is copied beside it so it can be reopened.
struct StudyFile: Identifiable, Codable, Hashable {
    var id = UUID()
    var courseID: UUID?
    var name: String
    var addedAt: Date = .now
    var units: Int = 0                    // pages or slides that had text
}

/// A passage of course material and where it came from.
struct StudyPassage: Hashable {
    let title: String                     // "Week 3 — Gauss's Law", "Lecture 4.pptx"
    let locator: String                   // "p. 12", "slide 4", "" for a note
    let text: String
    /// How the model is told to cite it, and how an answer names it back.
    var cite: String { locator.isEmpty ? title : "\(title), \(locator)" }
}

/// One thing that can be ticked as a source in the Study module.
enum StudySource: Hashable, Identifiable {
    case note(UUID), reading(UUID), file(UUID), syllabus(UUID)
    var id: String {
        switch self {
        case .note(let u): "n\(u)"; case .reading(let u): "r\(u)"; case .file(let u): "f\(u)"; case .syllabus(let u): "s\(u)"
        }
    }
}

enum StudyMaterial {
    static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StudyBar/StudyFiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private struct Unit: Codable { let locator: String; let text: String }
    private static func unitsURL(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).json") }
    static func fileURL(_ f: StudyFile) -> URL {
        dir.appendingPathComponent(f.id.uuidString).appendingPathExtension((f.name as NSString).pathExtension)
    }

    static let fileTypes = ["pdf", "pptx", "docx", "doc", "rtf", "rtfd", "odt", "txt", "md", "html",
                            "png", "jpg", "jpeg", "heic", "tiff"]

    /// Copy the file in and extract its text. nil when nothing readable came out. Slow on a
    /// scanned PDF (it is OCR'd) — call off the main thread.
    static func attach(_ src: URL, courseID: UUID?) -> StudyFile? {
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        let units = extract(src)
        guard !units.isEmpty else { return nil }
        let file = StudyFile(courseID: courseID, name: src.lastPathComponent, units: units.count)
        try? FileManager.default.copyItem(at: src, to: fileURL(file))
        guard let data = try? JSONEncoder().encode(units.map { Unit(locator: $0.locator, text: $0.text) }),
              (try? data.write(to: unitsURL(file.id), options: .atomic)) != nil else { return nil }
        return file
    }

    static func remove(_ f: StudyFile) {
        try? FileManager.default.removeItem(at: unitsURL(f.id))
        try? FileManager.default.removeItem(at: fileURL(f))
    }

    /// Text by page, slide or section — whatever the format's natural unit is.
    static func extract(_ url: URL) -> [(locator: String, text: String)] {
        func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        switch url.pathExtension.lowercased() {
        case "pdf":
            guard let doc = PDFDocument(url: url) else { return [] }
            var out: [(String, String)] = []
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                var t = clean(page.string ?? "")
                // A scanned page has no text layer: read it.
                if t.count < 20, let img = render(page) { t = clean(ocr(img)) }
                if !t.isEmpty { out.append(("p. \(i + 1)", t)) }
            }
            return out
        case "pptx":
            return slides(url).compactMap { n, t in t.isEmpty ? nil : ("slide \(n)", t) }
        case "png", "jpg", "jpeg", "heic", "tiff":
            guard let img = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
            let t = clean(ocr(img))
            return t.isEmpty ? [] : [("", t)]
        default:
            let text: String
            if ["txt", "md"].contains(url.pathExtension.lowercased()) {
                text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            } else {
                text = (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string ?? ""
            }
            let parts = LectureNotes.chunks(clean(text), maxChars: 2_000).map(clean).filter { !$0.isEmpty }
            return parts.enumerated().map { i, t in (parts.count > 1 ? "part \(i + 1)" : "", t) }
        }
    }

    /// A .pptx is a zip of XML; each slide's text is its `<a:t>` runs. `unzip` ships with macOS.
    static func slides(_ url: URL) -> [(number: Int, text: String)] {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pptx-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-qq", "-o", url.path, "ppt/slides/slide*.xml", "-d", tmp.path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        p.waitUntilExit()
        let slideDir = tmp.appendingPathComponent("ppt/slides")
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: slideDir.path)) ?? [])
            .filter { $0.hasPrefix("slide") && $0.hasSuffix(".xml") }
            .sorted { Int($0.filter(\.isNumber)) ?? 0 < Int($1.filter(\.isNumber)) ?? 0 }
        return files.map { name in
            let number = Int(name.filter(\.isNumber)) ?? 0
            let xml = (try? String(contentsOf: slideDir.appendingPathComponent(name), encoding: .utf8)) ?? ""
            // One line per paragraph (`<a:p>`), the runs inside it joined.
            let text = xml.components(separatedBy: "</a:p>").map { para in
                para.matches(of: /<a:t>([^<]*)<\/a:t>/).map { unescape(String($0.output.1)) }.joined()
            }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n")
            return (number, text)
        }
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
         .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
         .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func render(_ page: PDFPage, scale: CGFloat = 2) -> CGImage? {
        let b = page.bounds(for: .mediaBox)
        let img = page.thumbnail(of: NSSize(width: b.width * scale, height: b.height * scale), for: .mediaBox)
        return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// On-device text recognition, handwriting included.
    static func ocr(_ image: CGImage) -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: image).perform([req])
        return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    // MARK: Sources → passages

    /// Everything a course has to study from, for the source list.
    static func sources(course: UUID?, in data: AppData) -> [(source: StudySource, title: String, detail: String)] {
        var out: [(StudySource, String, String)] = []
        if let c = data.courses.first(where: { $0.id == course }), let s = c.syllabus, !s.filePath.isEmpty {
            out.append((.syllabus(c.id), "Syllabus", s.fileName))
        }
        for f in (data.studyFiles ?? []).filter({ $0.courseID == course }).sorted(by: { $0.addedAt > $1.addedAt }) {
            out.append((.file(f.id), f.name, "\(f.units) \(f.name.lowercased().hasSuffix(".pptx") ? "slides" : "parts")"))
        }
        for r in data.reading.filter({ $0.courseID == course && ($0.pdfPages ?? 0) > 0 }) {
            out.append((.reading(r.id), r.title, "PDF · \(r.pdfPages ?? 0) pages"))
        }
        for n in data.notes.filter({ $0.courseID == course }).sorted(by: { $0.createdAt > $1.createdAt }) {
            out.append((.note(n.id), n.title.isEmpty ? "Untitled note" : n.title, n.createdAt.formatted(date: .abbreviated, time: .omitted)))
        }
        return out
    }

    /// Passages of about 1,500 characters — small enough to pick the relevant few, large enough
    /// to hold a derivation together.
    @MainActor
    static func passages(_ source: StudySource, in data: AppData) -> [StudyPassage] {
        func split(_ title: String, _ locator: String, _ text: String) -> [StudyPassage] {
            let parts = LectureNotes.chunks(text, maxChars: 1_500)
            return parts.enumerated().map { i, t in
                StudyPassage(title: title, locator: parts.count > 1 && locator.isEmpty ? "part \(i + 1)" : locator, text: t)
            }
        }
        switch source {
        case .note(let id):
            guard let n = data.notes.first(where: { $0.id == id }) else { return [] }
            return split(n.title.isEmpty ? "Untitled note" : n.title, "", n.body)
        case .reading(let id):
            guard let r = data.reading.first(where: { $0.id == id }) else { return [] }
            return BookText.chunks(id).flatMap { split(r.title, "p. \($0.page)", $0.text) }
        case .syllabus(let courseID):
            guard let s = data.courses.first(where: { $0.id == courseID })?.syllabus else { return [] }
            return split("Syllabus", "", SyllabusStore.text(s))
        case .file(let id):
            guard let f = data.studyFiles?.first(where: { $0.id == id }),
                  let raw = try? Data(contentsOf: unitsURL(id)),
                  let units = try? JSONDecoder().decode([Unit].self, from: raw) else { return [] }
            return units.flatMap { split(f.name, $0.locator, $0.text) }
        }
    }

    /// Everything a course has, as passages — what lecture notes and completions fill in from.
    @MainActor
    static func coursePassages(_ course: UUID?, in data: AppData, excludingNote: UUID? = nil) -> [StudyPassage] {
        guard course != nil else { return [] }
        return sources(course: course, in: data).map(\.source)
            .filter { if case .note(let id) = $0 { return id != excludingNote }; return true }
            .flatMap { passages($0, in: data) }
    }

    /// The passages written out for a prompt, each under its citation.
    static func block(_ passages: [StudyPassage]) -> String {
        passages.map { "[\($0.cite)]\n\($0.text)" }.joined(separator: "\n\n")
    }

    /// Passages packed into prompt-sized groups, in order. A group never splits a passage.
    static func groups(_ passages: [StudyPassage], maxChars: Int) -> [[StudyPassage]] {
        var out: [[StudyPassage]] = [], cur: [StudyPassage] = [], size = 0
        for p in passages {
            let n = p.text.count + p.cite.count + 4
            if !cur.isEmpty, size + n > maxChars { out.append(cur); cur = []; size = 0 }
            cur.append(p); size += n
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// `count` groups spread evenly across the material — so ten questions come from the whole
    /// course, not the first ten pages of it.
    static func spread<T>(_ items: [T], count: Int) -> [T] {
        guard items.count > count, count > 0 else { return items }
        return (0..<count).map { items[$0 * items.count / count] }
    }
}

// MARK: - Retrieval

/// Finding the passages that answer a question: BM25 over words, then the leading candidates
/// re-ranked by meaning with Apple's on-device contextual embedding, so a question phrased
/// differently from the textbook can still find the right page. Nothing to index ahead of
/// time — a course's material is scored when asked.
///
/// Measured before choosing: `NLEmbedding.sentenceEmbedding` ranked "why is there no field in
/// a metal" closer to a page on potential than to the one on conductors. Mean-pooled
/// `NLContextualEmbedding` ranks it right, but by 0.85 against 0.84 — so the similarities are
/// spread across the candidates before being added to the keyword score, or they'd never move it.
enum StudyIndex {
    private static let stop: Set<String> = ["the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "is", "are",
        "was", "were", "be", "it", "this", "that", "with", "as", "by", "at", "from", "what", "how", "why", "which",
        "do", "does", "can", "i", "you", "we", "they", "my", "me", "if", "so", "not", "no", "about", "into", "than"]

    static func tokens(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).compactMap { w in
            var t = String(w)
            guard t.count > 1, !stop.contains(t) else { return nil }
            if t.count > 4, t.hasSuffix("ies") { t = String(t.dropLast(3)) + "y" }
            else if t.count > 3, t.hasSuffix("s"), !t.hasSuffix("ss") { t.removeLast() }
            return t
        }
    }

    /// The best matches that fit in `chars`, best first — as much of the material as the engine
    /// can take, rather than a fixed handful.
    static func fitting(_ query: String, in passages: [StudyPassage], chars: Int) -> [StudyPassage] {
        var used = 0
        return search(query, in: passages, k: 40).filter { p in
            guard used + p.text.count <= chars else { return false }
            used += p.text.count + p.cite.count + 4
            return true
        }
    }

    static func search(_ query: String, in passages: [StudyPassage], k: Int = 5) -> [StudyPassage] {
        guard !passages.isEmpty else { return [] }
        let q = Set(tokens(query))
        let docs = passages.map { tokens($0.text + " " + $0.title) }
        let avg = Double(docs.map(\.count).reduce(0, +)) / Double(max(1, docs.count))
        var df: [String: Int] = [:]
        for d in docs { for t in Set(d) where q.contains(t) { df[t, default: 0] += 1 } }
        let n = Double(docs.count)
        let bm25: [Double] = docs.map { d in
            var tf: [String: Int] = [:]
            for t in d where q.contains(t) { tf[t, default: 0] += 1 }
            return tf.reduce(0) { sum, e in
                let idf = log(1 + (n - Double(df[e.key] ?? 0) + 0.5) / (Double(df[e.key] ?? 0) + 0.5))
                let f = Double(e.value)
                return sum + idf * f * 2.2 / (f + 1.2 * (0.25 + 0.75 * Double(d.count) / max(1, avg)))
            }
        }
        // Candidates: the keyword leaders — or, when no word matches at all, every passage of a
        // small course (the embedding alone decides).
        var cand = bm25.indices.filter { bm25[$0] > 0 }.sorted { bm25[$0] > bm25[$1] }.prefix(40).map { $0 }
        if cand.isEmpty && passages.count <= 120 { cand = Array(passages.indices) }
        guard !cand.isEmpty else { return [] }

        let top = bm25.max() ?? 1
        var score: [Int: Double] = [:]
        for i in cand { score[i] = top > 0 ? bm25[i] / top : 0 }
        if cand.count > 1, let qv = vector(query) {
            let sims = cand.map { i in vector(passages[i].text).map { cosine(qv, $0) } }
            let known = sims.compactMap { $0 }
            if let lo = known.min(), let hi = known.max(), hi > lo {
                for (i, s) in zip(cand, sims) { if let s { score[i, default: 0] += (s - lo) / (hi - lo) } }
            }
        }
        return cand.sorted { score[$0, default: 0] > score[$1, default: 0] }.prefix(k).map { passages[$0] }
    }

    /// nil where the language assets aren't on this Mac — keywords alone then.
    private static let contextual: NLContextualEmbedding? = {
        guard let c = NLContextualEmbedding(language: .english), c.hasAvailableAssets, (try? c.load()) != nil else { return nil }
        return c
    }()

    /// The mean of the token vectors, over the first 600 characters (~8 ms a passage).
    static func vector(_ s: String) -> [Double]? {
        guard let c = contextual else { return nil }
        let text = String(s.prefix(600))
        guard let r = try? c.embeddingResult(for: text, language: .english) else { return nil }
        var sum = [Double](repeating: 0, count: c.dimension), n = 0
        r.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { v, _ in
            for i in 0..<min(v.count, sum.count) { sum[i] += v[i] }
            n += 1; return true
        }
        return n > 0 ? sum.map { $0 / Double(n) } : nil
    }

    private static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<min(a.count, b.count) { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    }
}
