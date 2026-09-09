import Foundation

/// Quotation marks in an answer are a factual claim: *these words are in your note*. Models
/// break that claim — qwen2.5:7b produced between zero and two invented quotations per eval
/// run at the same temperature, and one of them was a whole sentence about Gauss's law that
/// appeared in neither attached note.
///
/// Asking the prompt to stop helped and did not settle it, so this settles it: after the
/// answer arrives, every quoted span is looked for in the notes that were actually sent. A
/// span that isn't there loses its quotation marks — the sentence survives as the paraphrase
/// it always was, and the reader is told how many were downgraded.
enum QuoteCheck {

    struct Result: Equatable {
        let text: String
        /// Spans that claimed to be quotations and weren't.
        let unverified: [String]
        var count: Int { unverified.count }
    }

    /// Short spans are idiom, not citation ("the note calls it a \"cutting\""), and a term of
    /// art matching loosely would produce false alarms in both directions.
    static let minimumSpan = 25

    /// Comparison is whitespace- and case-insensitive: models re-wrap lines and fix
    /// capitalization inside a quotation without meaning to change it, and neither makes the
    /// quotation invented.
    static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "[\\s\\u00A0]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "[\\u2018\\u2019\\u201C\\u201D]", with: "'", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let quoted = try! NSRegularExpression(
        pattern: "[\"\\u201C]([^\"\\u201C\\u201D\\n]{\(minimumSpan),})[\"\\u201D]")

    static func verify(_ answer: String, against sources: [String]) -> Result {
        let ns = answer as NSString
        let matches = quoted.matches(in: answer, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return Result(text: answer, unverified: []) }

        let haystack = sources.map(normalize).joined(separator: "\n")
        var out = ""
        var cursor = 0
        var bad: [String] = []
        for m in matches {
            let inner = ns.substring(with: m.range(at: 1))
            // Trailing punctuation and an ellipsis are the quoter's, not the source's.
            let probe = normalize(inner)
                .trimmingCharacters(in: CharacterSet(charactersIn: " .,;:…"))
                .replacingOccurrences(of: "…", with: "")
            let present = probe.isEmpty || haystack.contains(probe)
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            out += present ? ns.substring(with: m.range) : inner   // keep the words, drop the claim
            if !present { bad.append(inner) }
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return Result(text: out, unverified: bad)
    }

    /// Shown under an answer that had quotations downgraded.
    static func notice(_ n: Int) -> String {
        n == 1 ? "1 quotation wasn't in your notes — shown without quote marks."
               : "\(n) quotations weren't in your notes — shown without quote marks."
    }
}

// MARK: - Self-test (StudyBar --quote-selftest)

enum QuoteSelfTest {
    static func run() -> Int32 {
        var pass = 0, fail = 0
        func check(_ name: String, _ got: Bool) {
            got ? { print("  ok   \(name)"); pass += 1 }() : { print("  FAIL \(name)"); fail += 1 }()
        }

        let note = """
        Gauss's law relates the electric flux through a closed surface to the charge enclosed.
        Constant saturation causes rot, and perlite provides aeration so roots do not suffocate.
        """

        // A real quotation keeps its marks.
        let real = QuoteCheck.verify("The note says \"Constant saturation causes rot, and perlite provides aeration\" here.", against: [note])
        check("verified quotation keeps its marks", real.text.contains("\"Constant saturation causes rot") && real.count == 0)

        // The failure this exists for: a fluent sentence that is nowhere in the note.
        let fake = QuoteCheck.verify("As my note puts it, \"In Part I we established the general form of Gauss's Law\" — so part II builds on it.", against: [note])
        check("invented quotation loses its marks", !fake.text.contains("\"In Part I") && fake.count == 1)
        check("the words survive", fake.text.contains("In Part I we established the general form"))

        // Re-wrapped and re-capitalized quotations are still quotations.
        let rewrapped = QuoteCheck.verify("It says \"constant saturation causes rot,\nand perlite provides aeration\".", against: [note])
        check("whitespace and case differences are tolerated", rewrapped.count == 0)

        // Short spans are idiom, not citation.
        let short = QuoteCheck.verify("The note calls it \"aeration\" throughout.", against: [note])
        check("short spans are left alone", short.count == 0)

        // Several notes attached: any of them counts as the source.
        let multi = QuoteCheck.verify("One note says \"Gauss's law relates the electric flux through a closed surface\".",
                                      against: ["something else entirely", note])
        check("checks every attached note", multi.count == 0)

        let none = QuoteCheck.verify("No quotations at all, just prose about flux and rot.", against: [note])
        check("prose is untouched", none.text.contains("just prose") && none.count == 0)

        check("notice reads naturally", QuoteCheck.notice(1).hasPrefix("1 quotation wasn't")
                                        && QuoteCheck.notice(2).hasPrefix("2 quotations weren't"))

        print(fail == 0 ? "QUOTE SELFTEST: ALL PASS (\(pass))" : "QUOTE SELFTEST: \(fail) FAILED")
        return fail == 0 ? 0 : 1
    }
}
