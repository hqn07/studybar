import Foundation

/// Earlier versions of each note, so an AI rewrite or a bad edit can be undone days later.
///
/// Recorded where every note change passes — the save — rather than in each editor, AI job or
/// sync. Typing keeps a version at most every ten minutes; a large change (an AI rewrite, a
/// restore, a paste over everything) keeps the one before it at once. Files live beside the
/// app's other local data (History/<note>/), not in the synced store: history is per Mac.
@MainActor
enum NoteHistory {
    struct Version: Codable, Identifiable, Equatable {
        var id: Date { at }
        let at: Date
        let title: String
        let body: String
        let rich: Data?
    }

    static let keep = 40
    static let interval: TimeInterval = 600

    static var dir: URL {
        let base = ProcessInfo.processInfo.environment["STUDYBAR_DATA_DIR"].map { URL(fileURLWithPath: $0) } ?? AppState.localDir
        return base.appendingPathComponent("History", isDirectory: true)
    }
    private static func folder(_ id: UUID) -> URL { dir.appendingPathComponent(id.uuidString, isDirectory: true) }

    /// When each note last had a version kept, this session.
    private static var lastKept: [UUID: Date] = [:]

    /// Keep the saved version of any note whose text is about to change.
    // ponytail: writes on the main thread at save; a note with large images costs a few ms, at
    // most once per note per ten minutes. Move off-main if it ever shows up in a profile.
    static func record(before: [Note], after: [Note], now: Date = .now) {
        let old = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for note in after {
            guard let prev = old[note.id], prev.body != note.body || prev.title != note.title,
                  !prev.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let due = lastKept[note.id].map { now.timeIntervalSince($0) >= interval } ?? true
            guard due || isLarge(from: prev.body, to: note.body) else { continue }
            save(Version(at: now, title: prev.title, body: prev.body, rich: prev.rich), of: note.id)
            lastKept[note.id] = now
        }
    }

    /// More than 200 characters, or a fifth of the note, differs between the two.
    static func isLarge(from a: String, to b: String) -> Bool {
        let x = Array(a), y = Array(b)
        var head = 0
        while head < min(x.count, y.count), x[head] == y[head] { head += 1 }
        var tail = 0
        while tail < min(x.count, y.count) - head, x[x.count - 1 - tail] == y[y.count - 1 - tail] { tail += 1 }
        let changed = max(x.count, y.count) - head - tail
        return changed > max(200, x.count / 5)
    }

    static func save(_ v: Version, of id: UUID) {
        let f = folder(id)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        let name = "\(Int(v.at.timeIntervalSince1970 * 1000)).json"
        try? JSONEncoder().encode(v).write(to: f.appendingPathComponent(name), options: .atomic)
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: f.path)) ?? []).sorted(by: >)
        for old in files.dropFirst(keep) { try? FileManager.default.removeItem(at: f.appendingPathComponent(old)) }
    }

    /// Newest first.
    static func versions(of id: UUID) -> [Version] {
        let f = folder(id)
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: f.path)) ?? []).sorted(by: >)
        return files.compactMap { name in
            (try? Data(contentsOf: f.appendingPathComponent(name))).flatMap { try? JSONDecoder().decode(Version.self, from: $0) }
        }
    }

    /// Line by line from `a` to `b`: -1 a line only `a` has, +1 one only `b` has, 0 both.
    static func diff(from a: [String], to b: [String]) -> [(line: String, change: Int)] {
        let d = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for c in d {
            switch c {
            case .remove(let o, _, _): removed.insert(o)
            case .insert(let o, _, _): inserted.insert(o)
            }
        }
        var out: [(String, Int)] = [], i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) { out.append((a[i], -1)); i += 1 }
            else if j < b.count, inserted.contains(j) { out.append((b[j], 1)); j += 1 }
            else if i < a.count, j < b.count { out.append((b[j], 0)); i += 1; j += 1 }
            else { break }
        }
        return out
    }
}

// MARK: - Self-test (STUDYBAR_DATA_DIR=<scratch> StudyBar --history-selftest)

@MainActor
enum NoteHistorySelfTest {
    static func run() -> Int32 {
        var fail = 0
        func check(_ n: String, _ ok: Bool, _ d: String = "") { print("  \(ok ? "ok  " : "FAIL") \(n) \(d)"); if !ok { fail += 1 } }
        guard ProcessInfo.processInfo.environment["STUDYBAR_DATA_DIR"] != nil else { print("Set STUDYBAR_DATA_DIR first"); return 1 }

        let t0 = Date(timeIntervalSince1970: 2_000_000_000)
        var n = Note(title: "Week 3", body: String(repeating: "Flux is field through area. ", count: 20))
        let v1 = n
        n.body += "Gauss."
        NoteHistory.record(before: [v1], after: [n], now: t0)
        check("the first edit keeps the version before it", NoteHistory.versions(of: n.id).first?.body == v1.body)
        var n2 = n; n2.body += " More typing."
        NoteHistory.record(before: [n], after: [n2], now: t0.addingTimeInterval(60))
        check("typing within ten minutes keeps no extra version", NoteHistory.versions(of: n.id).count == 1)
        var rewrite = n2; rewrite.body = "# Gauss's law\n- Completely rewritten by the AI, every line of it, top to bottom."
        NoteHistory.record(before: [n2], after: [rewrite], now: t0.addingTimeInterval(120))
        check("a large change keeps the version before it at once", NoteHistory.versions(of: n.id).first?.body == n2.body,
              "\(NoteHistory.versions(of: n.id).count) versions")
        check("small edits aren't large", !NoteHistory.isLarge(from: n.body, to: n2.body) && NoteHistory.isLarge(from: n2.body, to: rewrite.body))

        let rows = NoteHistory.diff(from: ["a", "b", "c"], to: ["a", "c", "d"])
        check("the diff walks both versions", rows.map { "\($0.change)\($0.line)" } == ["0a", "-1b", "0c", "1d"], "\(rows)")

        for i in 0..<(NoteHistory.keep + 5) {
            NoteHistory.save(.init(at: t0.addingTimeInterval(Double(1000 + i)), title: "t", body: "v\(i)", rich: nil), of: n.id)
        }
        let kept = NoteHistory.versions(of: n.id)
        check("only the newest versions are kept", kept.count == NoteHistory.keep && kept.first?.body == "v\(NoteHistory.keep + 4)")
        try? FileManager.default.removeItem(at: NoteHistory.dir.appendingPathComponent(n.id.uuidString))

        print(fail == 0 ? "HISTORY SELFTEST: ALL PASS" : "HISTORY SELFTEST: \(fail) FAILED")
        return fail == 0 ? 0 : 1
    }
}
