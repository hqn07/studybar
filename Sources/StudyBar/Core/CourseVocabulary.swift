import Foundation

/// The words a course actually uses, for speech recognition to expect: the course's own name
/// and code, plus every bold term and heading already written in its notes. Read, not guessed —
/// the notes are where a lecture's jargon is already spelled correctly.
enum CourseVocabulary {
    static func terms(course: Course, notes: [Note], limit: Int = 100) -> [String] {
        var seen = Set<String>(), out: [String] = []
        func add(_ raw: Substring) {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard t.count >= 3, t.count <= 40, t.split(separator: " ").count <= 4,
                  !t.contains("$"), seen.insert(t.lowercased()).inserted else { return }
            out.append(t)
        }
        add(Substring(course.name)); add(Substring(course.code))
        for note in notes where note.courseID == course.id {
            for m in note.body.matches(of: /\*\*([^*\n]+)\*\*/) { add(m.output.1) }
            for m in note.body.matches(of: /^#{1,3}\s+(.+)$/.anchorsMatchLineEndings()) { add(m.output.1) }
            if out.count >= limit { break }
        }
        return Array(out.prefix(limit))
    }
}
