import Foundation

/// Which course a piece of writing belongs to, when the timetable can't say.
///
/// A lecture recorded during class is tagged from the schedule — that is a fact, not a guess.
/// This is the other case: revising at 10pm, reading something over, catching a thought. The
/// model gets the course list and the first part of the note and answers with one code or
/// NONE; anything else it says is discarded rather than interpreted.
enum CourseGuess {
    /// Enough of the note to recognize the subject, short enough to stay cheap.
    static let sampleChars = 1_200

    static func system(codes: [String]) -> String {
        """
        You label a student's note with the course it belongs to.

        The courses are: \(codes.joined(separator: ", ")).

        Reply with EXACTLY one course code from that list, or the single word NONE when the \
        note does not clearly belong to any of them. No explanation, no punctuation, no other \
        words. A wrong label is worse than NONE: the student can file it themselves in a \
        second, but a note filed under the wrong course is one they will look for and not find.
        """
    }

    /// Map the reply back to a course. Only an exact code match counts.
    static func match(_ reply: String, courses: [(id: UUID, code: String)]) -> UUID? {
        let answer = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,:;\"'`"))
        guard !answer.isEmpty, answer.caseInsensitiveCompare("NONE") != .orderedSame else { return nil }
        // A model that returns a sentence anyway ("This is PHY2049.") still names the code.
        return courses.first { c in
            answer.caseInsensitiveCompare(c.code) == .orderedSame
                || answer.range(of: "\\b\(NSRegularExpression.escapedPattern(for: c.code))\\b",
                                options: [.regularExpression, .caseInsensitive]) != nil
        }?.id
    }
}
