import Foundation

/// The shape of a list in a note, enforced twice: asked for in the prompt, then repaired
/// deterministically on the way in — the same two-step `MathSupport.normalized` uses for LaTeX
/// delimiters, and for the same reason. A 7B model complies with a formatting rule most of the
/// time, and "most" is what put a flat wall of bullets in the store.
///
/// The failure this exists for: a model introduces a list with a bullet that is only a label —
///
///     - Sign of work:
///     - **Positive work**: force and displacement are in the same direction.
///     - **Negative work**: force and displacement are in opposite directions.
///
/// — so the label and the two things it introduces render as three siblings, and the reader has
/// to infer the hierarchy that the colon was supposed to carry.
enum NoteFormat {

    /// Appended to every system prompt whose output lands in a note. Short and imperative:
    /// local models weight a long rule block poorly, and three rules is what this needs.
    static let listRules = """
        Lists:
        - A line that introduces a list ends with a colon and is NOT itself a bullet. Write it \
        as its own line (bold it if it names a term), then the bullets under it.
        - Indent a bullet two spaces when it belongs under the one above it. Never make a \
        sub-point a sibling of the point it belongs to.
        - Every bullet states something — "- **Term** — what it means", never a bare label.
        """

    /// Repair the label-bullet shape: un-bullet the lead-in, bold it, and indent the run of
    /// bullets it introduces so they read as its children.
    ///
    /// Deliberately narrow. It fires only on a short bullet that ends in a colon and is followed
    /// immediately by bullets at the same indent — the one shape that is unambiguously wrong.
    /// Prose ending in a colon, a bullet with content after the colon, and a colon-bullet with
    /// nothing under it are all left exactly as they were. Idempotent: the output contains no
    /// label bullets, so running it twice changes nothing.
    static func tidy(_ md: String) -> String {
        guard md.contains(":") else { return md }
        let lines = md.components(separatedBy: "\n")
        var out: [String] = []
        var i = 0
        while i < lines.count {
            guard let lead = leadIn(lines[i]) else { out.append(lines[i]); i += 1; continue }
            var children: [String] = []
            var j = i + 1
            while j < lines.count, let b = bullet(lines[j]), b.indent == lead.indent {
                children.append(lines[j]); j += 1
            }
            guard !children.isEmpty else {
                // The same label, introducing a table instead of bullets — the shape the
                // repo's own render sample carries. Nothing to indent; it just stops being
                // a one-item list floating above the thing it names.
                if introducesTable(lines, after: i) {
                    if let last = out.last, !last.trimmingCharacters(in: .whitespaces).isEmpty { out.append("") }
                    out.append(leadInLine(lead))
                    i += 1
                    continue
                }
                out.append(lines[i]); i += 1; continue
            }
            // The lead-in stops being a list item, so it needs air above it or it reads as a
            // run-on with whatever preceded it.
            if let last = out.last, !last.trimmingCharacters(in: .whitespaces).isEmpty { out.append("") }
            out.append(leadInLine(lead))
            out.append(contentsOf: children.map { "  " + $0 })
            i = j
        }
        return out.joined(separator: "\n")
    }

    /// The lead-in as a standalone line. Bold, unless the label carries its own emphasis —
    /// wrapping "the **key** idea" in another pair produces markers that close each other in
    /// the wrong order and render as literal asterisks.
    private static func leadInLine(_ lead: (indent: Int, label: String)) -> String {
        let plain = !lead.label.contains("*") && !lead.label.contains("_")
        return String(repeating: " ", count: lead.indent) + (plain ? "**\(lead.label):**" : "\(lead.label):")
    }

    /// Whether the next non-empty line after `index` opens a Markdown table — a row followed
    /// by a `|---|---|` rule. One blank line between is normal; more means the label was
    /// introducing something else.
    private static func introducesTable(_ lines: [String], after index: Int) -> Bool {
        var j = index + 1
        while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty, j <= index + 2 { j += 1 }
        guard j + 1 < lines.count else { return false }
        let row = lines[j].trimmingCharacters(in: .whitespaces)
        let rule = lines[j + 1].trimmingCharacters(in: .whitespaces)
        guard row.hasPrefix("|"), rule.hasPrefix("|"), rule.contains("-") else { return false }
        return rule.allSatisfy { "|-: \t".contains($0) }
    }

    // MARK: - Line shapes

    /// A bullet line: its indent in spaces (a tab counts as two) and the text after the marker.
    /// Checkboxes are not bullets here — `- [ ] Call the TA:` is a task, not a lead-in.
    static func bullet(_ line: String) -> (indent: Int, text: String)? {
        var indent = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == " " || line[idx] == "\t" {
            indent += line[idx] == "\t" ? 2 : 1
            idx = line.index(after: idx)
        }
        guard idx < line.endIndex, "-*•".contains(line[idx]) else { return nil }
        let afterMarker = line.index(after: idx)
        guard afterMarker < line.endIndex, line[afterMarker] == " " else { return nil }
        let text = String(line[afterMarker...]).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        guard !lower.hasPrefix("[ ]"), !lower.hasPrefix("[]"), !lower.hasPrefix("[x]") else { return nil }
        return (indent, text)
    }

    /// The label of a bullet that is only a label — `- Sign of work:` → "Sign of work".
    /// Emphasis comes off, since the rewrite adds its own: models write the label bold in both
    /// spellings (`**Table**:` and `**Table:**`) and neither may become `****Table**:**`.
    private static func leadIn(_ line: String) -> (indent: Int, label: String)? {
        guard let b = bullet(line) else { return nil }
        var text = b.text
        if text.hasPrefix("**"), text.hasSuffix(":**") { text = String(text.dropFirst(2).dropLast(2)) }
        guard text.hasSuffix(":") else { return nil }
        let label = unemphasized(String(text.dropLast()).trimmingCharacters(in: .whitespaces))
        // A long line ending in a colon is prose introducing a list, and prose keeps its bullet.
        guard !label.isEmpty, label.count <= 60, !label.contains(":") else { return nil }
        return (b.indent, label)
    }

    /// Strip emphasis wrapping the whole label. A label with emphasis *inside* it — "the **key**
    /// idea" — is left alone: stripping its outer pair would cut the markers in half.
    private static func unemphasized(_ s: String) -> String {
        for marker in ["**", "*", "__", "_"] {
            guard s.hasPrefix(marker), s.hasSuffix(marker), s.count > marker.count * 2 else { continue }
            let inner = String(s.dropFirst(marker.count).dropLast(marker.count))
                .trimmingCharacters(in: .whitespaces)
            if !inner.contains(marker) { return inner }
        }
        return s
    }

    /// How deep a line sits: two spaces (or one tab) per level, capped so a model that indents
    /// by eight can't push text off the pane. Renderers share this so the editor, the reading
    /// view, print and the web fallback all agree on what "nested" means.
    static func indentLevel(_ line: String) -> Int {
        var spaces = 0
        for c in line {
            if c == " " { spaces += 1 } else if c == "\t" { spaces += 2 } else { break }
        }
        return min(3, spaces / 2)
    }

    /// The marker drawn at each depth — filled, hollow, square, the way every outliner does it.
    static func bulletGlyph(_ level: Int) -> String {
        switch level {
        case 0:  return "•"
        case 1:  return "◦"
        default: return "▪"
        }
    }
}

// MARK: - Self-test (`StudyBar --format-selftest`)

enum NoteFormatSelfTest {
    @MainActor
    static func run() -> Int32 {
        var failures = 0
        func check(_ name: String, _ got: String, _ want: String) {
            let ok = got == want
            if !ok { failures += 1 }
            print("  \(ok ? "ok  " : "FAIL") \(name)")
            if !ok {
                print("       want: \(want.replacingOccurrences(of: "\n", with: "⏎"))")
                print("       got:  \(got.replacingOccurrences(of: "\n", with: "⏎"))")
            }
        }
        func checkBool(_ name: String, _ got: Bool, _ want: Bool) {
            check(name, got ? "yes" : "no", want ? "yes" : "no")
        }

        print("NoteFormat self-test")

        // The shape from the store that this exists for.
        let real = """
        - Sign of work:
        - **Positive work**: force and displacement are in the same direction.
        - **Negative work**: force and displacement are in opposite directions.
        """
        check("label bullet becomes a bold lead-in", NoteFormat.tidy(real), """
        **Sign of work:**
          - **Positive work**: force and displacement are in the same direction.
          - **Negative work**: force and displacement are in opposite directions.
        """)
        checkBool("tidy is idempotent", NoteFormat.tidy(NoteFormat.tidy(real)) == NoteFormat.tidy(real), true)

        check("a blank line separates the lead-in from what precedes it",
              NoteFormat.tidy("Work done by a force.\n- Sign of work:\n- Positive: same direction."),
              "Work done by a force.\n\n**Sign of work:**\n  - Positive: same direction.")

        check("an already-bold label does not double its stars",
              NoteFormat.tidy("- **Sign of work:**\n- Positive: same direction."),
              "**Sign of work:**\n  - Positive: same direction.")

        check("a label above a table is un-bulleted too",
              NoteFormat.tidy("- **Table**:\n\n| Year | Due |\n|------|-----|\n| 0 | $1,000 |"),
              "**Table:**\n\n| Year | Due |\n|------|-----|\n| 0 | $1,000 |")
        check("a label bolded without the colon is un-bulleted cleanly",
              NoteFormat.tidy("- **Sign of work**:\n- Positive: same direction."),
              "**Sign of work:**\n  - Positive: same direction.")
        // Bolding a label that already contains emphasis would nest the markers wrongly, so
        // that one is un-bulleted without adding any.
        check("a label with emphasis inside it is not re-bolded",
              NoteFormat.tidy("- The **key** idea:\n- It follows from the definition."),
              "The **key** idea:\n  - It follows from the definition.")
        check("a label above prose keeps its bullet",
              NoteFormat.tidy("- Table:\n\nA paragraph about the table."),
              "- Table:\n\nA paragraph about the table.")

        // Everything the rule must not touch.
        let noChildren = "- Sign of work:\n\nA paragraph."
        check("a colon bullet with nothing under it is left alone", NoteFormat.tidy(noChildren), noChildren)
        let contentAfterColon = "- **Positive work**: force and displacement agree.\n- **Negative work**: they oppose."
        check("a bullet with content after the colon is left alone",
              NoteFormat.tidy(contentAfterColon), contentAfterColon)
        let prose = "The three cases below matter for the exam, and each one is worth knowing well:\n- First case."
        check("prose ending in a colon keeps its line", NoteFormat.tidy(prose), prose)
        let task = "- [ ] Email the TA:\n- [ ] Book a room."
        check("a checkbox is not a lead-in", NoteFormat.tidy(task), task)
        let noColon = "- Sign of work\n- Positive work"
        check("bullets without a colon are untouched", NoteFormat.tidy(noColon), noColon)
        let timestamp = "- Lecture 3: 10:30 start"
        check("a second colon means it is content, not a label", NoteFormat.tidy(timestamp), timestamp)
        check("text with no colon short-circuits", NoteFormat.tidy("- a\n- b"), "- a\n- b")

        // Already-nested input keeps its nesting rather than being re-flattened.
        let nested = "**Sign of work:**\n  - Positive: same direction.\n  - Negative: opposite."
        check("already-nested output is stable", NoteFormat.tidy(nested), nested)

        // Indent reading, which every renderer shares.
        check("no indent is level 0", "\(NoteFormat.indentLevel("- a"))", "0")
        check("two spaces is level 1", "\(NoteFormat.indentLevel("  - a"))", "1")
        check("four spaces is level 2", "\(NoteFormat.indentLevel("    - a"))", "2")
        check("a tab is level 1", "\(NoteFormat.indentLevel("\t- a"))", "1")
        check("deep indents are capped", "\(NoteFormat.indentLevel("                - a"))", "3")
        check("depth changes the marker",
              "\(NoteFormat.bulletGlyph(0))\(NoteFormat.bulletGlyph(1))\(NoteFormat.bulletGlyph(2))", "•◦▪")

        // Bullet parsing: the marker needs its space, or `-5 V` is a list.
        checkBool("a dash without a space is not a bullet", NoteFormat.bullet("-5 V across the plate") == nil, true)
        checkBool("a star bullet parses", NoteFormat.bullet("* thing")?.text == "thing", true)
        checkBool("a bullet glyph parses", NoteFormat.bullet("  • thing")?.indent == 2, true)

        print(failures == 0 ? "All NoteFormat checks passed." : "\(failures) NoteFormat check(s) failed.")
        return failures == 0 ? 0 : 1
    }
}
