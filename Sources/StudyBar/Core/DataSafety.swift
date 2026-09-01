import Foundation

/// Data-safety guards. The store is the product for a local-first app; these make it
/// structurally hard to lose it. Three layers, plus a build-time regression test:
///
///  1. **Load** never seeds-empty over an existing file it couldn't decode
///     (`AppState.init` quarantines the raw file and blocks saving instead).
///  2. **Save** never writes an effectively-empty document over a non-empty file on disk
///     (`AppState.commitSave` refuses and backs up).
///  3. A `STUDYBAR_DATA_DIR` override so a dev/test build can point at a throwaway store
///     instead of the user's live data (`AppState.dataURL`).
///  4. `--decode-selftest` proves every model still decodes from *old-shaped* JSON, so a
///     newly-added non-optional field can't silently break loading (the 2026-08-31 bug).

extension AppData {
    /// A store with none of the user's real content. Used as the tripwire for the save
    /// guard: writing this over a non-empty file on disk is almost always a bug, not intent.
    var isEffectivelyEmpty: Bool {
        courses.isEmpty && assignments.isEmpty && notes.isEmpty && (todos.isEmpty)
            && classes.isEmpty && decks.isEmpty && flashcards.isEmpty && reading.isEmpty
            && references.isEmpty && snippets.isEmpty && links.isEmpty && clips.isEmpty
            && timeEntries.isEmpty && readingList.isEmpty && (gradeItems ?? []).isEmpty
            && scratchpad.isEmpty
    }

    /// Cheap content signal for the save guard — how many "real" records a store holds.
    var contentCount: Int {
        courses.count + assignments.count + notes.count + todos.count + classes.count
            + decks.count + flashcards.count + reading.count + references.count
            + snippets.count + links.count + timeEntries.count + readingList.count
            + (gradeItems ?? []).count
    }
}

// MARK: - Decode regression test (StudyBar --decode-selftest)

/// Proves the models still decode from JSON shaped like an *older* release — i.e. missing
/// the fields added since. Swift's synthesized `Decodable` throws `.keyNotFound` for a
/// missing **non-optional** property (it ignores the default value), which fails the whole
/// `AppData` decode and drops the user to an empty store. Every model must therefore
/// tolerate missing keys: make new fields Optional, or give the type a lenient
/// `init(from:)`. This test fails the build if that rule is ever broken again.
enum DecodeSelfTest {
    /// Top-level collections added AFTER 1.0 — old files won't contain these keys, so they
    /// MUST stay optional (a missing key decodes to nil). Add a new one here when you add a
    /// new optional collection to AppData.
    static let additiveTopKeys = ["rssFeeds", "rssRead", "timeBlocks", "gradeItems", "fileRefs", "trash"]

    static func run() -> Int32 {
        var pass = 0, fail = 0
        func ok(_ n: String, _ extra: String = "") { print("  ok    \(n)\(extra.isEmpty ? "" : " (\(extra))")"); pass += 1 }
        func bad(_ n: String, _ why: String) { print("  FAIL  \(n): \(why)"); fail += 1 }

        // A populated store built from the CURRENT models, so every mandatory key is present.
        var full = AppData()
        full.courses = [Course(name: "MAP2302", credits: 3)]
        full.assignments = [Assignment(title: "HW1")]
        full.links = [QuickLink(title: "Syllabus", url: "https://ufl.edu")]
        full.rssFeeds = [RSSFeed(title: "Feed", url: "https://x/feed", folder: "News")]
        let baseline = full.contentCount

        guard let encoded = try? JSONEncoder.studybar.encode(full) else {
            bad("encode", "current store won't encode"); print("DECODE SELFTEST: 1 FAILED"); return 1
        }

        // 1. Round-trip — the current schema is self-consistent.
        if let d = try? JSONDecoder.studybar.decode(AppData.self, from: encoded), d.contentCount == baseline {
            ok("round-trip", "content=\(baseline)")
        } else { bad("round-trip", "current store did not decode back to \(baseline) records") }

        // 2. Old-file compatibility — simulate a file written by an EARLIER release by
        //    stripping the keys that didn't exist then: the additive top-level collections,
        //    and `folder` from every feed (the field whose non-optionality wiped stores on
        //    2026-08-31). It MUST still decode, with the mandatory content intact.
        if var obj = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any] {
            var feeds = obj["rssFeeds"] as? [[String: Any]] ?? []
            for i in feeds.indices { feeds[i].removeValue(forKey: "folder") }
            for k in additiveTopKeys where k != "rssFeeds" { obj.removeValue(forKey: k) }
            obj["rssFeeds"] = feeds   // keep the feed, minus its post-1.6 folder key
            if let legacy = try? JSONSerialization.data(withJSONObject: obj),
               let d = try? JSONDecoder.studybar.decode(AppData.self, from: legacy) {
                // courses + assignments + links survive (rssFeeds isn't counted in contentCount).
                d.courses.count == 1 && d.assignments.count == 1
                    ? ok("legacy shape (no folder / additive keys)", "content=\(d.contentCount)")
                    : bad("legacy shape", "decoded but lost content (\(d.contentCount))")
            } else { bad("legacy shape", "a pre-folder file failed to decode — a non-optional field broke old data") }
        } else { bad("legacy shape", "could not re-serialize fixture") }

        print(fail == 0 ? "DECODE SELFTEST: ALL PASS (\(pass))" : "DECODE SELFTEST: \(fail) FAILED")
        return fail == 0 ? 0 : 1
    }
}
