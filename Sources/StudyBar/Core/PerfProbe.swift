import Foundation

/// `StudyBar --perf-notes` — times the note-rendering path against the real store.
///
/// Written because a note in this store says "Lag when open notes while using Voice note
/// module" and guessing at a stall is how you end up optimizing the wrong thing. It measures
/// what opening a note actually costs: the detection pass, the markdown conversion, and the
/// KaTeX page build — the last of which inlines the whole KaTeX bundle (CSS, JS and twenty
/// woff2 fonts as base64) into a fresh String on every SwiftUI render of the reading view.
@MainActor
enum PerfProbe {
    static func run(state: AppState) -> Int32 {
        let notes = state.data.notes
            .sorted { $0.body.count > $1.body.count }
            .prefix(5)
        guard !notes.isEmpty else { print("No notes in the store."); return 0 }

        func ms(_ block: () -> Void) -> Double {
            let t0 = DispatchTime.now().uptimeNanoseconds
            block()
            return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        }

        print("KaTeX prelude inlined per page: \(KatexAssets.prelude.count / 1024) KB")
        print("")
        func pad(_ s: String, _ n: Int) -> String {
            s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
        }
        func rpad(_ s: String, _ n: Int) -> String {
            s.count >= n ? s : String(repeating: " ", count: n - s.count) + s
        }
        print(pad("note", 34) + rpad("chars", 8) + rpad("detect", 10) + rpad("convert", 10)
              + rpad("page", 10) + rpad("pageKB", 9))

        for n in notes {
            let title = (n.title.isEmpty ? "Untitled" : n.title).prefix(32)
            var hasMath = false
            let detect = ms { hasMath = MathMarkdown.hasMath(n.body) || MathMarkdown.hasTable(n.body) }
            var page = ""
            let convert = ms { _ = MathSupport.normalized(n.body) }
            let build = ms { page = MathMarkdown.bodyHTML(n.body) }
            print(pad(String(title), 34)
                  + rpad("\(n.body.count)", 8)
                  + rpad(String(format: "%.1fms", detect), 10)
                  + rpad(String(format: "%.1fms", convert), 10)
                  + rpad(String(format: "%.1fms", build), 10)
                  + rpad("\(page.count / 1024)KB", 9))
            if !hasMath { print("    (plain text — renders natively, no web view)") }
        }

        // The reading view rebuilds this string inside `body`, so the cost above is paid on
        // every re-render, not once per note.
        let biggest = notes[notes.startIndex]
        var total = 0.0
        for _ in 0..<10 { total += ms { _ = MathMarkdown.bodyHTML(biggest.body) } }
        print("")
        print(String(format: "10 re-renders of the largest note: %.0fms (%.2fms each)", total, total / 10))
        print("(the KaTeX shell is now loaded once per web view, not per note)")
        return 0
    }
}
