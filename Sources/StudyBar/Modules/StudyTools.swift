import SwiftUI

// MARK: - Make flashcards

/// Flashcards from the student's own material, in one place whichever way they came: a note's
/// Flashcards button, a selection's right-click, an empty Flashcards screen, a deck's menu. Pick
/// the notes (or keep the selection), say how many and what to stress, check the cards, add them.
struct MakeCardsView: View {
    /// `note`: the note a selection was made in, so its cards point back to it.
    struct Request: Identifiable { let id = UUID(); var notes: [UUID] = []; var text = ""; var course: UUID? = nil; var deck: UUID? = nil; var note: UUID? = nil }

    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let request: Request

    struct Card: Identifiable { let id = UUID(); var front: String; var back: String; var include = true }

    /// What kind of cards to write. Mixed is what this always wrote.
    enum Kind: String, CaseIterable, Identifiable {
        case mixed = "Mixed", terms = "Terms", blanks = "Fill in the blank"
        var id: String { rawValue }
        var help: String {
            switch self {
            case .mixed: return "Definitions, key-concept questions and a few why or how questions"
            case .terms: return "A term, name or formula on the front; what it means on the back"
            case .blanks: return "A sentence with the key word hidden — you recall it"
            }
        }
    }

    @State private var course: UUID?
    @State private var picked: Set<UUID> = []
    @State private var search = ""
    @State private var selection = ""
    @AppStorage("cardsCount") private var count = 10
    @AppStorage("cardsKind") private var kind: Kind = .mixed
    @AppStorage("cardsLevel") private var level: Difficulty = .standard
    @State private var focus = ""
    @State private var deck: UUID?
    @State private var loading = false
    @State private var raw = ""
    @State private var cards: [Card] = []
    @State private var failed = false
    @State private var task: Task<Void, Never>?

    private var fromSelection: Bool { !request.text.isEmpty }
    private var courseNotes: [Note] {
        state.data.notes.filter { $0.courseID == course }
            .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.body.localizedCaseInsensitiveContains(search) }
            .sorted { $0.createdAt > $1.createdAt }
    }
    private var included: Int { cards.filter(\.include).count }
    private var courseName: String { state.course(course).map { $0.code.isEmpty ? $0.name : $0.code } ?? "Flashcards" }
    /// The deck the cards go to: the one asked for, else the course's, else a new one named for it.
    private var target: Deck? { state.data.decks.first { $0.id == deck } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Make flashcards").font(.headline)
                Spacer()
                if !fromSelection { CoursePicker(courseID: $course).fixedSize() }
            }.padding(14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if fromSelection {
                        Text("From your selection").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        TextEditor(text: $selection).font(.callout).frame(minHeight: 90)
                            .scrollContentBackground(.hidden).padding(6)
                            .background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                    } else {
                        notePicker
                    }
                    HStack(spacing: 12) {
                        Picker("How many", selection: $count) { ForEach([5, 10, 20, 30], id: \.self) { Text("\($0)").tag($0) } }
                            .pickerStyle(.segmented).frame(width: 260)
                        TextField("Focus — optional, e.g. definitions, formulas, dates", text: $focus).textFieldStyle(.roundedBorder)
                    }
                    // One row each: side by side they don't fit the sheet.
                    Picker("Cards", selection: $kind) { ForEach(Kind.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).fixedSize().help(kind.help)
                    Picker("Difficulty", selection: $level) { ForEach(Difficulty.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).fixedSize()
                    Button { generate() } label: { Label(loading ? "Writing cards…" : cards.isEmpty ? "Write cards" : "Write again", systemImage: "sparkles") }
                        .buttonStyle(.borderedProminent).disabled(loading || source.count < 20 || !AIConfig.isReady(for: .ask))
                    if !AIConfig.isReady(for: .ask) {
                        Text("Set up an engine in Settings ▸ Intelligence to write cards.").font(.caption).foregroundStyle(.secondary)
                    }
                    if loading {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Reading \(fromSelection ? "the selection" : "\(picked.count) note\(picked.count == 1 ? "" : "s")")…").font(.caption).foregroundStyle(.secondary)
                            Button("Stop") { task?.cancel() }.controlSize(.small).help("Stop — keep the cards written so far")
                        }
                    } else if failed {
                        Label("No cards came back that could be read — try again, or a stronger engine in Settings ▸ Intelligence.", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if !cards.isEmpty { preview }
                }.padding(14)
            }
            Divider()
            HStack {
                if !cards.isEmpty {
                    Text("Add to").font(.callout)
                    Menu(target?.name ?? "New deck “\(courseName)”") {
                        Button("New deck “\(courseName)”") { deck = nil }
                        Divider()
                        ForEach(state.data.decks) { d in Button(d.name.isEmpty ? "Untitled deck" : d.name) { deck = d.id } }
                    }.fixedSize()
                }
                Spacer()
                Button("Cancel") { task?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add \(included) card\(included == 1 ? "" : "s")") { add() }.buttonStyle(.borderedProminent).disabled(included == 0)
            }.padding(12)
        }
        .frame(minWidth: 620, minHeight: 560)
        .onAppear {
            course = request.course ?? state.likelyCourseID
            picked = Set(request.notes)
            selection = request.text
            deck = request.deck ?? defaultDeck(for: course)
        }
        .onChange(of: course) { _, c in
            if !request.notes.contains(where: { id in state.data.notes.first { $0.id == id }?.courseID == c }) { picked = [] }
            if request.deck == nil { deck = defaultDeck(for: c) }
        }
    }

    private var notePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("From these notes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("All") { picked.formUnion(courseNotes.map(\.id)) }.buttonStyle(.borderless).font(.caption)
                Button("None") { picked = [] }.buttonStyle(.borderless).font(.caption)
            }
            SearchField(text: $search)
            if courseNotes.isEmpty {
                Text(search.isEmpty ? "No notes in \(state.course(course)?.name ?? "this course") yet — pick another course above." : "No notes match.")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 6)
            }
            ForEach(courseNotes.prefix(200)) { n in
                Button { if picked.contains(n.id) { picked.remove(n.id) } else { picked.insert(n.id) } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: picked.contains(n.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(picked.contains(n.id) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        Text(n.title.isEmpty ? "Untitled note" : n.title).lineLimit(1)
                        Spacer()
                        Text(n.createdAt.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(included) of \(cards.count) selected").font(.caption.weight(.medium))
                Spacer()
                Text("Edit any card before adding").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach($cards) { $c in
                HStack(alignment: .top, spacing: 8) {
                    Button { c.include.toggle() } label: {
                        Image(systemName: c.include ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(c.include ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            .accessibilityLabel(c.include ? "Leave out this card" : "Include this card")
                    }.buttonStyle(.plain).padding(.top, 3)
                    VStack(spacing: 4) {
                        TextField("Front", text: $c.front).textFieldStyle(.roundedBorder)
                        // A fill-in-the-blank card's answer is the word in {{…}}; it has no back.
                        if !(c.front.contains("{{") && c.back.isEmpty) {
                            TextField("Back", text: $c.back).textFieldStyle(.roundedBorder)
                        }
                    }
                }.opacity(c.include ? 1 : 0.5)
            }
        }
    }

    /// The material, as the model reads it: the selection, or each picked note under its title.
    private var source: String {
        if fromSelection { return selection.trimmingCharacters(in: .whitespacesAndNewlines) }
        return state.data.notes.filter { picked.contains($0.id) }.sorted { $0.createdAt < $1.createdAt }
            .map { "# \($0.title.isEmpty ? "Untitled note" : $0.title)\n\($0.body)" }.joined(separator: "\n\n")
    }

    private func defaultDeck(for course: UUID?) -> UUID? {
        let name = state.course(course).map { $0.code.isEmpty ? $0.name : $0.code }
        return (state.data.decks.first { course != nil && $0.courseID == course }
            ?? state.data.decks.first { name != nil && $0.name.caseInsensitiveCompare(name!) == .orderedSame })?.id
    }

    static func system(count: Int, focus: String, kind: Kind = .mixed, level: Difficulty = .standard) -> String {
        let f = focus.trimmingCharacters(in: .whitespacesAndNewlines)
        let spread = "Write about \(count) cards — fewer only if the material runs out — covering the key terms, definitions, formulas, facts and methods across ALL of it, not just the start."
        let shape: String
        switch kind {
        case .mixed:
            shape = "Output ONE flashcard per line as `Front / Back` — the front, then a space, a slash, a space, then the back. Example: `What is present worth? / A method that discounts future cash flows to the present using the MARR.` \(spread) Vary them: plain definitions, key-concept questions, and a few 'why' or application questions. Keep each back to 1–2 sentences."
        case .terms:
            shape = "Output ONE flashcard per line as `Front / Back` — the front, then a space, a slash, a space, then the back. The front is a single key term, name, symbol or formula from the material; the back says what it means in one sentence. Example: `MARR / The minimum rate of return a project must earn to be accepted.` \(spread)"
        case .blanks:
            shape = "Output ONE card per line: a sentence that states one key fact from the material, with the word or short phrase the student must recall wrapped in double braces. EVERY line needs its {{…}} — a line without one is not a card. Examples: `The {{MARR}} is the minimum rate of return a project must earn to be accepted.` and `Work done by a gas at constant pressure is the pressure times the {{change in volume}}.` One blank per card, and never a formula inside the braces. \(spread)"
        }
        return "You create study flashcards from a student's own material. " + shape + " Write any math as LaTeX in $…$." + level.forCards
            + (f.isEmpty ? "" : " The student wants the cards to focus on: \(f).")
            + " Use only what's in the material — do not invent. No numbering, no preamble, no other text."
    }

    private func generate() {
        guard let provider = AIService.makeProvider(for: .ask) else { return }
        let text = String(source.prefix(LectureNotes.readChars(for: AIConfig.engine(for: .ask))))
        guard text.count >= 20 else { return }
        loading = true; raw = ""; cards = []; failed = false
        let sys = Self.system(count: count, focus: focus, kind: kind, level: level)
        task?.cancel()
        task = Task {
            let out = try? await provider.streamPlain(system: sys, messages: [AIMessage(role: .user, text: text)]) { p in raw = p }
            loading = false
            // Stopped: the cards written so far, less the one cut off mid-line.
            let written = Task.isCancelled ? String(raw[..<(raw.lastIndex(of: "\n") ?? raw.startIndex)]) : (out ?? raw)
            cards = Self.parse(written, kind: kind).map { Card(front: $0.front, back: $0.back) }
            failed = cards.isEmpty && !Task.isCancelled
        }
    }

    private func add() {
        let name = courseName
        // Each card remembers its note — and the moment in that lecture — found by its words.
        let from = fromSelection ? [request.note].compactMap { $0 } : Array(picked)
        let place = CardOrigin.finder(among: state.data.notes.filter { from.contains($0.id) })
        state.withUndo("Added \(included) card\(included == 1 ? "" : "s") to \(target?.name ?? name)") {
            let d: Deck
            if let t = target { d = t } else { d = Deck(name: name, courseID: course); state.data.decks.append(d) }
            var seen = Set(state.data.flashcards.filter { $0.deckID == d.id }.map { $0.front.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) })
            for c in cards where c.include {
                let key = c.front.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                var f = Flashcard(deckID: d.id, front: c.front, back: c.back)
                f.source = from.isEmpty ? nil : place(c.front, c.back)
                state.data.flashcards.append(f)
            }
        }
        dismiss()
    }

    /// Tolerant of however the model actually formatted the cards — weak local models rarely
    /// obey the format. Tries, in order: a `::`/`/`/`|`/tab delimiter per line; then
    /// blank-line-separated blocks (first line = front, rest = back — the common Q?/A layout);
    /// then consecutive line pairs. Strips numbering and Q:/A:/Front:/Back: prefixes.
    static func parse(_ s: String, kind: Kind = .mixed) -> [(front: String, back: String)] {
        let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        func clean(_ t: String) -> String {
            MathSupport.normalized(t).trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"^\s*(\d+[.)]|[-•*])\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"(?i)^\s*(front|back|q(?:uestion)?|a(?:nswer)?)\s*[:.)\-]\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }

        // 0) Fill-in-the-blank: most lines hide a word in {{…}} — each is a cloze card, no back.
        let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let cloze = lines.filter { $0.range(of: #"\{\{[^{}]+\}\}"#, options: .regularExpression) != nil }
        // Asked for blanks, a sentence without one is a fact with nothing to recall — never a card,
        // and never paired with the next line as if it were its back.
        if kind == .blanks || (cloze.count >= 2 && cloze.count * 2 >= lines.count) {
            return cloze.map { (clean($0.replacingOccurrences(of: "`", with: "")), "") }
        }

        // 1) Delimiter per line. Space-padded " / " and " | " so mid-content slashes/pipes
        //    ("benefit/cost") don't split; `::` and tab are unambiguous.
        for d in ["::", " / ", " | ", "\t"] {
            let found: [(String, String)] = text.split(whereSeparator: \.isNewline).compactMap { line in
                let parts = String(line).components(separatedBy: d)
                guard parts.count >= 2 else { return nil }
                let f = clean(parts[0]), b = clean(parts[1...].joined(separator: d))
                return (!f.isEmpty && !b.isEmpty) ? (f, b) : nil
            }
            if found.count >= 2 { return found }
        }

        // 2) Blank-line-separated cards: first line = front, remaining lines = back.
        var blocks: [[String]] = [], cur: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { if !cur.isEmpty { blocks.append(cur); cur = [] } }
            else { cur.append(String(line)) }
        }
        if !cur.isEmpty { blocks.append(cur) }
        if blocks.count >= 2 {
            let found: [(String, String)] = blocks.compactMap { lines in
                guard lines.count >= 2 else { return nil }
                let f = clean(lines[0]), b = clean(lines[1...].joined(separator: " "))
                return (!f.isEmpty && !b.isEmpty) ? (f, b) : nil
            }
            if !found.isEmpty { return found }
        }

        // 3) Last resort: pair up consecutive non-empty lines.
        var out: [(String, String)] = [], i = 0
        while i + 1 < lines.count {
            let f = clean(lines[i]), b = clean(lines[i + 1])
            if !f.isEmpty, !b.isEmpty { out.append((f, b)); i += 2 } else { i += 1 }
        }
        return out
    }
}

// MARK: - Study notes, the way the student wants them

/// The choices behind "Make study notes": how much of the lecture, what shape, how much the AI
/// fills in, what to stress. Remembered between lectures — except the focus, which is this one's.
struct NotesStyleForm: View {
    @AppStorage("notesDetail") private var detail = LectureNotes.Style.Detail.full.rawValue
    @AppStorage("notesShape") private var shape = LectureNotes.Style.Shape.notes.rawValue
    @AppStorage("notesFillIn") private var fill = LectureNotes.Style.FillIn.thorough.rawValue
    @Binding var focus: String

    static func style(focus: String) -> LectureNotes.Style {
        var s = LectureNotes.Style.saved
        s.focus = focus.trimmingCharacters(in: .whitespacesAndNewlines)
        return s
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Detail").gridColumnAlignment(.trailing)
                Picker("Detail", selection: $detail) { ForEach(LectureNotes.Style.Detail.allCases) { Text($0.rawValue).tag($0.rawValue) } }
                    .pickerStyle(.segmented).labelsHidden()
            }
            GridRow {
                Text("Shape")
                Picker("Shape", selection: $shape) { ForEach(LectureNotes.Style.Shape.allCases) { Text($0.rawValue).tag($0.rawValue) } }
                    .pickerStyle(.segmented).labelsHidden()
            }
            GridRow {
                Text("Fill in")
                Picker("Fill in", selection: $fill) { ForEach(LectureNotes.Style.FillIn.allCases) { Text($0.rawValue).tag($0.rawValue) } }
                    .pickerStyle(.segmented).labelsHidden()
            }
            GridRow {
                Text("Focus")
                TextField("Optional — e.g. formulas and definitions, what's on the exam", text: $focus).textFieldStyle(.roundedBorder)
            }
        }
        Text(explain).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private var explain: String {
        let d = detail == "Brief" ? "About a page: the main ideas, every definition and formula, an example per topic."
            : detail == "Standard" ? "Every definition, formula and example; the rest said once, plainly."
            : "Everything that was said."
        let f = fill == "None" ? "Nothing added that wasn't said."
            : fill == "Light" ? "Only what you can't follow without is added, marked 💡 Added."
            : "Definitions, missing steps and examples the lecture skipped are added, marked 💡 Added."
        return d + " " + f
    }
}

/// A note — a transcript saved as it was said, most often — rewritten as study notes. The note's
/// text before is kept in its History.
struct StudyNotesSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let text: String
    let course: UUID?
    let onReplace: (String) -> Void
    @State private var focus = ""
    @State private var stream = ""
    @State private var part = (1, 1)
    @State private var busy = false
    @State private var result: String?
    @State private var failed = false
    @State private var task: Task<Void, Never>?

    /// `result`: notes already written — for the layout snapshot.
    init(text: String, course: UUID?, onReplace: @escaping (String) -> Void, result: String? = nil) {
        self.text = text; self.course = course; self.onReplace = onReplace
        _result = State(initialValue: result)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Study notes from this note").font(.headline)
            NotesStyleForm(focus: $focus)
            if busy || result != nil {
                ScrollView { NotePreview(text: result ?? stream).padding(10).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(height: 300).background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            }
            if failed { Label("The AI returned nothing usable — the note is unchanged.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            HStack {
                if busy {
                    ProgressView().controlSize(.small)
                    Text(part.1 > 1 ? "Writing part \(part.0) of \(part.1)…" : "Writing…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("The note's text now stays in its History.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { task?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                if let result {
                    Button("Write again") { write() }.disabled(busy)
                    Button("Replace the note") { onReplace(result); dismiss() }.buttonStyle(.borderedProminent).disabled(busy)
                } else {
                    Button("Write notes") { write() }.buttonStyle(.borderedProminent).disabled(busy || !AIConfig.isReady(for: .transcript))
                }
            }
        }
        .padding(18).frame(width: 620)
    }

    private func write() {
        guard let provider = AIService.makeProvider(for: .transcript) else { return }
        busy = true; failed = false; result = nil; stream = ""
        let style = NotesStyleForm.style(focus: focus)
        task = Task {
            let out = await LectureNotes.run(text, job: .lecture, provider: provider, mode: AIConfig.engine(for: .transcript),
                                             material: StudyMaterial.coursePassages(course, in: state.data), style: style) { notes, p, t in
                stream = notes; part = (p, t)
            }
            busy = false
            let cleaned = NoteFormat.tidy(MathSupport.normalized((out ?? "").trimmingCharacters(in: .whitespacesAndNewlines)))
            if cleaned.count > 80 { result = cleaned } else { failed = true }
        }
    }
}

// MARK: - Announced in a lecture → Assignments

/// The homework and deadlines a lecture's notes list under Announced, each as an assignment to
/// check — title, date, whether it's wanted — before any is added. Dates are read from what was
/// said, counted from the lecture's day.
struct AnnouncedSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let note: Note

    struct Row: Identifiable { let id = UUID(); var a: Assignment; var dated: Bool; var include = true }
    @State private var rows: [Row] = []
    private var chosen: Int { rows.filter(\.include).count }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Announced in this lecture").font(.headline)
                Spacer()
                CourseChip(course: state.course(note.courseID))
            }.padding(14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Check each one, then add it to Assignments. Dates come from what was said, counted from the lecture on \(note.createdAt.dayMonth).")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach($rows) { $r in
                        HStack(alignment: .top, spacing: 8) {
                            Button { r.include.toggle() } label: {
                                Image(systemName: r.include ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(r.include ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            }.buttonStyle(.plain).padding(.top, 4)
                                .accessibilityLabel(r.include ? "Don't add \(r.a.title)" : "Add \(r.a.title)")
                            VStack(alignment: .leading, spacing: 4) {
                                TextField("Title", text: $r.a.title).textFieldStyle(.roundedBorder)
                                HStack(spacing: 8) {
                                    Toggle("Due", isOn: $r.dated).toggleStyle(.checkbox)
                                    if r.dated {
                                        DatePicker("", selection: Binding(get: { r.a.due ?? defaultDue }, set: { r.a.due = $0 }),
                                                   displayedComponents: [.date, .hourAndMinute]).labelsHidden().fixedSize()
                                    }
                                }
                                Text(r.a.notes).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }.opacity(r.include ? 1 : 0.5)
                    }
                }.padding(14)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add \(chosen) to Assignments") { add() }.buttonStyle(.borderedProminent).disabled(chosen == 0)
                    .keyboardShortcut(.defaultAction)
            }.padding(12)
        }
        .frame(minWidth: 500, minHeight: 360)
        .onAppear { rows = Announced.assignments(in: note, data: state.data).map { Row(a: $0, dated: $0.due != nil) } }
    }

    /// A week after the lecture, end of day — where a date picked by hand starts.
    private var defaultDue: Date {
        let cal = Calendar.current
        let week = cal.date(byAdding: .day, value: 7, to: note.createdAt) ?? note.createdAt
        return cal.date(bySettingHour: 23, minute: 59, second: 0, of: week) ?? week
    }

    private func add() {
        let picked = rows.filter(\.include).map { r -> Assignment in
            var a = r.a
            a.title = a.title.trimmingCharacters(in: .whitespaces)
            if !r.dated { a.due = nil }
            return a
        }.filter { !$0.title.isEmpty }
        state.withUndo("Added \(picked.count) assignment\(picked.count == 1 ? "" : "s")") { state.data.assignments += picked }
        dismiss()
    }
}


// MARK: - Fix a misheard word

/// Misheard → should be, how many places it's in, and whether the course's recordings should
/// expect the right word from now on. Voice uses it on a transcript; Notes on a whole course.
struct FixWordFields: View {
    @Binding var find: String
    @Binding var replace: String
    @Binding var learn: Bool
    let count: Int
    /// "in the transcript", "in 3 notes".
    let place: String
    let course: String?
    /// The sheet keeps Replace All in its footer instead.
    var inlineButton = true
    let apply: () -> Void

    static func ready(count: Int, replace: String) -> Bool { count > 0 && !replace.trimmingCharacters(in: .whitespaces).isEmpty }
    private var ready: Bool { Self.ready(count: count, replace: replace) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Heard as — e.g. ferrets", text: $find).textFieldStyle(.roundedBorder)
            TextField("Should be — e.g. farads", text: $replace).textFieldStyle(.roundedBorder)
                .onSubmit { if ready { apply() } }
            Text(find.trimmingCharacters(in: .whitespaces).isEmpty ? " " : count == 0 ? "Not found \(place)." : "\(count) place\(count == 1 ? "" : "s") \(place).")
                .font(.caption).foregroundStyle(.secondary)
            if let course {
                Toggle(replace.trimmingCharacters(in: .whitespaces).isEmpty ? "Expect the right word in \(course) recordings from now on"
                       : "Expect “\(replace)” in \(course) recordings from now on", isOn: $learn)
                    .toggleStyle(.checkbox).font(.caption)
            }
            if inlineButton {
                HStack {
                    Spacer()
                    Button("Replace All", action: apply).buttonStyle(.borderedProminent).disabled(!ready)
                }
            }
        }
    }
}

/// A word fixed in every note of a course — the title, the text and its formatting — with Undo.
struct FixWordSheet: View {
    struct Request: Identifiable { let id = UUID(); var find = ""; var course: UUID? }
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let request: Request
    @State private var find = ""
    @State private var replace = ""
    @State private var course: UUID?
    @State private var learn = true

    private var hits: [(note: Note, count: Int)] {
        guard !find.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return state.data.notes.filter { $0.courseID == course }.compactMap { n in
            let c = TermFix.count(n.body, find) + TermFix.count(n.title, find)
            return c > 0 ? (n, c) : nil
        }
    }

    var body: some View {
        let hits = hits
        VStack(spacing: 0) {
            HStack {
                Text("Fix a word in every note").font(.headline)
                Spacer()
                CoursePicker(courseID: $course).fixedSize()
            }.padding(14)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                FixWordFields(find: $find, replace: $replace, learn: $learn, count: hits.map(\.count).reduce(0, +),
                              place: "in \(hits.count) note\(hits.count == 1 ? "" : "s")",
                              course: state.course(course).map { $0.code.isEmpty ? $0.name : $0.code }, inlineButton: false, apply: apply)
                if !hits.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(hits, id: \.note.id) { h in
                                HStack {
                                    Text(h.note.title.isEmpty ? "Untitled note" : h.note.title).lineLimit(1)
                                    Spacer()
                                    Text("\(h.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }.font(.callout)
                            }
                        }
                    }.frame(maxHeight: 160)
                }
                Text("Whole words, any case; a capital stays a capital. The recording's own transcript keeps the words as they were heard.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }.padding(14)
            Spacer(minLength: 0)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Replace All", action: apply).buttonStyle(.borderedProminent)
                    .disabled(!FixWordFields.ready(count: hits.map(\.count).reduce(0, +), replace: replace))
                    .keyboardShortcut(.defaultAction)
            }.padding(12)
        }
        .frame(width: 460, height: 440)
        .onAppear { find = request.find; course = request.course }
    }

    private func apply() {
        let fixes = hits.compactMap { TermFix.fixed($0.note, find, with: replace) }
        let total = fixes.map(\.count).reduce(0, +), shown = find.trimmingCharacters(in: .whitespaces)
        state.withUndo("Fixed “\(shown)” in \(fixes.count) note\(fixes.count == 1 ? "" : "s") (\(total))", rewritesNotes: true) {
            for f in fixes { if let i = state.data.notes.firstIndex(where: { $0.id == f.note.id }) { state.data.notes[i] = f.note } }
            if learn { TermFix.learn(replace, course: course, in: &state.data) }
        }
        dismiss()
    }
}
