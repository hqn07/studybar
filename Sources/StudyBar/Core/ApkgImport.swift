import Foundation
import SQLite3

/// Import an Anki `.apkg` deck file (a ZIP of a SQLite collection + media).
///
/// We read the notes' fields, convert Anki cloze + strip HTML via `AnkiText`, and
/// hand back `AnkiText.Card`s — media is intentionally dropped (StudyBar cards are
/// plain text). Legacy plain-SQLite collections (`collection.anki2`/`.anki21`) are
/// supported; the newest zstd-compressed `.anki21b` is not (Anki can re-export in
/// the older format).
enum ApkgImport {
    struct Result { var cards: [AnkiText.Card] = []; var error: String? = nil }

    static func read(_ url: URL) -> Result {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("apkg-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }

        // Unzip (app is not sandboxed; /usr/bin/unzip is always present on macOS).
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            p.arguments = ["-o", "-q", url.path, "-d", tmp.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { return Result(error: "Couldn't unzip the .apkg file.") }
        } catch {
            return Result(error: "Couldn't read the .apkg file.")
        }

        // Prefer .anki21 (newer plain SQLite) then .anki2. Reject zstd .anki21b.
        let anki21 = tmp.appendingPathComponent("collection.anki21")
        let anki2 = tmp.appendingPathComponent("collection.anki2")
        let dbURL: URL
        if fm.fileExists(atPath: anki21.path) { dbURL = anki21 }
        else if fm.fileExists(atPath: anki2.path) { dbURL = anki2 }
        else if fm.fileExists(atPath: tmp.appendingPathComponent("collection.anki21b").path) {
            return Result(error: "This deck uses Anki's newest format. In Anki, re-export with “Support older Anki versions” checked.")
        } else {
            return Result(error: "No Anki collection found in that file.")
        }

        return readCollection(dbURL)
    }

    // MARK: - SQLite

    private static func readCollection(_ dbURL: URL) -> Result {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return Result(error: "Couldn't open the Anki collection.")
        }
        defer { sqlite3_close(db) }

        let clozeModels = clozeModelIDs(db)   // model ids whose type == 1 (cloze)

        var cards: [AnkiText.Card] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT mid, flds, tags FROM notes", -1, &stmt, nil) == SQLITE_OK else {
            return Result(error: "Couldn't read notes from the collection.")
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let mid = sqlite3_column_int64(stmt, 0)
            let flds = column(stmt, 1)
            let tagsRaw = column(stmt, 2)

            let fields = flds.components(separatedBy: "\u{1f}")
            guard let first = fields.first else { continue }
            let isCloze = clozeModels.contains(mid)

            let front = AnkiText.normalizeField(first, html: true)
            guard !front.isEmpty else { continue }
            let back = isCloze ? "" : (fields.count > 1 ? AnkiText.normalizeField(fields[1], html: true) : "")
            let tags = tagsRaw.split(whereSeparator: { $0 == " " }).map(String.init).filter { !$0.isEmpty }

            cards.append(AnkiText.Card(front: front, back: back, tags: tags))
        }

        if cards.isEmpty { return Result(error: "No cards found in that deck.") }
        return Result(cards: cards)
    }

    /// Parse `col.models` (JSON: mid → {type,…}) and return the cloze model ids (type 1).
    private static func clozeModelIDs(_ db: OpaquePointer) -> Set<Int64> {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT models FROM col LIMIT 1", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return [] }
        let json = column(stmt, 0)
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var out: Set<Int64> = []
        for (key, value) in obj {
            if let m = value as? [String: Any], (m["type"] as? Int) == 1, let id = Int64(key) { out.insert(id) }
        }
        return out
    }

    private static func column(_ stmt: OpaquePointer?, _ i: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: c)
    }
}
