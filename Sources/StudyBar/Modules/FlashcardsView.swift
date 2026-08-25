import SwiftUI

/// Cloze deletions. Stored internally as `{{word}}`, but the braces are never
/// shown or typed — the composer blanks words by tapping them.
enum Cloze {
    static func question(_ s: String) -> String {
        s.replacingOccurrences(of: #"\{\{(.*?)\}\}"#, with: "[ … ]", options: .regularExpression)
    }
    static func answer(_ s: String) -> String {
        s.replacingOccurrences(of: "{{", with: "").replacingOccurrences(of: "}}", with: "")
    }

    /// Front words for the blank-picker chips (space-separated tokens).
    static func words(_ plain: String) -> [String] {
        plain.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    }
    /// Existing stored front → plain text (no braces) + the set of blanked word indices.
    static func parse(_ front: String) -> (plain: String, blanks: Set<Int>) {
        var blanks = Set<Int>(); var plain: [String] = []
        for (i, w) in front.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
            var s = String(w); var isBlank = false
            if s.hasPrefix("{{") { s.removeFirst(2); isBlank = true }
            if s.hasSuffix("}}") { s.removeLast(2); isBlank = true }
            if isBlank { blanks.insert(i) }
            plain.append(s)
        }
        return (plain.joined(separator: " "), blanks)
    }
    /// Plain text + blanked indices → stored front with `{{ }}` around blanks.
    static func build(plain: String, blanks: Set<Int>) -> String {
        plain.split(separator: " ", omittingEmptySubsequences: false).enumerated().map { i, w in
            (blanks.contains(i) && !w.isEmpty) ? "{{\(w)}}" : String(w)
        }.joined(separator: " ")
    }
}

struct FlashcardsView: View {
    @EnvironmentObject var state: AppState
    @State private var newDeck = ""

    private func dueCount(_ deck: Deck) -> Int {
        state.data.flashcards.filter { $0.deckID == deck.id && $0.isDue }.count
    }
    private func cardCount(_ deck: Deck) -> Int {
        state.data.flashcards.filter { $0.deckID == deck.id }.count
    }

    var body: some View {
        NavigationStack {
            ModulePane(title: "Flashcards") { EmptyView() } content: {
                VStack(spacing: 0) {
                    HStack {
                        TextField("New deck…", text: $newDeck, onCommit: addDeck)
                            .textFieldStyle(.roundedBorder)
                        Button("Add", action: addDeck).disabled(newDeck.isEmpty)
                    }.padding(10)
                    Divider()
                    if state.data.decks.isEmpty {
                        EmptyState(symbol: "rectangle.on.rectangle.angled", title: "No decks",
                                   subtitle: "Create a deck, add cards, then study with spaced repetition.")
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 6) {
                                ForEach(state.data.decks) { deck in
                                    NavigationLink(value: deck) { deckRow(deck) }.buttonStyle(.plain)
                                }
                            }.padding(10)
                        }
                    }
                }
            }
            .navigationDestination(for: Deck.self) { DeckView(deck: $0) }
        }
    }

    private func deckRow(_ deck: Deck) -> some View {
        HStack(spacing: DS.Space.l) {
            Image(systemName: "rectangle.stack").foregroundStyle(.tint).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(deck.name.isEmpty ? "Untitled deck" : deck.name).fontWeight(.medium)
                HStack(spacing: DS.Space.s) {
                    CourseChip(course: state.course(deck.courseID))
                    Text("\(cardCount(deck)) cards").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            let due = dueCount(deck)
            if due > 0 { Chip("\(due) due", .status(.week)) }
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(DS.Space.m).background(.background.secondary, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }

    private func addDeck() {
        let n = newDeck.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        state.data.decks.append(Deck(name: n))
        newDeck = ""
    }
}

// MARK: - Deck detail

struct DeckView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let deck: Deck
    @State private var frontPlain = ""
    @State private var back = ""
    @State private var blanks: Set<Int> = []
    @State private var selectedTags: Set<String> = []
    @State private var composerFlipped = false
    @State private var cardFilter = ""
    @State private var studying = false
    @State private var practiceAll = false
    @State private var editingCard: Flashcard?
    @State private var importing = false

    private var cards: [Flashcard] { state.data.flashcards.filter { $0.deckID == deck.id } }
    private var due: [Flashcard] { cards.filter { $0.isDue } }
    private var newCards: [Flashcard] { cards.filter { $0.reps == 0 } }
    private var filteredCards: [Flashcard] {
        guard !cardFilter.isEmpty else { return cards }
        return cards.filter {
            $0.front.localizedCaseInsensitiveContains(cardFilter) ||
            $0.back.localizedCaseInsensitiveContains(cardFilter) ||
            $0.tags.contains { $0.localizedCaseInsensitiveContains(cardFilter) }
        }
    }
    private var retention: Int? {
        let reviewed = cards.filter { $0.reviews > 0 }
        let totalR = reviewed.reduce(0) { $0 + $1.reviews }
        guard totalR > 0 else { return nil }
        let lapses = reviewed.reduce(0) { $0 + $1.lapses }
        return Int(round(Double(totalR - lapses) / Double(totalR) * 100))
    }
    private var courseBinding: Binding<UUID?> {
        Binding(get: { state.data.decks.first { $0.id == deck.id }?.courseID },
                set: { v in if let i = state.data.decks.firstIndex(where: { $0.id == deck.id }) { state.data.decks[i].courseID = v } })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            statsRow
            Divider()
            addCardForm
            Divider()
            cardList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("").toolbar(.hidden, for: .windowToolbar)
        .navigationDestination(isPresented: $studying) { StudyView(deckID: deck.id, practiceAll: practiceAll) }
        .navigationDestination(item: $editingCard) { CardEditor(card: $0) }
        .navigationDestination(isPresented: $importing) { CSVImportView(deckID: deck.id) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: { Image(systemName: "chevron.left").fontWeight(.semibold) }
                .buttonStyle(.borderless).help("Back").keyboardShortcut("[", modifiers: .command)
            Text(deck.name.isEmpty ? "Deck" : deck.name).font(.headline).lineLimit(1)
            CoursePicker(courseID: courseBinding)
            Spacer()
            Menu {
                Button { importing = true } label: { Label("Import CSV…", systemImage: "square.and.arrow.down") }
                Button { exportCSV() } label: { Label("Copy deck as CSV", systemImage: "doc.on.doc") }
                Divider()
                Button { resetProgress() } label: { Label("Reset study progress", systemImage: "arrow.counterclockwise") }
                Button(role: .destructive) { deleteDeck() } label: { Label("Delete deck", systemImage: "trash") }
            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
            studyButton
        }.padding(12)
    }

    private var statsRow: some View {
        HStack(spacing: 0) {
            statPill("\(due.count)", "due", .dsWeek)
            statPill("\(newCards.count)", "new", .blue)
            statPill("\(cards.count)", "total", .secondary)
            if let r = retention { statPill("\(r)%", "retention", r >= 80 ? .dsDone : .dsWeek) }
        }.padding(.vertical, 6)
    }
    private func statPill(_ v: String, _ l: String, _ c: Color) -> some View {
        VStack(spacing: 1) {
            Text(v).font(.callout.bold().monospacedDigit()).foregroundStyle(c)
            Text(l).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }

    /// Distinct tags across all decks — the pool the reusable tag chips draw from.
    private var allTags: [String] {
        Array(Set(state.data.flashcards.flatMap { $0.tags })).sorted { $0.localizedCompare($1) == .orderedAscending }
    }
    private var canAdd: Bool {
        !frontPlain.trimmingCharacters(in: .whitespaces).isEmpty
        && (!back.trimmingCharacters(in: .whitespaces).isEmpty || !blanks.isEmpty)
    }

    private var addCardForm: some View {
        VStack(spacing: 10) {
            FlipCardComposer(frontPlain: $frontPlain, back: $back, blanks: $blanks, flipped: $composerFlipped)
            TagChips(suggestions: allTags, selected: $selectedTags)
            HStack {
                Text(blanks.isEmpty ? "Write a front and back — or tap a word to make a cloze blank."
                                    : "Cloze card — the blanked word is the answer.")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button { addCard() } label: { Label("Add card", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).disabled(!canAdd)
            }
        }.padding(10)
    }

    private var cardList: some View {
        Group {
            if cards.isEmpty {
                EmptyState(symbol: "plus.rectangle.on.rectangle", title: "No cards",
                           subtitle: "Add front/back pairs above, or import a CSV from the ⋯ menu.")
            } else {
                VStack(spacing: 0) {
                    if cards.count > 6 { SearchField(text: $cardFilter).padding(8) }
                    ScrollView {
                        LazyVStack(spacing: 5) {
                            ForEach(filteredCards) { card in cardRow(card) }
                        }.padding(10)
                    }
                }
            }
        }
    }

    private func cardRow(_ card: Flashcard) -> some View {
        Button { editingCard = card } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.isCloze ? Cloze.answer(card.front) : card.front).fontWeight(.medium).lineLimit(2)
                    if !card.back.isEmpty {
                        Text(card.back).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if !card.tags.isEmpty {
                        Text(card.tags.map { "#\($0)" }.joined(separator: " ")).font(.caption2).foregroundStyle(.tint)
                    }
                }
                Spacer()
                Text(card.isDue ? "due" : card.due.dayMonth)
                    .font(.caption2).foregroundStyle(card.isDue ? .orange : .secondary)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(DS.Space.m).contentShape(Rectangle())
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        }.buttonStyle(.plain)
    }

    @ViewBuilder private var studyButton: some View {
        if !due.isEmpty {
            Button { practiceAll = false; studying = true } label: { Label("Study \(due.count)", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent)
        } else if !cards.isEmpty {
            Button { practiceAll = true; studying = true } label: { Label("Practice", systemImage: "arrow.clockwise") }
                .buttonStyle(.bordered)
        } else {
            Button { } label: { Label("Study", systemImage: "play.fill") }.buttonStyle(.bordered).disabled(true)
        }
    }

    private func addCard() {
        let storedFront = Cloze.build(plain: frontPlain.trimmingCharacters(in: .whitespaces), blanks: blanks)
        state.data.flashcards.append(Flashcard(deckID: deck.id,
                                               front: storedFront,
                                               back: back.trimmingCharacters(in: .whitespaces),
                                               tags: selectedTags.sorted()))
        frontPlain = ""; back = ""; blanks = []; composerFlipped = false
        // selectedTags intentionally kept — consecutive cards reuse the same tags.
    }
    private func deleteDeck() {
        state.data.flashcards.removeAll { $0.deckID == deck.id }
        state.data.decks.removeAll { $0.id == deck.id }
        dismiss()
    }
    private func resetProgress() {
        for i in state.data.flashcards.indices where state.data.flashcards[i].deckID == deck.id {
            state.data.flashcards[i].reps = 0
            state.data.flashcards[i].interval = 0
            state.data.flashcards[i].ease = 2.5
            state.data.flashcards[i].due = .now
        }
    }
    private func exportCSV() {
        let csv = cards.map { c in
            let f = c.front.replacingOccurrences(of: "\t", with: " ")
            let b = c.back.replacingOccurrences(of: "\t", with: " ")
            let t = c.tags.joined(separator: " ")
            return "\(f)\t\(b)\t\(t)"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(csv, forType: .string)
    }
}

/// A card-flip transition: rotates on the Y axis while entering/leaving, but
/// settles to identity so the resting editor stays interactive.
private struct FlipModifier: ViewModifier {
    let angle: Double
    func body(content: Content) -> some View {
        content
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.3)
            .opacity(abs(angle) > 55 ? 0 : 1)
    }
}
extension AnyTransition {
    static var cardFlip: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: FlipModifier(angle: -90), identity: FlipModifier(angle: 0)),
            removal:   .modifier(active: FlipModifier(angle:  90), identity: FlipModifier(angle: 0)))
    }
}

// MARK: - Flip-card composer + reusable tags

/// The primary card-authoring surface: an actual flashcard you write on. Write
/// the front, flip to write the back, and blank words for cloze by tapping them
/// (no `{{ }}` ever typed or shown).
struct FlipCardComposer: View {
    @Binding var frontPlain: String
    @Binding var back: String
    @Binding var blanks: Set<Int>
    @Binding var flipped: Bool

    private var words: [String] { Cloze.words(frontPlain) }
    private var hasWords: Bool { words.contains { !$0.isEmpty } }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                // Only the visible face exists in the hierarchy, at identity transform,
                // so its TextEditor is always clickable. (A persistent rotation3DEffect
                // breaks hit-testing — you can't type into a rotated editor.) The flip
                // is a transient transition only.
                if flipped {
                    face(text: $back, side: "BACK",
                         placeholder: blanks.isEmpty ? "Answer" : "Extra notes (optional for cloze)")
                        .transition(.cardFlip)
                } else {
                    face(text: $frontPlain, side: "FRONT", placeholder: "Question or term")
                        .transition(.cardFlip)
                }
            }
            .frame(height: 150)
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: flipped)
            .overlay(alignment: .bottomTrailing) {
                Button { flipped.toggle() } label: {
                    Label(flipped ? "Write front" : "Flip to write back", systemImage: "arrow.2.squarepath")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().stroke(.tint.opacity(0.4)))
                }.buttonStyle(.plain).padding(10)
            }

            if !flipped && hasWords { clozeRow }
        }
    }

    // The blank-picker: tap a word to toggle it as a cloze deletion.
    private var clozeRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: "rectangle.dashed").font(.caption2)
                Text(blanks.isEmpty ? "Tap a word to blank it (cloze)"
                                    : "Tap to toggle blanks · answer is the blanked word(s)")
                    .font(.caption2)
            }.foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                        if !w.isEmpty {
                            Button { toggle(i) } label: {
                                Text(w).font(.caption)
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(blanks.contains(i) ? AnyShapeStyle(.tint) : AnyShapeStyle(.background.secondary), in: Capsule())
                                    .foregroundStyle(blanks.contains(i) ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                            }.buttonStyle(.plain)
                        }
                    }
                }.padding(.bottom, 2)
            }
            if !blanks.isEmpty {
                Text(Cloze.question(Cloze.build(plain: frontPlain, blanks: blanks)))
                    .font(.caption2.italic()).foregroundStyle(.tint).lineLimit(2)
            }
        }
    }

    private func toggle(_ i: Int) {
        if blanks.contains(i) { blanks.remove(i) } else { blanks.insert(i) }
    }

    private func face(text: Binding<String>, side: String, placeholder: String) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.tint.opacity(0.35), lineWidth: 1))
                .shadow(color: .black.opacity(0.10), radius: 4, y: 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(side).font(.system(size: 10, weight: .heavy)).foregroundStyle(.tint).tracking(0.8)
                ZStack(alignment: .topLeading) {
                    if text.wrappedValue.isEmpty {
                        Text(placeholder).foregroundStyle(.tertiary).font(.title3).padding(.top, 3).padding(.leading, 5)
                    }
                    TextEditor(text: text).scrollContentBackground(.hidden).font(.title3)
                }
            }
            .padding(14)
        }
    }
}

/// Reusable tag picker — toggle chips for existing tags (so tags don't get
/// retyped per card) plus a field to add a new one.
struct TagChips: View {
    let suggestions: [String]
    @Binding var selected: Set<String>
    @State private var newTag = ""

    private var ordered: [String] {
        selected.sorted { $0.localizedCompare($1) == .orderedAscending }
        + suggestions.filter { !selected.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "tag").font(.caption2).foregroundStyle(.secondary)
                TextField("Add tag…", text: $newTag).textFieldStyle(.plain).font(.caption).onSubmit(addNew)
                if !newTag.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button(action: addNew) { Image(systemName: "plus.circle.fill") }
                        .buttonStyle(.borderless).font(.caption)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(.background.secondary, in: Capsule())

            if !ordered.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { ForEach(ordered, id: \.self) { chip($0) } }.padding(.vertical, 1)
                }
            }
        }
    }

    private func chip(_ t: String) -> some View {
        let on = selected.contains(t)
        return Button {
            if on { selected.remove(t) } else { selected.insert(t) }
        } label: {
            HStack(spacing: 3) {
                if on { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)) }
                Text(t).font(.caption2)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.background.secondary), in: Capsule())
            .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }.buttonStyle(.plain)
    }

    private func addNew() {
        let t = newTag.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        selected.insert(t); newTag = ""
    }
}

// MARK: - Card editor

struct CardEditor: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Flashcard
    @State private var selectedTags: Set<String>
    @State private var frontPlain: String
    @State private var blanks: Set<Int>
    @State private var flipped = false
    init(card: Flashcard) {
        _draft = State(initialValue: card)
        _selectedTags = State(initialValue: Set(card.tags))
        let parsed = Cloze.parse(card.front)
        _frontPlain = State(initialValue: parsed.plain)
        _blanks = State(initialValue: parsed.blanks)
    }
    private var allTags: [String] {
        Array(Set(state.data.flashcards.flatMap { $0.tags })).sorted { $0.localizedCompare($1) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            SubHeader("Card") {
                Button("Delete", role: .destructive) {
                    state.data.flashcards.removeAll { $0.id == draft.id }; dismiss()
                }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    FlipCardComposer(frontPlain: $frontPlain, back: $draft.back, blanks: $blanks, flipped: $flipped)
                    labeled("Tags") { TagChips(suggestions: allTags, selected: $selectedTags) }
                    labeled("Deck") {
                        Picker("", selection: $draft.deckID) {
                            ForEach(state.data.decks) { Text($0.name.isEmpty ? "Deck" : $0.name).tag($0.id) }
                        }.labelsHidden()
                    }
                    Text("Due \(draft.due.formatted(date: .abbreviated, time: .omitted)) · \(draft.reviews) reviews · \(draft.lapses) lapses")
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(14)
            }
            Divider()
            HStack { Spacer(); Button("Cancel") { dismiss() }
                Button("Save") { save() }.keyboardShortcut(.defaultAction) }.padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("").toolbar(.hidden, for: .windowToolbar)
    }

    @ViewBuilder private func labeled<C: View>(_ l: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(l).font(.caption).foregroundStyle(.secondary); c() }
    }
    private func save() {
        draft.tags = selectedTags.sorted()
        draft.front = Cloze.build(plain: frontPlain.trimmingCharacters(in: .whitespaces), blanks: blanks)
        if draft.front.trimmingCharacters(in: .whitespaces).isEmpty {
            state.data.flashcards.removeAll { $0.id == draft.id }
        } else if let i = state.data.flashcards.firstIndex(where: { $0.id == draft.id }) {
            state.data.flashcards[i] = draft
        }
        dismiss()
    }
}

// MARK: - CSV import

struct CSVImportView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let deckID: UUID
    @State private var text = ""

    private var parsed: [(String, String, [String])] {
        text.split(separator: "\n").compactMap { line in
            let raw = String(line)
            let parts = raw.contains("\t") ? raw.components(separatedBy: "\t")
                                           : raw.split(separator: ",", maxSplits: 2).map(String.init)
            guard let front = parts.first?.trimmingCharacters(in: .whitespaces), !front.isEmpty else { return nil }
            let back = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            let tags = parts.count > 2 ? parts[2].split(whereSeparator: { $0 == " " || $0 == ";" }).map(String.init) : []
            return (front, back, tags)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SubHeader("Import Cards")
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Paste one card per line: front, back  (comma or tab separated; optional third field = tags).")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $text).font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 160).scrollContentBackground(.hidden)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                Text("\(parsed.count) cards detected").font(.caption).foregroundStyle(.tint)
            }.padding(14)
            Divider()
            HStack { Spacer(); Button("Cancel") { dismiss() }
                Button("Import \(parsed.count)") { doImport() }.buttonStyle(.borderedProminent)
                    .disabled(parsed.isEmpty) }.padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("").toolbar(.hidden, for: .windowToolbar)
    }

    private func doImport() {
        for (front, back, tags) in parsed {
            state.data.flashcards.append(Flashcard(deckID: deckID, front: front, back: back, tags: tags))
        }
        dismiss()
    }
}

// MARK: - Study session

struct StudyView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let deckID: UUID
    var practiceAll = false
    @State private var queue: [UUID] = []
    @State private var revealed = false
    @State private var done = 0
    @State private var graded = 0
    @State private var agains = 0
    @State private var initialCount = 0
    @State private var editingCard: Flashcard?

    private var currentCard: Flashcard? {
        guard let id = queue.first else { return nil }
        return state.data.flashcards.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                if initialCount > 0 {
                    ProgressView(value: Double(done), total: Double(initialCount)).frame(maxWidth: 160)
                }
                Spacer()
                if let c = currentCard {
                    Button { editingCard = c } label: { Image(systemName: "pencil") }.buttonStyle(.borderless)
                }
                Text("\(queue.count) left").font(.caption).foregroundStyle(.secondary)
            }.padding(12)

            if let card = currentCard {
                Spacer()
                VStack(spacing: 14) {
                    faceText(card.isCloze ? Cloze.question(card.front) : card.front, font: .title2.bold())
                    if revealed {
                        Divider().frame(width: 120)
                        faceText(card.isCloze ? Cloze.answer(card.front) : card.back, font: .title3,
                                 color: card.isCloze ? .primary : .secondary)
                        if !card.tags.isEmpty {
                            Text(card.tags.map { "#\($0)" }.joined(separator: " "))
                                .font(.caption2).foregroundStyle(.tint)
                        }
                    }
                }
                .padding(24).frame(maxWidth: .infinity)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 16)
                Spacer()
                if revealed {
                    HStack(spacing: 8) {
                        ForEach(Array(SM2.Grade.allCases.enumerated()), id: \.element) { idx, g in
                            Button { grade(g) } label: {
                                VStack(spacing: 1) {
                                    Text(g.label).font(.caption.bold())
                                    Text(SM2.intervalPreview(card, grade: g)).font(.system(size: 9)).opacity(0.8)
                                }.frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered).tint(color(g))
                            .keyboardShortcut(KeyEquivalent(Character("\(idx + 1)")), modifiers: [])
                        }
                    }.padding(.horizontal, 16).padding(.bottom, 16)
                } else {
                    Button("Show answer") { revealed = true }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.space, modifiers: [])
                        .padding(.bottom, 16)
                }
            } else {
                Spacer()
                EmptyState(symbol: "checkmark.seal.fill", title: "Session complete",
                           subtitle: summary)
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent).padding(.bottom, 20)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("").toolbar(.hidden, for: .windowToolbar)
        .navigationDestination(item: $editingCard) { CardEditor(card: $0) }
        .onAppear {
            if queue.isEmpty {
                queue = state.data.flashcards
                    .filter { $0.deckID == deckID && (practiceAll || $0.isDue) }
                    .map(\.id).shuffled()
                initialCount = queue.count
            }
        }
    }

    /// Render a card face: math (LaTeX) via RichText, otherwise a centered Text.
    @ViewBuilder private func faceText(_ text: String, font: Font, color: Color = .primary) -> some View {
        if MathMarkdown.hasMath(text) {
            RichText(text: text).frame(maxWidth: .infinity)
        } else {
            Text(text).font(font).multilineTextAlignment(.center).foregroundStyle(color)
        }
    }

    private var summary: String {
        let acc = graded > 0 ? Int(round(Double(graded - agains) / Double(graded) * 100)) : 100
        return "\(done) cards reviewed · \(acc)% recalled."
    }

    private func grade(_ g: SM2.Grade) {
        guard let card = currentCard,
              let i = state.data.flashcards.firstIndex(where: { $0.id == card.id }) else { return }
        state.data.flashcards[i] = SM2.apply(card, grade: g)
        queue.removeFirst()
        graded += 1
        if g == .again { agains += 1; queue.append(card.id) } else { done += 1 }
        revealed = false
    }

    private func color(_ g: SM2.Grade) -> Color {
        switch g { case .again: return .red; case .hard: return .orange; case .good: return .blue; case .easy: return .green }
    }
}
