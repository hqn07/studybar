import SwiftUI
import UniformTypeIdentifiers

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
        .padding(DS.Space.m).background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
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
    @State private var matching = false
    @State private var testing = false
    @State private var editingCard: Flashcard?
    @State private var importing = false
    @State private var generating = false

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
        .navigationDestination(isPresented: $matching) { MatchView(deckID: deck.id) }
        .navigationDestination(isPresented: $testing) { TestView(deckID: deck.id) }
        .navigationDestination(item: $editingCard) { CardEditor(card: $0) }
        .navigationDestination(isPresented: $importing) { CSVImportView(deckID: deck.id) }
        .navigationDestination(isPresented: $generating) { GenerateCardsView(deckID: deck.id) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: { Image(systemName: "chevron.left").fontWeight(.semibold) }
                .buttonStyle(.borderless).help("Back").keyboardShortcut("[", modifiers: .command)
            Text(deck.name.isEmpty ? "Deck" : deck.name).font(.headline).lineLimit(1)
            CoursePicker(courseID: courseBinding)
            Spacer()
            Menu {
                if cards.count >= 4 {
                    Section("Study modes") {
                        Button { matching = true } label: { Label("Match game", systemImage: "square.grid.2x2") }
                        Button { testing = true } label: { Label("Test yourself", systemImage: "checklist") }
                    }
                    Divider()
                }
                if AIConfig.isReady {
                    Button { generating = true } label: { Label("Generate with AI…", systemImage: "sparkles") }
                    Divider()
                }
                Button { importing = true } label: { Label("Import from Anki / CSV…", systemImage: "square.and.arrow.down") }
                Button { exportFile() } label: { Label("Export for Anki…", systemImage: "square.and.arrow.up") }
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
                           subtitle: "Add front/back pairs above, or import an Anki/CSV file from the ⋯ menu.")
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
            .background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
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
        state.withUndo("Deleted deck") {
            state.data.flashcards.removeAll { $0.deckID == deck.id }
            state.data.decks.removeAll { $0.id == deck.id }
        }
        dismiss()
    }
    private func resetProgress() {
        for i in state.data.flashcards.indices where state.data.flashcards[i].deckID == deck.id {
            state.data.flashcards[i].reps = 0
            state.data.flashcards[i].interval = 0
            state.data.flashcards[i].ease = 2.5
            state.data.flashcards[i].due = .now
            state.data.flashcards[i].stability = 0
            state.data.flashcards[i].difficulty = 0
            state.data.flashcards[i].lastReview = nil
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

    /// Export the deck as an Anki-importable plain-text file (cloze back-converted).
    private func exportFile() {
        let text = AnkiText.export(cards.map { AnkiText.Card(front: $0.front, back: $0.back, tags: $0.tags) })
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(deck.name.isEmpty ? "deck" : deck.name).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
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
                                    .background(blanks.contains(i) ? AnyShapeStyle(.tint) : AnyShapeStyle(.sbSurface), in: Capsule())
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
                        .overlay(alignment: .topTrailing) { AITextMenu(text: text, showsLabel: false).padding(4) }
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
            .background(.sbSurface, in: Capsule())

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
            .background(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.sbSurface), in: Capsule())
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
                    state.withUndo("Deleted card") { state.data.flashcards.removeAll { $0.id == draft.id } }; dismiss()
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
    @State private var choosing = false
    @State private var importError = ""

    private var parsed: [AnkiText.Card] { AnkiText.parse(text) }
    private var existingFronts: Set<String> {
        Set(state.data.flashcards.filter { $0.deckID == deckID }.map { norm($0.front) })
    }
    private var newCards: [AnkiText.Card] {
        var seen = existingFronts
        return parsed.filter { seen.insert(norm($0.front)).inserted }   // also dedup within the paste
    }
    private var dupeCount: Int { parsed.count - newCards.count }
    private func norm(_ s: String) -> String { s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            SubHeader("Import Cards") {
                Button { choosing = true } label: { Label("Choose file…", systemImage: "folder") }
                    .buttonStyle(.borderless)
            }
            Divider()
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Text("Paste cards, or choose an Anki deck (.apkg) / export (.txt) / CSV file. Front, back, optional tags — Anki `{{c1::cloze}}` and HTML are handled.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $text).font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 160).scrollContentBackground(.hidden)
                    .background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                HStack(spacing: DS.Space.s) {
                    if !importError.isEmpty {
                        Text(importError).font(.caption).foregroundStyle(Color.dsNow)
                    } else if !parsed.isEmpty {
                        Chip("\(newCards.count) new", .status(.done))
                        if dupeCount > 0 { Chip("\(dupeCount) duplicate\(dupeCount == 1 ? "" : "s")", .status(.neutral)) }
                    } else if !text.isEmpty {
                        Text("No cards detected").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(14)
            Divider()
            HStack { Spacer(); Button("Cancel") { dismiss() }
                Button("Import \(newCards.count)") { doImport() }.buttonStyle(.borderedProminent)
                    .disabled(newCards.isEmpty) }.padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("").toolbar(.hidden, for: .windowToolbar)
        .fileImporter(isPresented: $choosing,
                      allowedContentTypes: [.plainText, .commaSeparatedText,
                                            UTType(filenameExtension: "tsv") ?? .plainText,
                                            UTType(filenameExtension: "txt") ?? .plainText,
                                            UTType(filenameExtension: "apkg") ?? .data]) { result in
            if case .success(let url) = result { loadFile(url) }
        }
    }

    private func loadFile(_ url: URL) {
        importError = ""
        if url.pathExtension.lowercased() == "apkg" {
            let r = ApkgImport.read(url)
            if let e = r.error { importError = e; text = "" }
            else { text = AnkiText.export(r.cards) }   // funnel through the shared preview/dedup path
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let s = try? String(contentsOf: url, encoding: .utf8) { text = s }
    }

    private func doImport() {
        for c in newCards {
            state.data.flashcards.append(Flashcard(deckID: deckID, front: c.front, back: c.back, tags: c.tags))
        }
        dismiss()
    }
}

// MARK: - AI card generation (on-object, propose → accept)

/// Turn a student's own material (pasted, or pulled from a note) into flashcards. The AI
/// only ever proposes — every card is shown for review, editable, with a per-card toggle;
/// nothing lands in the deck until the user taps Add. Duplicates of existing fronts are skipped.
struct GenerateCardsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let deckID: UUID

    struct PropCard: Identifiable { let id = UUID(); var front: String; var back: String; var include = true }

    @State private var source = ""
    @State private var loading = false
    @State private var raw = ""
    @State private var proposed: [PropCard] = []
    @State private var genError = false
    @State private var task: Task<Void, Never>?

    private var includedCount: Int { proposed.filter(\.include).count }
    private var canGenerate: Bool {
        AIConfig.isReady && !loading && source.trimmingCharacters(in: .whitespacesAndNewlines).count >= 20
    }

    var body: some View {
        VStack(spacing: 0) {
            SubHeader("Generate Cards") {
                if !state.data.notes.isEmpty {
                    Menu {
                        ForEach(state.data.notes.prefix(60)) { n in
                            Button(n.title.isEmpty ? "Untitled note" : n.title) { source = n.body }
                        }
                    } label: { Label("From a note…", systemImage: "note.text") }.buttonStyle(.borderless)
                }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    Text("Paste your material (or pull a note), then let AI draft flashcards. You pick and edit which to keep — nothing is added until you tap Add.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $source).font(.callout)
                        .frame(minHeight: 120).scrollContentBackground(.hidden)
                        .background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                    Button { generate() } label: {
                        Label(loading ? "Generating…" : "Generate cards", systemImage: "sparkles")
                    }.buttonStyle(.borderedProminent).disabled(!canGenerate)
                    if !AIConfig.isReady {
                        Text("Turn on an engine in Settings ▸ Intelligence first.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    if loading {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Drafting from your material…").font(.caption).foregroundStyle(.secondary)
                        }
                        if !raw.isEmpty {
                            Text(raw).font(.caption.monospaced()).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else if !proposed.isEmpty {
                        HStack {
                            Text("\(includedCount) card\(includedCount == 1 ? "" : "s") selected").font(.caption.weight(.medium))
                            Spacer()
                            Text("Edit any card before adding").font(.caption2).foregroundStyle(.secondary)
                        }
                        ForEach($proposed) { $c in
                            HStack(alignment: .top, spacing: 8) {
                                Button { c.include.toggle() } label: {
                                    Image(systemName: c.include ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(c.include ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                }.buttonStyle(.plain).padding(.top, 3)
                                VStack(spacing: 4) {
                                    TextField("Front", text: $c.front).textFieldStyle(.roundedBorder)
                                    TextField("Back", text: $c.back).textFieldStyle(.roundedBorder)
                                }
                            }.opacity(c.include ? 1 : 0.5)
                        }
                    } else if genError {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Couldn't read cards from the reply — none added.", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                            Text("Tap Generate again, or switch to a stronger engine in Settings ▸ Intelligence. Raw reply:")
                                .font(.caption2).foregroundStyle(.secondary)
                            if !raw.isEmpty {
                                Text(raw).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                            }
                        }
                    }
                }.padding(14)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { task?.cancel(); dismiss() }
                Button("Add \(includedCount)") { add() }.buttonStyle(.borderedProminent).disabled(includedCount == 0)
            }.padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("").toolbar(.hidden, for: .windowToolbar)
    }

    private func generate() {
        guard AIConfig.isReady, let provider = AIService.makeProvider() else { return }
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 20 else { return }
        loading = true; raw = ""; proposed = []; genError = false
        let sys = "You create study flashcards from a student's own material. Output ONE flashcard per line as `Front / Back` — the front, then a space, a slash, a space, then the back. Example: `What is present worth? / A method that discounts future cash flows to the present using the MARR.` Front = a question or term; back = a short answer or definition. 5–15 cards covering the key facts, terms, definitions, dates, and numbers. Use only what's in the material — do not invent. No numbering, no preamble, no other text."
        task?.cancel()
        task = Task {
            let msgs = [AIMessage(role: .user, text: text)]
            let out: String?
            if let ollama = provider as? OllamaProvider {
                out = try? await ollama.completePlainStreaming(system: sys, messages: msgs) { p in raw = p }
            } else {
                out = try? await provider.completePlain(system: sys, messages: msgs)
            }
            await MainActor.run {
                loading = false
                let cards = parseCards(out ?? raw)
                proposed = cards
                genError = cards.isEmpty
            }
        }
    }

    /// Tolerant of however the model actually formatted the cards — weak local models rarely
    /// obey the `::` instruction. Tries, in order: a `::`/`|`/tab delimiter per line; then
    /// blank-line-separated blocks (first line = front, rest = back — the common Q?/A layout);
    /// then consecutive line pairs. Strips numbering and Q:/A:/Front:/Back: prefixes.
    private func parseCards(_ s: String) -> [PropCard] {
        let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        func clean(_ t: String) -> String {
            t.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"^\s*(\d+[.)]|[-•*])\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"(?i)^\s*(front|back|q(?:uestion)?|a(?:nswer)?)\s*[:.)\-]\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }

        // 1) Delimiter per line. Space-padded " / " and " | " so mid-content slashes/pipes
        //    ("benefit/cost") don't split; `::` and tab are unambiguous.
        for d in ["::", " / ", " | ", "\t"] {
            let cards: [PropCard] = text.split(whereSeparator: \.isNewline).compactMap { line in
                let raw = String(line)
                guard raw.contains(d) else { return nil }
                let parts = raw.components(separatedBy: d)
                guard parts.count >= 2 else { return nil }
                let f = clean(parts[0]); let b = clean(parts[1...].joined(separator: d))
                return (!f.isEmpty && !b.isEmpty) ? PropCard(front: f, back: b) : nil
            }
            if cards.count >= 2 { return cards }
        }

        // Group into blocks separated by blank lines.
        var blocks: [[String]] = []; var cur: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if raw.trimmingCharacters(in: .whitespaces).isEmpty {
                if !cur.isEmpty { blocks.append(cur); cur = [] }
            } else { cur.append(String(raw)) }
        }
        if !cur.isEmpty { blocks.append(cur) }

        // 2) Blank-line-separated cards: first line = front, remaining lines = back.
        if blocks.count >= 2 {
            let cards = blocks.compactMap { lines -> PropCard? in
                guard lines.count >= 2 else { return nil }
                let f = clean(lines[0]); let b = clean(lines[1...].joined(separator: " "))
                return (!f.isEmpty && !b.isEmpty) ? PropCard(front: f, back: b) : nil
            }
            if !cards.isEmpty { return cards }
        }

        // 3) Last resort: pair up consecutive non-empty lines.
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var out: [PropCard] = []; var i = 0
        while i + 1 < lines.count {
            let f = clean(lines[i]); let b = clean(lines[i + 1])
            if !f.isEmpty, !b.isEmpty { out.append(PropCard(front: f, back: b)); i += 2 } else { i += 1 }
        }
        return out
    }

    private func add() {
        var seen = Set(state.data.flashcards.filter { $0.deckID == deckID }
            .map { $0.front.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) })
        for c in proposed where c.include {
            let key = c.front.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            state.data.flashcards.append(Flashcard(deckID: deckID, front: c.front, back: c.back))
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
                .background(.sbSurface, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 16)
                Spacer()
                if revealed {
                    HStack(spacing: 8) {
                        ForEach(Array(SM2.Grade.allCases.enumerated()), id: \.element) { idx, g in
                            Button { grade(g) } label: {
                                VStack(spacing: 1) {
                                    Text(g.label).font(.caption.bold())
                                    Text(FSRS.intervalPreview(card, grade: g)).font(.system(size: 9)).opacity(0.8)
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
        state.data.flashcards[i] = FSRS.apply(card, grade: g)
        queue.removeFirst()
        graded += 1
        if g == .again { agains += 1; queue.append(card.id) } else { done += 1 }
        revealed = false
    }

    private func color(_ g: SM2.Grade) -> Color {
        switch g { case .again: return .red; case .hard: return .orange; case .good: return .blue; case .easy: return .green }
    }
}

// MARK: - Match game (Quizlet-style pairing — practice only, no FSRS scheduling)

/// Tap a term, then its definition. Correct pairs fade out; mismatches flash. Times you.
struct MatchView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let deckID: UUID

    private struct Tile: Identifiable, Equatable { let id = UUID(); let pair: UUID; let text: String; let isTerm: Bool }
    @State private var tiles: [Tile] = []
    @State private var picked: UUID? = nil
    @State private var gone: Set<UUID> = []
    @State private var wrong: Set<UUID> = []
    @State private var startAt = Date()
    @State private var finishedAt: Date? = nil

    private var pairCount: Int { tiles.count / 2 }
    private var done: Bool { !tiles.isEmpty && gone.count == tiles.count }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if done { result } else { grid }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("").toolbar(.hidden, for: .windowToolbar)
        .onAppear { if tiles.isEmpty { build() } }
    }

    private var header: some View {
        HStack(spacing: DS.Space.m) {
            Button { dismiss() } label: { Image(systemName: "chevron.left").fontWeight(.semibold) }
                .buttonStyle(.borderless).keyboardShortcut("[", modifiers: .command)
            Text("Match").font(.headline)
            Spacer()
            if !done {
                TimelineView(.periodic(from: startAt, by: 0.1)) { ctx in
                    Text(String(format: "%.1fs", (finishedAt ?? ctx.date).timeIntervalSince(startAt)))
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text("\(gone.count / 2)/\(pairCount)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Button { build() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Shuffle")
        }.padding(12)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 10)], spacing: 10) {
                ForEach(tiles) { tile in
                    let isGone = gone.contains(tile.id)
                    Button { tap(tile) } label: {
                        Text(tile.text).font(.callout).multilineTextAlignment(.center).lineLimit(4)
                            .frame(maxWidth: .infinity, minHeight: 62).padding(8)
                            .background(fill(tile), in: RoundedRectangle(cornerRadius: DS.Radius.card))
                            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card)
                                .strokeBorder(stroke(tile), lineWidth: 1.2))
                    }
                    .buttonStyle(.plain).disabled(isGone)
                    .opacity(isGone ? 0 : 1).animation(.easeOut(duration: 0.2), value: isGone)
                }
            }.padding(14)
        }
    }

    private var result: some View {
        VStack(spacing: DS.Space.l) {
            Image(systemName: "checkmark.seal.fill").font(.largeTitle).foregroundStyle(Color.dsDone)
            Text("Matched \(pairCount) pairs").font(.title3.weight(.semibold))
            if let f = finishedAt {
                Text(String(format: "in %.1f seconds", f.timeIntervalSince(startAt)))
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: DS.Space.m) {
                Button { build() } label: { Label("Play again", systemImage: "arrow.clockwise") }.buttonStyle(.borderedProminent)
                Button("Done") { dismiss() }.buttonStyle(.bordered)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fill(_ t: Tile) -> AnyShapeStyle {
        if picked == t.id { return AnyShapeStyle(.tint.opacity(0.18)) }
        if wrong.contains(t.id) { return AnyShapeStyle(Color.dsNow.opacity(0.18)) }
        return AnyShapeStyle(.sbSurface)
    }
    private func stroke(_ t: Tile) -> Color {
        if picked == t.id { return .accentColor }
        if wrong.contains(t.id) { return .dsNow }
        return .clear
    }

    private func build() {
        let cards = state.data.flashcards
            .filter { $0.deckID == deckID && !$0.front.isEmpty && !$0.back.isEmpty }
            .shuffled().prefix(6)
        var t: [Tile] = []
        for c in cards {
            t.append(Tile(pair: c.id, text: Cloze.parse(c.front).plain, isTerm: true))
            t.append(Tile(pair: c.id, text: c.back, isTerm: false))
        }
        tiles = t.shuffled(); picked = nil; gone = []; wrong = []; startAt = Date(); finishedAt = nil
    }

    private func tap(_ tile: Tile) {
        guard !gone.contains(tile.id), finishedAt == nil, wrong.isEmpty else { return }
        guard let first = picked else { picked = tile.id; return }
        if first == tile.id { picked = nil; return }
        let a = tiles.first { $0.id == first }, b = tile
        if let a, a.pair == b.pair, a.isTerm != b.isTerm {
            gone.insert(first); gone.insert(tile.id); picked = nil
            if gone.count == tiles.count { finishedAt = Date() }
        } else {
            wrong = [first, tile.id]; picked = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { wrong = [] }
        }
    }
}

// MARK: - Test (multiple-choice quiz — practice only, no FSRS scheduling)

/// A quick multiple-choice quiz over the deck: the card's front, four options drawn from
/// other cards' backs. Scores at the end. Doesn't change scheduling.
struct TestView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let deckID: UUID

    private struct Q: Identifiable { let id = UUID(); let front: String; let answer: String; let options: [String] }
    @State private var qs: [Q] = []
    @State private var idx = 0
    @State private var score = 0
    @State private var picked: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if qs.isEmpty {
                EmptyState(symbol: "checklist", title: "Not enough cards",
                           subtitle: "Add a few more cards with distinct answers to take a test.")
            } else if idx >= qs.count {
                result
            } else {
                question(qs[idx])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("").toolbar(.hidden, for: .windowToolbar)
        .onAppear { if qs.isEmpty { build() } }
    }

    private var header: some View {
        HStack(spacing: DS.Space.m) {
            Button { dismiss() } label: { Image(systemName: "chevron.left").fontWeight(.semibold) }
                .buttonStyle(.borderless).keyboardShortcut("[", modifiers: .command)
            Text("Test").font(.headline)
            Spacer()
            if !qs.isEmpty && idx < qs.count {
                Text("\(idx + 1)/\(qs.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }.padding(12)
    }

    private func question(_ q: Q) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            Text(q.front).font(.title3.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Space.l)
                .background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            VStack(spacing: DS.Space.s) {
                ForEach(q.options, id: \.self) { opt in
                    Button { if picked == nil { picked = opt; if opt == q.answer { score += 1 } } } label: {
                        HStack {
                            Text(opt).multilineTextAlignment(.leading)
                            Spacer(minLength: DS.Space.s)
                            if picked != nil && opt == q.answer { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.dsDone) }
                            else if picked == opt { Image(systemName: "xmark.circle.fill").foregroundStyle(Color.dsNow) }
                        }
                        .padding(DS.Space.m).frame(maxWidth: .infinity, alignment: .leading)
                        .background(optionFill(opt, q), in: RoundedRectangle(cornerRadius: DS.Radius.card))
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(optionStroke(opt, q), lineWidth: 1))
                    }.buttonStyle(.plain)
                }
            }
            if picked != nil {
                Button { idx += 1; picked = nil } label: {
                    Label(idx + 1 == qs.count ? "See score" : "Next", systemImage: "arrow.right").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent)
            }
            Spacer()
        }.padding(DS.Space.l)
    }

    private func optionFill(_ opt: String, _ q: Q) -> AnyShapeStyle {
        guard let picked else { return AnyShapeStyle(.sbSurface) }
        if opt == q.answer { return AnyShapeStyle(Color.dsDone.opacity(0.15)) }
        if opt == picked { return AnyShapeStyle(Color.dsNow.opacity(0.15)) }
        return AnyShapeStyle(.sbSurface)
    }
    private func optionStroke(_ opt: String, _ q: Q) -> Color {
        guard picked != nil else { return .clear }
        if opt == q.answer { return .dsDone }
        if opt == picked { return .dsNow }
        return .clear
    }

    private var result: some View {
        let pct = qs.isEmpty ? 0 : Int(round(Double(score) / Double(qs.count) * 100))
        return VStack(spacing: DS.Space.l) {
            Image(systemName: pct >= 80 ? "checkmark.seal.fill" : "flag.checkered")
                .font(.largeTitle).foregroundStyle(pct >= 80 ? Color.dsDone : .accentColor)
            Text("\(score) / \(qs.count) correct").font(.title2.weight(.semibold))
            Text("\(pct)%").font(.callout).foregroundStyle(.secondary)
            HStack(spacing: DS.Space.m) {
                Button { build() } label: { Label("Retake", systemImage: "arrow.clockwise") }.buttonStyle(.borderedProminent)
                Button("Done") { dismiss() }.buttonStyle(.bordered)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func build() {
        let cards = state.data.flashcards.filter { $0.deckID == deckID && !$0.front.isEmpty && !$0.back.isEmpty }
        let backs = Array(Set(cards.map(\.back)))
        guard cards.count >= 2 && backs.count >= 2 else { qs = []; idx = 0; score = 0; picked = nil; return }
        qs = cards.shuffled().prefix(12).map { c in
            var opts = [c.back]
            let distractors = backs.filter { $0 != c.back }.shuffled().prefix(3)
            opts.append(contentsOf: distractors)
            return Q(front: Cloze.parse(c.front).plain, answer: c.back, options: opts.shuffled())
        }
        idx = 0; score = 0; picked = nil
    }
}
