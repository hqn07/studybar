import Foundation

/// A parsed release from the bundled CHANGELOG.md — powers Settings ▸ About ▸ Release Notes,
/// so the in-app history and the repo changelog never drift.
struct ChangelogRelease: Identifiable {
    let id = UUID()
    let version: String     // "1.8.0"
    let date: String        // "2026-09-02", or "" if none
    let notes: [String]     // bullet lines, inline markdown preserved
}

enum Changelog {
    /// Newest first; the empty "[Unreleased]" heading is skipped.
    static func releases() -> [ChangelogRelease] {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        var out: [ChangelogRelease] = []
        var version = "", date = "", notes: [String] = []
        func flush() {
            if !version.isEmpty, version.lowercased() != "unreleased", !notes.isEmpty {
                out.append(ChangelogRelease(version: version, date: date, notes: notes))
            }
            notes = []
        }
        for raw in text.components(separatedBy: "\n") {
            if raw.hasPrefix("## ") {
                flush()
                let header = raw.dropFirst(3)
                if let lb = header.firstIndex(of: "["), let rb = header.firstIndex(of: "]") {
                    version = String(header[header.index(after: lb)..<rb])
                } else {
                    version = String(header).trimmingCharacters(in: .whitespaces)
                }
                if let dash = header.range(of: "—") {
                    date = String(header[dash.upperBound...]).trimmingCharacters(in: .whitespaces)
                } else { date = "" }
            } else if raw.hasPrefix("- ") {
                notes.append(String(raw.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            }
        }
        flush()
        return out
    }
}
