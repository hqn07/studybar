import AppKit

// MARK: - Board photos (benchmark 1.10)

/// Photos of the board taken while recording. Each is a `📷 Board photo N` line in the transcript
/// at the moment it was taken; the study notes keep the line where it belongs, and a note shows
/// it as the photo. The files sit beside the recording, listed in its timeline.
enum BoardPhotos {
    static func marker(_ n: Int) -> String { "📷 Board photo \(n)" }

    /// The photo a line shows: `📷 Board photo 2` as written, or as notes keep it — bulleted,
    /// bold, with a caption after.
    static func number(inLine line: String) -> Int? {
        guard let m = line.firstMatch(of: /^[\s\-*•>_]*📷\s*[*_]*\s*[Bb]oard photo\s+(\d+)/) else { return nil }
        return Int(m.output.1)
    }

    /// Every photo with its line: one the notes left out goes at the end, under its own heading,
    /// so no photo is lost to a rewrite.
    static func ensured(_ text: String, count: Int) -> String {
        guard count > 0 else { return text }
        let present = Set(text.components(separatedBy: "\n").compactMap(number(inLine:)))
        let missing = (1...count).filter { !present.contains($0) }
        guard !missing.isEmpty else { return text }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n### Board photos\n" + missing.map(marker).joined(separator: "\n\n")
    }

    enum Piece: Equatable { case text(String), photo(Int, caption: String) }

    /// The text cut at its photo lines, to show each photo in its place.
    static func split(_ text: String) -> [Piece] {
        var out: [Piece] = [], buffer: [String] = []
        func flush() {
            let t = buffer.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !t.isEmpty { out.append(.text(t)) }
            buffer = []
        }
        for line in text.components(separatedBy: "\n") {
            if let n = number(inLine: line) {
                flush()
                // What the notes wrote after the photo's name, if anything: "— the circuit for Q3".
                let rest = line.replacing(/^[\s\-*•>_]*📷\s*[*_]*\s*[Bb]oard photo\s+\d+[*_]*\s*[—–:\-]?\s*/, with: "")
                out.append(.photo(n, caption: rest.trimmingCharacters(in: CharacterSet(charactersIn: "*_ "))))
            } else {
                buffer.append(line)
            }
        }
        flush()
        return out
    }

    /// Photos in no kept timeline, a week after they were taken — a deleted lecture's, or a session
    /// a crash left and nobody recovered. Pure, for the self-test; see `VoiceService.trashOrphans`.
    static func orphans(_ files: [(name: String, modified: Date)], keeping: Set<String>, now: Date = .now) -> [String] {
        files.filter { $0.name.hasPrefix("photo-") && $0.name.hasSuffix(".jpg") && !keeping.contains($0.name)
            && now.timeIntervalSince($0.modified) > 7 * 86_400 }.map(\.name)
    }

    @MainActor static func url(_ photo: LectureTimeline.Photo) -> URL { VoiceService.recordingsDir.appendingPathComponent(photo.file) }

    private static let cache = NSCache<NSString, NSImage>()
    @MainActor static func image(_ photo: LectureTimeline.Photo) -> NSImage? {
        if let hit = cache.object(forKey: photo.file as NSString) { return hit }
        guard let img = NSImage(contentsOf: url(photo)) else { return nil }
        cache.setObject(img, forKey: photo.file as NSString)
        return img
    }

    static func clock(_ t: Double) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// A note's photos, from its recording's timeline.
    @MainActor static func photos(of note: Note) -> [LectureTimeline.Photo] {
        guard let a = note.audioPath else { return [] }
        return LectureTimeline.load(beside: VoiceService.recordingsDir.appendingPathComponent(a))?.photos ?? []
    }
}

// MARK: - Self-test (part of StudyBar --take-selftest)

enum BoardPhotosSelfTest {
    static func run(_ check: (String, Bool, String) -> Void) {
        check("a photo's line reads back as its number", BoardPhotos.number(inLine: BoardPhotos.marker(3)) == 3, "")
        check("…as the notes keep it, bulleted or bold", BoardPhotos.number(inLine: "- **📷 Board photo 2** — the RC circuit") == 2
              && BoardPhotos.number(inLine: "  * 📷 board photo 12") == 12, "")
        check("…and not mid-sentence", BoardPhotos.number(inLine: "See 📷 Board photo 2 above") == nil
              && BoardPhotos.number(inLine: "## Capacitors") == nil, "")
        let notes = "## Capacitors\n- C = Q/V\n- 📷 Board photo 2 — the plates\n## Energy\n- U = ½CV²"
        let kept = BoardPhotos.ensured(notes, count: 3)
        check("a photo the notes dropped is added at the end", kept.hasSuffix("### Board photos\n📷 Board photo 1\n\n📷 Board photo 3")
              && kept.components(separatedBy: "Board photo 2").count == 2, kept)
        check("nothing added when every photo is there, or there are none", BoardPhotos.ensured("x\n📷 Board photo 1", count: 1) == "x\n📷 Board photo 1"
              && BoardPhotos.ensured(notes, count: 0) == notes, "")
        let pieces = BoardPhotos.split(notes)
        check("the text cut at each photo, its caption kept", pieces == [.text("## Capacitors\n- C = Q/V"), .photo(2, caption: "the plates"),
                                                                         .text("## Energy\n- U = ½CV²")], "\(pieces)")
        check("a bare photo line has no caption", BoardPhotos.split("📷 Board photo 1") == [.photo(1, caption: "")], "")
        let now = Date()
        let files: [(name: String, modified: Date)] = [("photo-a.jpg", now.addingTimeInterval(-8 * 86_400)), ("photo-b.jpg", now.addingTimeInterval(-8 * 86_400)),
                                                       ("photo-c.jpg", now), ("A.m4a", now.addingTimeInterval(-9 * 86_400))]
        check("only old photos no timeline lists go", BoardPhotos.orphans(files, keeping: ["photo-b.jpg"], now: now) == ["photo-a.jpg"], "")
    }
}
