import Foundation

/// The words a course actually uses, for speech recognition to expect: the course's own name
/// and code, the slide titles of this lecture's deck, then every bold term and heading already
/// written in its notes (newest first), its `term :: definition` lines, its flashcards' terms,
/// its syllabus objectives' key words and its other decks' slide titles — and, before all of
/// those, any word the student fixed in a transcript (`TermFix.learn`). Read, not guessed —
/// these are where a lecture's jargon is already spelled correctly. "Farads" came out as
/// "ferrets" when only bold words and headings counted, because no note had it in bold.
enum CourseVocabulary {
    static func terms(course: Course, data: AppData, slides: StudyFile? = nil, limit: Int = 100) -> [String] {
        var seen = Set<String>(), out: [String] = []
        func add(_ raw: Substring) {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard t.count >= 3, t.count <= 40, t.split(separator: " ").count <= 4,
                  !t.contains("$"), seen.insert(t.lowercased()).inserted else { return }
            out.append(t)
        }
        /// A slide's title is its first line.
        func titles(_ f: StudyFile) {
            for u in StudyMaterial.units(f) {
                if let first = u.text.split(whereSeparator: \.isNewline).first { add(first) }
            }
        }
        add(Substring(course.name)); add(Substring(course.code))
        for w in course.words ?? [] { add(Substring(w)) }          // ones the student corrected: never miss them again
        if let slides { titles(slides) }
        let notes = data.notes.filter { $0.courseID == course.id }.sorted { $0.createdAt > $1.createdAt }
        for note in notes {
            for m in note.body.matches(of: /\*\*([^*\n]+)\*\*/) { add(m.output.1) }
            for m in note.body.matches(of: /^#{1,3}\s+(.+)$/.anchorsMatchLineEndings()) { add(m.output.1) }
            for c in NoteCards.parse(note.body) { add(Substring(c.front)) }
            if out.count >= limit { return Array(out.prefix(limit)) }
        }
        let decks = Set(data.decks.filter { $0.courseID == course.id }.map(\.id))
        for c in data.flashcards where decks.contains(c.deckID) && !c.front.contains("?") && !c.front.contains("{{") {
            add(Substring(c.front))
        }
        for o in course.syllabus?.objectives ?? [] { o.keys.forEach { add(Substring($0)) } }
        for f in (data.studyFiles ?? []) where f.courseID == course.id && f.id != slides?.id { titles(f) }
        return Array(out.prefix(limit))
    }

    /// Ready the recorder for a lecture in `course`: its name for Whisper, its terms for Apple
    /// Speech and SpeechAnalyzer. Voice does this as its course changes; a recording started
    /// from the menu bar or the shortcut, with Voice never opened, does it here.
    @MainActor
    static func prepare(_ voice: VoiceService, course: Course?, data: AppData) {
        guard let c = course else { voice.vocabPrompt = nil; voice.vocabulary = []; return }
        voice.vocabPrompt = "Course: \(c.name)\(c.code.isEmpty ? "" : " (\(c.code))")."
        voice.vocabulary = terms(course: c, data: data, slides: voice.slides)
    }
}
