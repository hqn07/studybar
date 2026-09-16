import SwiftUI
import UniformTypeIdentifiers

enum NoteSort: String, CaseIterable, Identifiable {
    case updated = "Last edited", created = "Date created", title = "Title"
    var id: String { rawValue }
}

/// A note being opened, plus whether it should land in reading (preview) or editing mode —
/// existing notes open to read, brand-new / template notes open ready to type.
struct OpenNote: Identifiable, Hashable { let note: Note; let preview: Bool; var id: UUID { note.id } }

struct NotesView: View {
    @EnvironmentObject var state: AppState
    @State private var editing: OpenNote?       // narrow/popover: pushed note
    @State private var selection: UUID?         // wide window: selected note in the split
    @State private var newDraft: Note?          // wide window: a not-yet-saved new note
    @State private var search = ""
    // Notes are taken on a date and looked for by that date, so "Date created" is the
    // default order. @AppStorage, not @State: the sort a user picks is a preference, and
    // it used to reset to "Last edited" on every launch.
    @AppStorage("notesSort") private var sort = NoteSort.created
    @State private var scope: NoteScope = .all

    /// The split (list + editor) needs real width; below this we push one note at a time.
    private let splitMinWidth: CGFloat = 640
    /// Width of the list pane in the split, dragged by the divider between the two. Persisted:
    /// how much list you want beside a note is a working preference, not a per-session whim.
    @AppStorage("notesListWidth") private var listWidth: Double = 268
    /// Hide the list and give the whole pane to the note you're in. Lighter than focus mode —
    /// the module header, the rail and the editor's own chrome all stay.
    @AppStorage("notesListHidden") private var listHidden = false
    /// The note that was open when you last left. Reopening to a list you then have to search
    /// is a step; reopening to what you were reading is none.
    @AppStorage("lastOpenNote") private var lastOpenNote = ""
    @State private var restoredLastNote = false
    private static let listWidthRange: ClosedRange<CGFloat> = 200...460

    /// Which course slice the list is showing. Tabs across the top switch it.
    enum NoteScope: Hashable { case all, untagged, course(UUID) }

    /// Courses that actually own a note, in the app's course order — the tab set.
    private var coursesWithNotes: [Course] {
        let used = Set(state.data.notes.compactMap(\.courseID))
        return state.data.courses.filter { used.contains($0.id) }
    }
    private var hasUntagged: Bool { state.data.notes.contains { $0.courseID == nil } }
    /// Only worth showing tabs once notes span at least one course.
    private var showTabs: Bool { !coursesWithNotes.isEmpty }

    private var notes: [Note] {
        var list = state.data.notes
        switch scope {
        case .all: break
        case .untagged: list = list.filter { $0.courseID == nil }
        case .course(let id): list = list.filter { $0.courseID == id }
        }
        if !search.isEmpty {
            // Fuzzy + relevance-ranked while searching (overrides the sort picker).
            return list.compactMap { n in FuzzyMatch.best(search, [n.title, n.body] + n.tags).map { (n, $0) } }
                .sorted { $0.1 > $1.1 }.map(\.0)
        }
        switch sort {
        case .updated: list.sort { $0.updatedAt > $1.updatedAt }
        case .created: list.sort { $0.createdAt > $1.createdAt }
        case .title:   list.sort { $0.title.localizedCompare($1.title) == .orderedAscending }
        }
        // Pinned always float to the top.
        return list.sorted { ($0.pinned ? 1 : 0) > ($1.pinned ? 1 : 0) }
    }

    /// The list broken into labelled sections: Pinned first, then soft date buckets (Today /
    /// This week / Earlier) on whichever date the sort uses. Flat (one unlabelled section)
    /// while searching or sorting by title, so the header never contradicts the order.
    private var notesSections: [(id: String, title: String?, notes: [Note])] {
        let all = notes
        if !search.isEmpty { return [("all", nil, all)] }
        let pinned = all.filter(\.pinned)
        let rest = all.filter { !$0.pinned }
        var out: [(String, String?, [Note])] = []
        if !pinned.isEmpty { out.append(("pinned", "Pinned", pinned)) }
        // Inside a course, lecture notes are kept per class session, so the week of the term
        // is the axis that matches how they were written — "Week 3" beside the three notes
        // the user titled that by hand. Outside a course (All / Untagged) the soft date
        // buckets stay, since weeks from different courses interleave meaninglessly.
        if case .course = scope, sort != .title, state.data.termStart != nil {
            var buckets: [Int: [Note]] = [:]
            var undated: [Note] = []
            for n in rest {
                if let w = SemesterWeek.number(for: n.createdAt, termStart: state.data.termStart) {
                    buckets[w, default: []].append(n)
                } else {
                    undated.append(n)
                }
            }
            for w in buckets.keys.sorted(by: >) {
                out.append(("week-\(w)", "Week \(w)", buckets[w] ?? []))
            }
            if !undated.isEmpty { out.append(("before", "Before the term", undated)) }
            return out
        }
        if sort != .title {
            // Bucket on the date the list is ordered by, or the headers describe one date
            // while the rows are in the order of another.
            let date: (Note) -> Date = sort == .created ? { $0.createdAt } : { $0.updatedAt }
            let cal = Calendar.current
            let weekAgo = cal.date(byAdding: .day, value: -7, to: .now) ?? .now
            let today = rest.filter { cal.isDateInToday(date($0)) }
            let week = rest.filter { !cal.isDateInToday(date($0)) && date($0) >= weekAgo }
            let earlier = rest.filter { date($0) < weekAgo }
            for (id, t, g) in [("today", "Today", today), ("week", "This week", week), ("earlier", "Earlier", earlier)] where !g.isEmpty {
                out.append((id, t, g))
            }
        } else if !rest.isEmpty {
            out.append(("rest", pinned.isEmpty ? nil : "Notes", rest))
        }
        return out
    }

    private func sectionHeader(_ t: String) -> some View {
        Text(t.uppercased())
            .font(.caption2.weight(.bold)).tracking(0.6).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6).padding(.top, DS.Space.s).padding(.bottom, 1)
    }

    var body: some View {
        GeometryReader { geo in
            let split = geo.size.width >= splitMinWidth
            // In focus mode the note is the whole module: no "Notes" header, no list, and
            // RootView has already dropped the rail and the window header around us.
            let writing = state.focusMode && split && selection != nil
            NavigationStack {
                Group {
                    if writing {
                        // Nothing is drawn above the note in focus mode, so it leaves its own
                        // room for the traffic lights floating in the titlebar strip.
                        detailPane.padding(.top, 26)
                    } else {
                        ModulePane(title: "Notes") { toolbar(split: split) } content: {
                            if split { splitBody(available: geo.size.width) } else { stackBody }
                        }
                    }
                }
                .navigationDestination(item: $editing) { target in
                    NoteEditor(note: target.note, startInPreview: target.preview, onNavigate: { id in
                        if let n = state.data.notes.first(where: { $0.id == id }) { editing = OpenNote(note: n, preview: true) }
                    })
                }
                .onAppear { consumePending(split: split); restoreLastNote(split: split) }
                // The first layout pass can report a zero width, so `split` is only truthful
                // on the second — restore has to survive that, or it silently never runs.
                .onChange(of: split) { _, s in restoreLastNote(split: s) }
                .onChange(of: state.pendingNew) { _, _ in consumePending(split: split) }
                .onChange(of: state.pendingOpenNote) { _, _ in consumePending(split: split) }
                .onChange(of: selection) { _, id in if let id { lastOpenNote = id.uuidString } }
            }
        }
    }

    @ViewBuilder private func toolbar(split: Bool) -> some View {
        HStack(spacing: 8) {
            if split {
                Button { withAnimation(.snappy(duration: 0.22)) { listHidden.toggle() } } label: {
                    Image(systemName: listHidden ? "sidebar.left" : "sidebar.leading")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(listHidden ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .help(listHidden ? "Show the note list (⇧⌘L)" : "Hide the note list — keep just this note (⇧⌘L)")
                // Without this VoiceOver reads the SF Symbol's name — "Toggle Sidebar" — which
                // is also what the module rail's button is called.
                .accessibilityLabel(listHidden ? "Show the note list" : "Hide the note list")
            }
            // Focus mode with no note on screen (nothing selected, or a window too narrow to
            // split) would otherwise be a room with the door painted over: the shell has hidden
            // the rail and the header, and the editor's own exit button isn't showing either.
            if state.focusMode {
                Button { withAnimation(.easeInOut(duration: 0.2)) { state.focusMode = false } } label: {
                    Label("Exit focus", systemImage: "arrow.down.right.and.arrow.up.left")
                }
                .buttonStyle(.borderless).controlSize(.small).foregroundStyle(.tint)
                .help("Exit focus mode (⇧⌘F)")
            }
            Menu {
                Section("Sort") {
                    ForEach(NoteSort.allCases) { s in
                        Button { sort = s } label: { Label(s.rawValue, systemImage: sort == s ? "checkmark" : "arrow.up.arrow.down") }
                    }
                }
                Section("New from template") {
                    ForEach(NoteTemplates.all) { t in
                        Button { newFromTemplate(t, split: split) } label: { Label(t.name, systemImage: t.symbol) }
                    }
                }
            } label: { Image(systemName: "ellipsis.circle") }
            Button { newNote(split: split) } label: { Image(systemName: "square.and.pencil") }
                .keyboardShortcut("n", modifiers: .command).help("New note")
        }
    }

    // MARK: Narrow / popover — list that pushes one note

    /// Course tabs — All · one per course with notes · Untagged. Filters the list so a
    /// heavy notebook stays navigable. Hidden until at least one note is course-tagged.
    @ViewBuilder private var courseTabBar: some View {
        if showTabs {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    tabChip("All", scope: .all)
                    ForEach(coursesWithNotes) { c in
                        tabChip(c.code.isEmpty ? c.name : c.code, scope: .course(c.id), dot: c.color)
                    }
                    if hasUntagged { tabChip("Untagged", scope: .untagged) }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
            }
            Divider()
        }
    }

    private func tabChip(_ label: String, scope s: NoteScope, dot: Color? = nil) -> some View {
        Button { scope = s } label: {
            Chip(label, .filter, selected: scope == s, dot: dot)
        }.buttonStyle(.plain)
    }

    private var stackBody: some View {
        VStack(spacing: 0) {
            courseTabBar
            if state.data.notes.count > 4 { SearchField(text: $search).padding(8); Divider() }
            if notes.isEmpty {
                notesEmptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(notesSections, id: \.id) { sec in
                            if let t = sec.title { sectionHeader(t) }
                            ForEach(sec.notes) { n in NoteRow(note: n, showCreated: sort == .created) { editing = OpenNote(note: n, preview: true) } }
                        }
                    }.padding(10)
                }
            }
        }
    }

    // MARK: Wide window — master-detail split

    private func splitBody(available: CGFloat) -> some View {
        // The editor keeps at least 340pt whatever the saved list width says, so narrowing the
        // window squeezes the list rather than the note.
        let maxList = max(Self.listWidthRange.lowerBound, available - 340)
        let shown = min(CGFloat(listWidth), maxList)
        // Hiding the list only makes sense while a note is open: with nothing selected it
        // would leave "No note selected" and no way to select one.
        let hideList = listHidden && selection != nil
        return HStack(spacing: 0) {
            if !hideList {
                listPane.frame(width: shown)
                PaneDivider(width: Binding(get: { CGFloat(listWidth) }, set: { listWidth = Double($0) }),
                            range: Self.listWidthRange.lowerBound...min(Self.listWidthRange.upperBound, maxList),
                            resetTo: 268)
            }
            detailPane.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.snappy(duration: 0.22), value: hideList)
    }

    private var listPane: some View {
        VStack(spacing: 0) {
            courseTabBar
            if state.data.notes.count > 4 { SearchField(text: $search).padding(8); Divider() }
            if notes.isEmpty {
                notesEmptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(notesSections, id: \.id) { sec in
                                if let t = sec.title { sectionHeader(t) }
                                ForEach(sec.notes) { n in
                                    NoteRow(note: n, selected: n.id == selection, showCreated: sort == .created) { select(n.id) }
                                        .id(n.id)
                                }
                            }
                        }.padding(8)
                    }
                    .keyboardListNav(ids: notes.map(\.id), selection: $selection,
                                     onActivate: { select($0) }, onEscape: { selection = nil })
                    .onChange(of: selection) { _, id in
                        if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
            }
        }
        .background(.sbSurface.opacity(0.35))
    }

    @ViewBuilder private var detailPane: some View {
        if let sel = selection, let note = noteForSelection(sel) {
            NoteEditor(note: note, embedded: true, startInPreview: newDraft?.id != sel,
                       onClose: { selection = nil; newDraft = nil },
                       onNavigate: { select($0) })
                .id(sel)   // switching notes rebuilds the editor → old one autosaves on teardown
        } else {
            EmptyState(symbol: "note.text", title: "No note selected",
                       subtitle: "Pick a note from the list, or ⌘N to start a new one.")
        }
    }

    private var notesEmptyState: some View {
        EmptyState(symbol: "note.text",
                   title: state.data.notes.isEmpty ? "No notes yet" : "No matches",
                   subtitle: state.data.notes.isEmpty ? "Capture ideas, lecture notes and reminders. Markdown supported." : "Try a different search.",
                   actionTitle: state.data.notes.isEmpty ? "New note" : "Clear search",
                   action: { if state.data.notes.isEmpty { newNote(split: true) } else { search = "" } })
    }

    /// The note behind the current selection — a saved note, or the pending new draft.
    private func noteForSelection(_ id: UUID) -> Note? {
        state.data.notes.first { $0.id == id } ?? (newDraft?.id == id ? newDraft : nil)
    }
    private func select(_ id: UUID) { selection = id; newDraft = nil }

    // MARK: Actions (fork by surface width)

    /// Reopen whatever was last being read, once per appearance.
    private func restoreLastNote(split: Bool) {
        guard split, !restoredLastNote, selection == nil, newDraft == nil,
              state.pendingOpenNote == nil, state.pendingNew == nil,
              let id = UUID(uuidString: lastOpenNote),
              state.data.notes.contains(where: { $0.id == id }) else { return }
        restoredLastNote = true
        selection = id
    }

    private func consumePending(split: Bool) {
        if state.pendingNew == "notes" { state.pendingNew = nil; newNote(split: split) }

        // A note the palette asked for: clear whatever filter would hide it, then open it.
        if let id = state.pendingOpenNote, let note = state.data.notes.first(where: { $0.id == id }) {
            state.pendingOpenNote = nil
            search = ""
            scope = .all
            if split { selection = note.id } else { editing = OpenNote(note: note, preview: true) }
        }
    }
    private func newNote(split: Bool) {
        var n = Note()
        if case .course(let id) = scope {
            n.courseID = id                                   // inherit the active course tab
            // …and the week, which is what the title would have started with anyway.
            if let prefix = SemesterWeek.noteTitlePrefix(termStart: state.data.termStart) {
                n.title = prefix
            }
        }
        if split { newDraft = n; selection = n.id }   // editor inserts it on first edit
        else { editing = OpenNote(note: n, preview: false) }   // new note → start editing
    }

    private func newFromTemplate(_ t: NoteTemplates.Template, split: Bool) {
        let attr = t.build()
        var n = Note(title: t.title)
        if case .course(let id) = scope { n.courseID = id }   // inherit the active course tab
        n.rich = attr.rtfdData(); n.body = attr.string
        state.data.notes.append(n)                    // has content → insert now
        if split { selection = n.id; newDraft = nil } else { editing = OpenNote(note: n, preview: false) }
    }

}

/// Loads a screenshot attachment by filename.
func screenshotImage(_ name: String) -> NSImage? {
    guard !name.isEmpty else { return nil }
    return NSImage(contentsOf: ScreenshotService.directory.appendingPathComponent(name))
}

struct NoteRow: View {
    @EnvironmentObject var state: AppState
    let note: Note
    var selected: Bool = false
    /// Show the created date rather than the edited one — set when the list is sorted by
    /// creation, so the row's date is the one the reader is scanning for.
    var showCreated: Bool = false
    let onOpen: () -> Void

    init(note: Note, selected: Bool = false, showCreated: Bool = false, onOpen: @escaping () -> Void) {
        self.note = note; self.selected = selected; self.showCreated = showCreated; self.onOpen = onOpen
    }

    private var isEmpty: Bool { note.previewText.isEmpty }
    private var spineColor: Color { state.course(note.courseID)?.color ?? .accentColor }

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 0) {
                // Course-color spine.
                Rectangle().fill(spineColor.opacity(isEmpty ? 0.35 : 0.9)).frame(width: 3)
                HStack(alignment: .top, spacing: 10) {
                    if let img = screenshotImage(note.imagePath) {
                        Image(nsImage: img).resizable().scaledToFill()
                            .frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            if note.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
                            Text(note.listTitle)
                                .fontWeight(.semibold).lineLimit(1)
                                .foregroundStyle(isEmpty ? .secondary : .primary)
                            if isEmpty {
                                Text("empty").font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(.sbSurface2, in: Capsule())
                            }
                        }
                        if !isEmpty {
                            Text(note.previewText)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        metaLine
                    }
                    Spacer(minLength: 0)
                }
                .padding(DS.Space.m)
            }
            .contentShape(Rectangle())
            .background(selected ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.sbSurface),
                        in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(.tint.opacity(0.5), lineWidth: 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))   // clip the spine to the card corners
        }.buttonStyle(.plain)
    }

    /// Course · when-edited · length, plus any tags — the quiet context line under a row.
    private var metaLine: some View {
        HStack(spacing: 6) {
            if let c = state.course(note.courseID) {
                Circle().fill(c.color).frame(width: 5, height: 5)
                Text(c.code.isEmpty ? c.name : c.code).lineLimit(1)
                Text("·")
            }
            Text(isEmpty || showCreated ? "created \(note.createdAt.relativeShort)" : "edited \(note.updatedAt.relativeShort)")
            if !isEmpty {
                Text("·")
                Text("\(note.wordCount) word\(note.wordCount == 1 ? "" : "s")").monospacedDigit()
            }
            ForEach(note.tags.prefix(2), id: \.self) { t in
                Text("#\(t)").foregroundStyle(.tint).lineLimit(1)
            }
            if note.tags.count > 2 { Text("+\(note.tags.count - 2)") }
        }
        // One line, truncated — not wrapped. In a narrow list "created 1 day ago" broke across
        // two lines mid-phrase and pushed the row taller than its neighbours.
        .lineLimit(1)
        .truncationMode(.tail)
        .font(.caption2).foregroundStyle(.tertiary)
        .padding(.top, 1)
    }
}

struct NoteEditor: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var editor = RichTextController()
    @State private var draft: Note
    @State private var tagText: String
    @State private var showPreview = false
    @State private var saveTask: Task<Void, Never>?
    @State private var defineTerm = ""
    @State private var defineResult: String?
    @State private var foldPrompt = false
    @State private var foldTitle = ""
    @State private var colorMode: ColorMode?
    @State private var splitLive = false
    @State private var liveText = ""
    @State private var liveTask: Task<Void, Never>?
    @State private var toolHint: String?
    @State private var liveWords = 0
    @State private var showEquation = false
    /// Lives on AppState, not here: the shell hides the rail and the window header for the
    /// same flag, and it has to survive switching from one note to the next.
    private var focusMode: Bool { state.focusMode }
    @State private var outlineHeadings: [(title: String, location: Int)] = []
    @State private var deleted = false   // once deleted, the teardown autosave must not re-add it
    // Inline AI (Writing-Tools-style): result shown in a review card, accepted or discarded.
    @State private var aiAction: NoteAI?
    @State private var aiText = ""
    @State private var aiDone = false
    @State private var asking = false
    @State private var askQuestion = ""
    @State private var askLoading = false
    @State private var askPicking = false
    @State private var askBlocked: String?      // the question the guard stopped, for the method offer

    // The thread, its attached notes and its quote warnings live on AppState, keyed by this
    // note — see AppState.askThreads. Computed rather than @State so closing the panel or
    // switching notes no longer throws the conversation away.
    private var askThread: [NoteQA.Turn] {
        get { state.askThreads[draft.id]?.turns ?? [] }
        nonmutating set { state.askThreads[draft.id, default: .init()].turns = newValue }
    }
    private var askExtras: [UUID] {
        get { state.askThreads[draft.id]?.extras ?? [] }
        nonmutating set { state.askThreads[draft.id, default: .init()].extras = newValue }
    }
    private var askUnverified: [UUID: Int] {
        get { state.askThreads[draft.id]?.unverified ?? [:] }
        nonmutating set { state.askThreads[draft.id, default: .init()].unverified = newValue }
    }
    @State private var askTask: Task<Void, Never>?
    @State private var askPickerQuery = ""
    @State private var askCardsBusy = false
    @State private var askCardsNote: String?
    @State private var askError: String?
    /// Width of the Ask column beside the note, dragged by the rule between them. Persisted,
    /// like the notes list width.
    @AppStorage("askColumnWidth") private var askWidth: Double = 360
    /// Height it falls back to when the pane is too narrow to sit two columns side by side.
    @AppStorage("askDockHeight") private var askHeight: Double = 300
    @FocusState private var askFocused: Bool
    @State private var aiStart: Date?
    @State private var aiRange = NSRange(location: 0, length: 0)
    @State private var aiTask: Task<Void, Never>?
    @AppStorage("notesAutocomplete") private var autocompleteOn = false
    @AppStorage("aiProactive") private var aiProactive = false
    @AppStorage("notesFont") private var notesFont = "system"
    @AppStorage("notesFontSize") private var notesFontSize = 15.0
    @AppStorage("notesLineSpacing") private var notesLineSpacing = 3.5
    @State private var chipDismissed = false
    @FocusState private var tagFieldFocused: Bool
    private let initialAttributed: NSAttributedString
    /// A brand-new, empty note — grab focus so the user can just start typing.
    private let startedEmpty: Bool
    /// Embedded in the window's master-detail split (no back-nav; selection drives it).
    var embedded = false
    /// Called instead of `dismiss()` when embedded (e.g. after delete → clear selection).
    var onClose: () -> Void = {}
    /// Open another note by id (a clicked `[[link]]` or a backlink).
    var onNavigate: (UUID) -> Void = { _ in }

    enum ColorMode { case highlight, foreground }

    init(note: Note, embedded: Bool = false, startInPreview: Bool = false,
         onClose: @escaping () -> Void = {}, onNavigate: @escaping (UUID) -> Void = { _ in }) {
        self.embedded = embedded
        self.onClose = onClose
        self.onNavigate = onNavigate
        _draft = State(initialValue: note)
        _tagText = State(initialValue: note.tags.joined(separator: ", "))
        startedEmpty = (note.title.isEmpty || SemesterWeek.isBarePrefix(note.title))
            && note.body.isEmpty && note.rich == nil
        // Read-first: an existing note opens rendered; a brand-new/empty note opens ready to type.
        // A brand-new note opens ready to type, including one that arrives carrying only the
        // generated "Week 3 — " title.
        let blank = (note.title.isEmpty || SemesterWeek.isBarePrefix(note.title))
            && note.body.isEmpty && note.rich == nil
        _showPreview = State(initialValue: startInPreview && !blank)
        _liveWords = State(initialValue: note.wordCount)
        if let data = note.rich, let a = NSAttributedString.fromRTFD(data) {
            initialAttributed = a
        } else {
            initialAttributed = NSAttributedString(string: note.body,
                attributes: [.font: RichTextController.baseFont, .foregroundColor: NSColor.labelColor,
                             .paragraphStyle: RichTextController.bodyParagraph])
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let img = screenshotImage(draft.imagePath) {
                Image(nsImage: img).resizable().scaledToFit()
                    .frame(maxHeight: 200).frame(maxWidth: .infinity)
                    .background(.sbSurface)
                Divider()
            }
            if !showPreview && !focusMode {
                HStack(spacing: 0) {
                    formatBar
                    aiToolbarButton
                }
                if toolHint != nil || autocompleteOn {
                    HStack(spacing: 4) {
                        if let toolHint {
                            Image(systemName: "hand.point.up.left").font(.system(size: 9))
                            Text(toolHint)
                        }
                        Spacer(minLength: 8)
                        if autocompleteOn { autocompleteStatus }
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.bottom, 4)
                }
                if let colorMode { Divider(); swatchPanel(colorMode) }
                Divider()
            }
            if let defineResult { defineCard(defineResult) }
            if aiAction != nil { aiCard }
            else if showProactiveChip && !asking { proactiveChip }
            askAndEditor
            if editor.slashQuery != nil { Divider(); slashBar }
            else if editor.linkQuery != nil { Divider(); linkAutocompleteBar }
            else if !backlinks.isEmpty && !focusMode { Divider(); backlinksBar }
            if !focusMode { Divider(); footer }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("")
        .toolbar(.hidden, for: .windowToolbar)
        .onAppear {
            editor.onEdit = { scheduleAutosave(); refreshLive(); liveWords = countWords(editor.plainText) }
            editor.onOpenLink = { openLink($0) }
            DispatchQueue.main.async { outlineHeadings = editor.headings() }
        }
        // Autosave metadata edits; body edits fire through editor.onEdit. onDisappear
        // flushes on teardown (e.g. switching modules from the sidebar).
        .onChange(of: draft.title)         { _, _ in scheduleAutosave() }
        .onChange(of: tagText)             { _, _ in scheduleAutosave() }
        .onChange(of: draft.pinned)        { _, _ in scheduleAutosave() }
        .onChange(of: draft.courseID)      { _, _ in scheduleAutosave() }
        .onChange(of: draft.assignmentID)  { _, _ in scheduleAutosave() }
        .onDisappear { saveTask?.cancel(); persist() }
        .overlay { if foldPrompt { foldPromptCard } }
        .overlay {
            if showEquation {
                NoteEquationComposer(
                    onInsert: { latex, display in
                        editor.insertMath(latex, display: display)
                        showEquation = false; scheduleAutosave()
                    },
                    onCancel: { showEquation = false })
            }
        }
    }

    private var foldPromptCard: some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea().onTapGesture { foldPrompt = false }
            VStack(spacing: 12) {
                Text("Collapse into a section").font(.headline)
                Text("The selected text collapses into a titled chip — click it to expand or collapse.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                TextField("Section title", text: $foldTitle).textFieldStyle(.roundedBorder).frame(width: 220)
                    .onSubmit { commitFold() }
                HStack(spacing: 10) {
                    Button("Cancel") { foldPrompt = false }.keyboardShortcut(.cancelAction)
                    Button("Collapse") { commitFold() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
            .padding(20).frame(maxWidth: 280)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator)).shadow(radius: 20)
        }
    }

    private func commitFold() {
        editor.wrapFold(title: foldTitle)
        foldPrompt = false; foldTitle = ""
        scheduleAutosave()
    }

    private var header: some View {
        HStack(spacing: 8) {
            if !embedded {
                Button { save() } label: { Image(systemName: "chevron.left").fontWeight(.semibold) }
                    .buttonStyle(.borderless).help("Back (saves)").keyboardShortcut("[", modifiers: .command)
            }
            TextField("Title", text: $draft.title).textFieldStyle(.plain).font(.title3.bold())
            Menu {
                if outlineHeadings.isEmpty { Text("No headings yet") }
                else { ForEach(outlineHeadings.indices, id: \.self) { i in Button(outlineHeadings[i].title) { editor.scrollTo(outlineHeadings[i].location) } } }
            } label: { Image(systemName: "list.bullet.rectangle") }
                .menuStyle(.borderlessButton).fixedSize().foregroundStyle(.secondary)
                .onHover { hovering in
                    if hovering { outlineHeadings = editor.headings() }   // refresh as you reach for it
                    setHint("Outline — jump to a heading", hovering)
                }
            Button { splitLive.toggle(); if splitLive { refreshLiveNow() } } label: {
                Image(systemName: splitLive ? "rectangle.split.1x2.fill" : "rectangle.split.1x2")
            }
            .buttonStyle(.borderless).foregroundStyle(splitLive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .disabled(showPreview)
            .help("Live math preview — edit above, see it render below")
            .onHover { setHint("Live math preview — edit above, see it render below", $0) }
            Button { if !showPreview { persist() }; showPreview.toggle() } label: {
                Image(systemName: showPreview ? "eye.fill" : "eye")
            }
            .buttonStyle(.borderless).foregroundStyle(showPreview ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .keyboardShortcut("e", modifiers: .command)
            .help("Full preview (renders Markdown & LaTeX) — ⌘E")
            .onHover { setHint(showPreview ? "Back to editing (⌘E)" : "Preview (renders Markdown & LaTeX) — ⌘E", $0) }
            Button { draft.pinned.toggle() } label: {
                Image(systemName: draft.pinned ? "pin.fill" : "pin")
            }.buttonStyle(.borderless).foregroundStyle(draft.pinned ? .orange : .secondary)
            .onHover { setHint(draft.pinned ? "Unpin note" : "Pin note", $0) }
            Button { withAnimation(.easeInOut(duration: 0.2)) { state.focusMode.toggle() } } label: {
                Image(systemName: focusMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }.buttonStyle(.borderless).foregroundStyle(focusMode ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            // The ⇧⌘F key equivalent lives once, on the shell (RootView.shortcutKeys), so the
            // two definitions can't both claim the chord.
            .help(focusMode ? "Exit focus mode (⇧⌘F)" : "Focus mode — hide the list and chrome (⇧⌘F)")
            .onHover { setHint(focusMode ? "Exit focus mode (⇧⌘F)" : "Focus mode — hide the list and chrome (⇧⌘F)", $0) }
        }.padding(12)
    }

    // Formatting toolbar — drives the NSTextView through the controller.
    private var formatBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 11) {
                fmtBtn("arrow.uturn.backward", "Undo (⌘Z)") { editor.undo() }
                fmtBtn("arrow.uturn.forward", "Redo (⇧⌘Z)") { editor.redo() }
                sep
                fmtBtn("bold", "Bold") { editor.toggleTrait(.boldFontMask) }
                fmtBtn("italic", "Italic") { editor.toggleTrait(.italicFontMask) }
                fmtBtn("underline", "Underline") { editor.toggleAttribute(.underlineStyle) }
                fmtBtn("strikethrough", "Strikethrough") { editor.toggleAttribute(.strikethroughStyle) }
                sep
                Menu {
                    Picker("Heading", selection: Binding(get: { editor.currentHeading() },
                                                         set: { editor.setHeading($0) })) {
                        Text("Body").tag(RichTextController.Heading.body)
                        Text("Heading 1").tag(RichTextController.Heading.h1)
                        Text("Heading 2").tag(RichTextController.Heading.h2)
                        Text("Heading 3").tag(RichTextController.Heading.h3)
                    }.pickerStyle(.inline)
                } label: { Label("Style", systemImage: "textformat.size") }.menuStyle(.borderlessButton).fixedSize()
                    .help("Text style — Body / Heading 1–3")
                    .onHover { setHint("Text style — Body / Heading 1–3", $0) }
                fmtBtn("list.bullet", "Bullet list — Tab to indent, Return to continue") { editor.toggleBullet() }
                fmtBtn("list.number", "Numbered list — Tab to indent, Return to continue") { editor.toggleNumbered() }
                fmtBtn("checklist", "Checklist — tap a box to check it off") { editor.toggleChecklist() }
                sep
                Menu {
                    Button { editor.insertTable() } label: { Label("Table", systemImage: "tablecells") }
                    Button { editor.insertImage() } label: { Label("Image", systemImage: "photo") }
                    Button { showEquation = true } label: { Label("Equation", systemImage: "function") }
                    Button { editor.toggleCodeBlock() } label: { Label("Code block", systemImage: "chevron.left.forwardslash.chevron.right") }
                    Button { editor.toggleQuote() } label: { Label("Block quote", systemImage: "text.quote") }
                    Button { editor.insertDivider() } label: { Label("Divider", systemImage: "minus") }
                    Button { if editor.hasSelection { foldTitle = ""; foldPrompt = true } } label: { Label("Collapse selection", systemImage: "rectangle.compress.vertical") }
                    Divider()
                    Button { define() } label: { Label("Define selected word", systemImage: "character.book.closed") }
                } label: { Label("Insert", systemImage: "plus") }.menuStyle(.borderlessButton).fixedSize()
                    .help("Insert — table, image, equation, code, quote, divider, collapse")
                    .onHover { setHint("Insert — table, image, equation, code, quote…", $0) }
                Menu {
                    Button { colorMode = .highlight } label: { Label("Highlight", systemImage: "highlighter") }
                    Button { colorMode = .foreground } label: { Label("Text color", systemImage: "paintpalette") }
                    if colorMode != nil { Divider(); Button("Hide color picker") { colorMode = nil } }
                } label: { Image(systemName: "highlighter") }.menuStyle(.borderlessButton).fixedSize()
                    .foregroundStyle(colorMode != nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .help("Text & highlight color")
                    .onHover { setHint("Text & highlight color", $0) }
                sep
                Menu {
                    Picker("Font", selection: $notesFont) {
                        Text("System").tag("system"); Text("Serif").tag("serif"); Text("Mono").tag("mono")
                    }.pickerStyle(.inline)
                    Picker("Size", selection: $notesFontSize) {
                        Text("Small").tag(13.0); Text("Medium").tag(15.0); Text("Large").tag(17.0)
                    }.pickerStyle(.inline)
                    Picker("Line spacing", selection: $notesLineSpacing) {
                        Text("Tight").tag(2.0); Text("Normal").tag(3.5); Text("Relaxed").tag(6.0)
                    }.pickerStyle(.inline)
                } label: { Image(systemName: "textformat") }.menuStyle(.borderlessButton).fixedSize()
                    .help("Notes appearance — font, size, line spacing (applies to all notes)")
                    .onHover { setHint("Notes appearance — font, size, line spacing", $0) }
            }.padding(.horizontal, 10).padding(.vertical, 5)
            .onChange(of: notesFont) { _, _ in editor.reapplyTypography() }
            .onChange(of: notesFontSize) { _, _ in editor.reapplyTypography() }
            .onChange(of: notesLineSpacing) { _, _ in editor.reapplyTypography() }
        }
    }

    /// Pinned to the trailing edge of the toolbar (never scrolls off), so the AI actions are
    /// always visible. Acts on the selection, or the whole note when nothing is selected.
    private var aiToolbarButton: some View {
        HStack(spacing: 8) {
            Divider().frame(height: 18)
            Menu {
                if AIConfig.isReady(for: .rewrite) {
                    Section("Selection, or the whole note") {
                        ForEach(NoteAI.allCases) { a in
                            Button { runAI(a) } label: { Label(a.label, systemImage: a.icon) }
                        }
                    }
                    Divider()
                    Button { openAsk() } label: { Label("Ask this note…", systemImage: "questionmark.bubble") }
                } else {
                    Button("Turn on AI in Settings ▸ Intelligence") {}.disabled(true)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                    Text("AI").font(.callout.weight(.medium))
                }
                .foregroundStyle(.tint)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(.tint.opacity(0.13), in: Capsule())
            }
            .menuStyle(.borderlessButton).fixedSize().menuIndicator(.hidden)
            .help("AI — summarize, rewrite, proofread the selection or note")
        }
        .padding(.trailing, 10)
        .background(.bar)
    }

    // Inline AI review card — streams the result, then Accept (replace/insert) or Discard.
    private var aiCard: some View {
        let action = aiAction ?? .summarize
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: action.icon).foregroundStyle(.tint)
                Text(action.label).font(.caption.weight(.semibold))
                if !aiDone {
                    ProgressView().controlSize(.small)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text("\(max(0, Int(Date().timeIntervalSince(aiStart ?? Date()))))s")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(AIConfig.mode.title).font(.caption2).foregroundStyle(.secondary)
                Button { closeAI() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Discard")
            }
            ScrollView {
                Text(aiText.isEmpty ? "Thinking…" : aiText)
                    .font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(aiText.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            }.frame(maxHeight: 170)
            if aiDone && !aiText.isEmpty {
                HStack(spacing: 8) {
                    let insert = Button { aiInsert() } label: { Label(action.mode == .insert ? "Insert" : "Insert below", systemImage: "text.insert") }
                    let replace = Button { aiReplace() } label: { Label(action.mode == .replace ? "Replace" : "Replace selection", systemImage: "arrow.triangle.2.circlepath") }
                    if action.mode == .insert {
                        insert.buttonStyle(.borderedProminent).controlSize(.small)
                        replace.buttonStyle(.bordered).controlSize(.small)
                    } else {
                        replace.buttonStyle(.borderedProminent).controlSize(.small)
                        insert.buttonStyle(.bordered).controlSize(.small)
                    }
                    Spacer()
                    Button("Discard") { closeAI() }.buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(.tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.tint.opacity(0.25)))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .onExitCommand { closeAsk() }       // Esc hides it; the thread stays
    }

    // MARK: Ask this note
    //
    // The one place StudyBar's AI explains instead of only reorganizing: the note is context
    // for a question that may go past it. Sits on the note, like every other AI surface here,
    // rather than sending you to a chat module.

    /// "Ask this note" beside the note when the editor is wide enough, above it when it isn't.
    /// Stacked was the only option, so asking about a note pushed the note off screen — the
    /// answer and the thing it was about could never be read together.
    @ViewBuilder private var askAndEditor: some View {
        GeometryReader { geo in
            // Note on the left, the conversation in its own column on the right: answers fill
            // the column from the top and the question box sits at its bottom edge, the way a
            // chat is built. Drag the rule between them to set the split. Only when the pane
            // is too narrow for two columns does it fall back to a strip under the note.
            let side = asking && geo.size.width >= 720
            let maxCol = max(280, geo.size.width - 380)
            let column = min(CGFloat(askWidth), maxCol)
            let dockCap = max(180, geo.size.height - 200)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    editorOrPreview
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if asking && !side {
                        HeightDivider(height: Binding(get: { CGFloat(askHeight) }, set: { askHeight = Double($0) }),
                                      range: 180...dockCap, resetTo: 300)
                        askPanel.frame(height: min(CGFloat(askHeight), dockCap))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if side {
                    PaneDivider(width: Binding(get: { CGFloat(askWidth) }, set: { askWidth = Double($0) }),
                                range: 280...maxCol, resetTo: 360, inverted: true)
                    askPanel
                        .frame(width: column)
                        .frame(maxHeight: .infinity)
                }
            }
        }
    }

    private var askPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble").foregroundStyle(.tint)
                Text("Ask this note").font(.caption.weight(.semibold))
                if askLoading { ProgressView().controlSize(.small) }
                Spacer()
                Text(askEngineLabel).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).help("The engine answering here — Settings ▸ Intelligence")
                if !askThread.isEmpty {
                    Button { resetAskThread() } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Start a new thread")
                    .accessibilityLabel("Start a new thread")
                }
                Button { closeAsk() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Close")
                    .accessibilityLabel("Close Ask")
            }

            if askThread.isEmpty {
                askEmptyState
            } else {
                askThreadView
                askThreadActions
            }

            askContextRow

            HStack(spacing: 6) {
                TextField(askThread.isEmpty ? "Ask about this lecture — or something it didn't cover"
                                            : "Follow up…", text: $askQuestion, axis: .vertical)
                    .textFieldStyle(.plain).font(.callout).lineLimit(1...4)
                    .focused($askFocused)
                    .onSubmit { ask() }
                if askLoading {
                    // A local 7B can take half a minute. Leaving the only way out as "close the
                    // panel" threw the thread away with it.
                    Button { stopAsk() } label: { Image(systemName: "stop.circle.fill").font(.title3) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Stop generating")
                        .accessibilityLabel("Stop generating")
                } else {
                    Button { ask() } label: { Image(systemName: "arrow.up.circle.fill").font(.title3) }
                        .buttonStyle(.plain).foregroundStyle(.tint)
                        .disabled(askQuestion.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityLabel("Ask")
                }
            }
            .padding(8)
            .background(.sbSurface2, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(10)
        .background(.tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.tint.opacity(0.25)))
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    /// The thread, sized to its content up to a cap — a fixed-height box left dead space under
    /// a one-line answer and hid a long one. It follows the newest turn as it streams, which a
    /// plain ScrollView did not: an answer could finish entirely below the fold.
    private var askThreadView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(askThread.enumerated()), id: \.element.id) { i, turn in
                        if i > 0 { Divider().opacity(0.6) }
                        askTurnView(turn)
                    }
                    Color.clear.frame(height: 1).id("askBottom")
                }
                .padding(.bottom, 2)
            }
            .frame(maxHeight: .infinity)
            .onChange(of: askThread.count) { _, _ in scrollAsk(proxy) }
            .onChange(of: askThread.last?.answer) { _, _ in scrollAsk(proxy) }
        }
    }

    /// Before the first question the dock would otherwise be an empty box. Offer the two
    /// openings that actually get used on a lecture note.
    @ViewBuilder private var askEmptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Pinned to the bottom of the transcript, just above the box you type in — the
            // same place the first answer will appear from.
            Spacer(minLength: 0)
            ForEach(["Explain this like I missed the lecture",
                     "What would an exam ask about this?"], id: \.self) { starter in
                Button { ask(starter) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles").font(.caption2).foregroundStyle(.tint)
                        Text(starter).font(.caption)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 5).padding(.horizontal, 8)
                    .contentShape(Rectangle())
                    .background(.sbSurface2, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .disabled(askLoading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    private func scrollAsk(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("askBottom", anchor: .bottom) }
    }

    @ViewBuilder private func askTurnView(_ turn: NoteQA.Turn) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(turn.question).font(.caption.weight(.semibold))
                .foregroundStyle(.secondary).textSelection(.enabled)
            if turn.answer.isEmpty {
                Text("Thinking…").font(.callout).foregroundStyle(.secondary)
            } else {
                RichText(text: turn.answer)     // Markdown + math, same as the reading view
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    if let n = askUnverified[turn.id] {
                        Label(QuoteCheck.notice(n), systemImage: "quote.closing")
                            .font(.caption2).foregroundStyle(Color.dsWeek)
                    }
                    Spacer(minLength: 0)
                    if !turn.engine.isEmpty {
                        Text(turn.engine).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var askThreadActions: some View {
        if let blocked = askBlocked, !askLoading {
            HStack(spacing: 8) {
                Button {
                    askBlocked = nil
                    ask(HomeworkGuard.methodQuestion(from: blocked))
                } label: { Label("Explain the method instead", systemImage: "figure.walk") }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Spacer()
            }
        } else if let last = askThread.last, !last.answer.isEmpty, !askLoading {
            HStack(spacing: 8) {
                Button { insertAnswer(last) } label: { Label("Insert into note", systemImage: "text.insert") }
                    .buttonStyle(.bordered).controlSize(.small)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Insert this answer under its question (⌘↩)")
                Button { copyAnswer(last) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .buttonStyle(.bordered).controlSize(.small)
                // An answer worth keeping is usually worth revising from — and the machinery
                // for turning text into cards already exists on the assistant surface.
                Button { cardsFromAnswer(last) } label: { Label("Flashcards", systemImage: "rectangle.on.rectangle.angled") }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(askCardsBusy)
                    .help("Turn this answer into flashcards for this course")
                if askCardsBusy { ProgressView().controlSize(.small) }
                if let note = askCardsNote {
                    Text(note).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    /// The engine that will answer here, named by its model rather than its mode — with a
    /// per-surface override the Ask panel and the rest of the app often run different models.
    private var askEngineLabel: String {
        let mode = AIConfig.askMode ?? AIConfig.mode
        let model = AIConfig.modelName(for: mode)
        return model.isEmpty ? mode.title : "\(model) · \(mode.title)"
    }

    /// The note being read, then the ones attached by hand — order matters, the question is
    /// about the first one.
    private var askSources: [NoteQA.Source] {
        var out = [NoteQA.Source(id: draft.id,
                                 title: draft.title.isEmpty ? "Untitled note" : draft.title,
                                 body: draft.body)]
        for id in askExtras {
            guard let n = state.data.notes.first(where: { $0.id == id }) else { continue }
            out.append(NoteQA.Source(id: n.id, title: n.title.isEmpty ? "Untitled note" : n.title, body: n.body))
        }
        return out
    }

    private var askChars: Int {
        var total = draft.body.utf8.count
        for id in askExtras {
            total += state.data.notes.first { $0.id == id }?.body.utf8.count ?? 0
        }
        return min(NoteQA.totalCharLimit, total)
    }

    /// Other notes worth attaching: this course first (that's what "add week 1 and 2" means),
    /// then everything else, newest first.
    private var askCandidates: [Note] {
        let others = state.data.notes.filter { $0.id != draft.id && !askExtras.contains($0.id) }
        let sameCourse = others.filter { $0.courseID != nil && $0.courseID == draft.courseID }
        let rest = others.filter { !($0.courseID != nil && $0.courseID == draft.courseID) }
        let byDate: (Note, Note) -> Bool = { $0.createdAt > $1.createdAt }
        return sameCourse.sorted(by: byDate) + rest.sorted(by: byDate)
    }

    private var askContextRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.doc").font(.caption2).foregroundStyle(.secondary)
                // `chars / 4` is a token count, and it used to be printed with a "k" glued on:
                // a 12k-character note read as "~3024k", claiming three million tokens.
                Text("\(askSources.count) note\(askSources.count == 1 ? "" : "s") · ~\(ContextPill.format(max(1, askChars / 4))) tokens")
                    .font(.caption2).foregroundStyle(.secondary)
                    .help("Roughly how much of the model's context window this fills")
                Spacer()
                if !askCandidates.isEmpty {
                    Button { askPicking = true } label: {
                        Label("Add notes", systemImage: "plus").font(.caption2)
                    }
                    .buttonStyle(.plain).foregroundStyle(.tint)
                    // A popover, not an inline list: inline, the picker got whatever vertical
                    // room the thread left it — which on a real note was one row out of 21.
                    .popover(isPresented: $askPicking, arrowEdge: .bottom) { askPicker }
                }
            }
            if !askExtras.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(askExtras, id: \.self) { id in
                            if let n = state.data.notes.first(where: { $0.id == id }) {
                                Button { askExtras.removeAll { $0 == id } } label: {
                                    Chip("\(n.title.isEmpty ? "Untitled" : n.title)  ✕", .tag)
                                }
                                .buttonStyle(.plain).help("Remove from the question's context")
                            }
                        }
                    }
                }
            }
        }
    }

    /// Everything else in the store, searchable, with what each one costs in context.
    private var askPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.caption2).foregroundStyle(.secondary)
                TextField("Search notes", text: $askPickerQuery)
                    .textFieldStyle(.plain).font(.callout)
                if !askPickerQuery.isEmpty {
                    Button { askPickerQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(7)
            .background(.sbSurface2, in: RoundedRectangle(cornerRadius: 7))

            if let cid = draft.courseID, let c = state.course(cid) {
                let mine = state.data.notes.filter { $0.courseID == cid && $0.id != draft.id }
                if mine.count > 1, !mine.allSatisfy({ askExtras.contains($0.id) }) {
                    Button {
                        for n in mine where !askExtras.contains(n.id) { askExtras.append(n.id) }
                    } label: {
                        Label("Add all of \(c.code.isEmpty ? c.name : c.code) (\(mine.count) notes)",
                              systemImage: "text.badge.plus").font(.caption)
                    }.buttonStyle(.plain).foregroundStyle(.tint)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(askPickerMatches) { n in
                        let added = askExtras.contains(n.id)
                        Button {
                            if added { askExtras.removeAll { $0 == n.id } } else { askExtras.append(n.id) }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: added ? "checkmark.circle.fill" : "circle")
                                    .font(.caption2)
                                    .foregroundStyle(added ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                                if let c = state.course(n.courseID) {
                                    Circle().fill(c.color).frame(width: 6, height: 6)
                                }
                                Text(n.title.isEmpty ? "Untitled" : n.title).font(.caption).lineLimit(1)
                                Spacer(minLength: 8)
                                Text("+\(ContextPill.format(max(1, n.body.count / 4)))")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 3).padding(.horizontal, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(added ? AnyShapeStyle(.tint.opacity(0.08)) : AnyShapeStyle(.clear),
                                    in: RoundedRectangle(cornerRadius: 5))
                    }
                    if askPickerMatches.isEmpty {
                        Text("No notes match “\(askPickerQuery)”")
                            .font(.caption2).foregroundStyle(.secondary).padding(.vertical, 6)
                    }
                }
            }
            .frame(height: 220)

            Divider()
            HStack {
                Text("\(askSources.count) note\(askSources.count == 1 ? "" : "s") · ~\(ContextPill.format(max(1, askChars / 4))) tokens")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { askPicking = false }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .padding(10)
        .frame(width: 320)
    }

    /// Candidates filtered by the picker's search field — title first, then body text.
    private var askPickerMatches: [Note] {
        let q = askPickerQuery.trimmingCharacters(in: .whitespaces)
        let pool = state.data.notes.filter { $0.id != draft.id }
        guard !q.isEmpty else { return askCandidates }
        return pool.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.body.localizedCaseInsensitiveContains(q)
        }
    }

    private func openAsk() {
        persist()                       // ask about what is actually in the note, not a stale draft
        asking = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { askFocused = true }
    }

    /// Closing hides the panel and stops any request — it no longer deletes the conversation.
    /// Reopening Ask on this note brings the thread back; the ↺ button is what clears it.
    private func closeAsk() {
        askTask?.cancel(); askTask = nil
        asking = false; askLoading = false; askQuestion = ""
        askPicking = false; askBlocked = nil
        askCardsNote = nil
    }

    /// Throw the conversation away, deliberately.
    private func resetAskThread() {
        askTask?.cancel(); askTask = nil
        askLoading = false
        state.askThreads[draft.id] = .init()
        askBlocked = nil; askCardsNote = nil
    }

    /// Cancel the request but keep the thread — closing the panel was the only way to stop a
    /// slow local model, and that threw the conversation away with it.
    private func stopAsk() {
        askTask?.cancel(); askTask = nil
        askLoading = false
        if let i = askThread.indices.last, askThread[i].answer.isEmpty {
            askThread[i].answer = "_Stopped._"
        }
    }

    /// An answer → a handful of cards in a deck for this course.
    private func cardsFromAnswer(_ turn: NoteQA.Turn) {
        guard !askCardsBusy, let provider = AIService.makeProvider(for: .ask) else { return }
        askCardsBusy = true
        askCardsNote = nil
        Task {
            let raw = (try? await provider.completePlain(
                system: NoteQA.cardSystem,
                messages: NoteQA.cardMessages(question: turn.question, answer: turn.answer))) ?? ""
            let cards = NoteQA.parseCards(raw)
            await MainActor.run {
                askCardsBusy = false
                guard !cards.isEmpty else { askCardsNote = "No cards came back"; return }
                let deckName = state.course(draft.courseID).map { $0.code.isEmpty ? $0.name : $0.code }
                    ?? "Ask answers"
                state.withUndo("Added \(cards.count) card\(cards.count == 1 ? "" : "s")") {
                    let deck: Deck
                    if let existing = state.data.decks.first(where: { $0.name.caseInsensitiveCompare(deckName) == .orderedSame }) {
                        deck = existing
                    } else {
                        deck = Deck(name: deckName, courseID: draft.courseID)
                        state.data.decks.append(deck)
                    }
                    for c in cards {
                        state.data.flashcards.append(Flashcard(deckID: deck.id, front: c.front, back: c.back))
                    }
                }
                askCardsNote = "\(cards.count) card\(cards.count == 1 ? "" : "s") → \(deckName)"
            }
        }
    }

    private func ask(_ override: String? = nil) {
        let q = (override ?? askQuestion).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !askLoading, AIConfig.isReady(for: .ask),
              let provider = AIService.makeProvider(for: .ask) else { return }

        // Before the model, not in its prompt. Two of three engines wrote the homework when
        // only asked not to; this is the same refusal made structural.
        if override == nil, case .submission = HomeworkGuard.check(q) {
            askQuestion = ""
            askThread.append(NoteQA.Turn(question: q, answer: HomeworkGuard.message))
            askBlocked = q
            return
        }
        askBlocked = nil
        persist()
        askQuestion = ""
        let title = draft.title.isEmpty ? "Untitled note" : draft.title
        let course = state.course(draft.courseID).map { $0.code.isEmpty ? $0.name : $0.code }
        let sources = askSources
        let msgs = NoteQA.messages(thread: askThread, question: q, sources: sources)
        let sys = NoteQA.system(noteTitle: title, courseName: course, extraNotes: sources.count - 1)

        askThread.append(NoteQA.Turn(question: q, answer: ""))
        let idx = askThread.count - 1
        askLoading = true
        askTask?.cancel()
        let engine = askEngineLabel
        askError = nil
        askTask = Task {
            var out: String?
            var failure: Error?
            // Prose, so the streaming path — never the format:json one, which returns `{}`.
            // Raw while it streams: normalizing each delta re-scanned the whole answer per
            // token. The finished text is normalized and quote-checked below.
            do {
                out = try await provider.streamPlain(system: sys, messages: msgs,
                                                     numCtx: NoteQA.contextTokens(chars: askChars),
                                                     temperature: 0.4) { p in
                    if askThread.indices.contains(idx) { askThread[idx].answer = p }
                }
            } catch {
                failure = error
            }
            await MainActor.run {
                askLoading = false
                guard askThread.indices.contains(idx) else { return }
                askThread[idx].engine = engine
                let final = (out ?? askThread[idx].answer).trimmingCharacters(in: .whitespacesAndNewlines)
                if final.isEmpty {
                    // Say which thing went wrong: a missing key, a model name with a typo and
                    // an Ollama that isn't running used to produce one identical sentence.
                    let mode = AIConfig.askMode ?? AIConfig.mode
                    let why = failure.map { AIError.plainMessage($0, mode: mode, model: AIConfig.modelName(for: mode)) }
                        ?? "No answer came back — try rephrasing, or a stronger engine in Settings ▸ Intelligence."
                    askThread[idx].answer = why
                    askError = failure == nil ? nil : why
                } else {
                    // Quotation marks assert the words are in the note. Check that against the
                    // notes actually sent, rather than trusting the model not to invent one.
                    let checked = QuoteCheck.verify(MathSupport.normalized(final), against: sources.map(\.body))
                    // An answer can be inserted into the note, so it gets the same list repair
                    // as anything else that lands there.
                    askThread[idx].answer = NoteFormat.tidy(checked.text)
                    if checked.count > 0 { askUnverified[askThread[idx].id] = checked.count }
                }
            }
        }
    }

    /// Answers land in the note only when asked for, under the question that produced them.
    private func insertAnswer(_ turn: NoteQA.Turn) {
        let block = "\n\n**\(turn.question)**\n\n\(turn.answer)\n"
        if editor.attributedString.length > 0, !showPreview {
            editor.insertPlain(block, at: editor.attributedString.length)
        } else {
            draft.body += block
            draft.rich = nil                 // the plaintext mirror is now ahead of the RTFD
        }
        scheduleAutosave()
    }

    private func copyAnswer(_ turn: NoteQA.Turn) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(turn.answer, forType: .string)
    }

    // Opt-in ambient suggestion (Settings ▸ Intelligence ▸ Inline AI). Gentle, dismissible,
    // never auto-acts — it just offers the same Summarize the ✨ menu would run.
    private var showProactiveChip: Bool {
        aiProactive && AIConfig.isReady(for: .rewrite) && !chipDismissed && !showPreview && !focusMode && liveWords >= 150
    }
    private var proactiveChip: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(.tint)
            Text("This note's getting long — summarize it?").font(.caption)
            Spacer()
            Button("Summarize") { chipDismissed = true; runAI(.summarize) }
                .buttonStyle(.borderedProminent).controlSize(.small)
            Button { chipDismissed = true } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Dismiss")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.tint.opacity(0.08), in: Capsule())
        .padding(.horizontal, 10).padding(.top, 4)
    }

    private func runAI(_ action: NoteAI) {
        guard AIConfig.isReady(for: .rewrite), let provider = AIService.makeProvider(for: .rewrite) else { return }
        let scope = editor.aiScope()
        guard !scope.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        aiAction = action; aiText = ""; aiDone = false; aiStart = Date(); aiRange = scope.range
        aiTask?.cancel()
        aiTask = Task {
            let sys = action.system()
            let msgs = [AIMessage(role: .user, text: action.user(scope.text))]
            let out: String?
            out = try? await provider.streamPlain(system: sys, messages: msgs, temperature: action.temperature) { p in aiText = p }
            await MainActor.run {
                // Canonicalize the model's LaTeX delimiters here rather than asking for them
                // in the prompt: a 7B model complies most of the time, and "most" is what put
                // unrendered `\[…\]` in the store. Doing it before the card means what you
                // review is what lands in the note — and it lands as `$…$`, which the editor
                // renders inline too.
                // Same bargain for list shape: the prompt asks for a lead-in that isn't a
                // bullet, and `tidy` repairs the times it comes back as one anyway.
                aiText = NoteFormat.tidy(
                    MathSupport.normalized((out ?? aiText).trimmingCharacters(in: .whitespacesAndNewlines)))
                aiDone = true
                if aiText.isEmpty { aiAction = nil }   // failed — close quietly; note untouched
            }
        }
    }

    private func aiReplace() {
        guard !aiText.isEmpty else { return }
        editor.replaceRange(aiRange, withPlain: aiText); scheduleAutosave(); closeAI()
    }
    private func aiInsert() {
        guard !aiText.isEmpty else { return }
        editor.insertPlain("\n\n" + aiText + "\n", at: aiRange.upperBound); scheduleAutosave(); closeAI()
    }
    private func closeAI() { aiTask?.cancel(); aiTask = nil; aiAction = nil; aiText = ""; aiDone = false; aiStart = nil }

    /// Inline swatch panel — a real color grid (NSColorPanel would dismiss the popover).
    private func swatchPanel(_ mode: ColorMode) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text(mode == .highlight ? "Highlight" : "Text").font(.caption2.bold()).foregroundStyle(.secondary)
                ForEach(Self.palette, id: \.0) { name, color in
                    Button {
                        if mode == .highlight { editor.setHighlight(color.withAlphaComponent(0.35)) }
                        else { editor.setForeground(color) }
                        colorMode = nil
                    } label: {
                        Circle().fill(Color(nsColor: color)).frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
                    }.buttonStyle(.plain).help(name)
                }
                Button {
                    if mode == .highlight { editor.setHighlight(nil) } else { editor.setForeground(.labelColor) }
                    colorMode = nil
                } label: {
                    ZStack {
                        Circle().fill(Color(nsColor: .textBackgroundColor)).frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
                        Image(systemName: "slash.circle").font(.caption2).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain).help(mode == .highlight ? "No highlight" : "Default color")
            }.padding(.horizontal, 10).padding(.vertical, 6)
        }
    }

    // Theme-adaptive only — no raw White/Black (which vanish against the opposite theme).
    // The "default / no highlight" reset button covers going back to the base color.
    static let palette: [(String, NSColor)] = [
        ("Red", .systemRed), ("Orange", .systemOrange), ("Yellow", .systemYellow),
        ("Green", .systemGreen), ("Teal", .systemTeal), ("Blue", .systemBlue),
        ("Indigo", .systemIndigo), ("Purple", .systemPurple), ("Pink", .systemPink),
        ("Brown", .systemBrown), ("Gray", .systemGray),
    ]

    @ViewBuilder private var editorOrPreview: some View {
        if showPreview {
            VStack(spacing: 0) {
                readingBar
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        readingHeader
                        NotePreview(text: draft.body.isEmpty ? "_Nothing here yet — click to start writing._" : draft.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: 680, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)   // center the reading column
                    .padding(.horizontal, 24).padding(.vertical, 20)
                    // Selectable so a passage can be copied without entering the editor. The
                    // math rows are SwiftMath images and stay unselectable; a note that falls
                    // back to KaTeX is a web view, which selects on its own.
                    .textSelection(.enabled)
                    .background(
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { enterEditFromPreview() }
                    )
                }
            }
        } else if splitLive {
            VStack(spacing: 0) {
                RichTextEditor(initial: editor.snapshot ?? initialAttributed, controller: editor)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .frame(maxHeight: .infinity)
                Divider()
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        SectionHeader(title: "Live preview", systemImage: "function")
                        Spacer()
                    }.padding(.horizontal, 12).padding(.top, 6)
                    ScrollView {
                        NotePreview(text: liveText.isEmpty ? "_Type math with `$…$` or `$$…$$`_" : liveText)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }
                }
                .frame(maxHeight: 240)
                .background(.sbSurface)
            }
        } else {
            // Cap the writing column to a readable measure and center it (only bites once
            // the window is wider than ~720 — no effect in the popover / narrow window).
            RichTextEditor(initial: editor.snapshot ?? initialAttributed, controller: editor, focusOnAppear: startedEmpty)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 4).padding(.vertical, 2)
        }
    }

    /// Slim strip atop the reading view — names the mode and advertises the click-to-edit gesture.
    private var readingBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "book").font(.caption2)
            Text("Reading").font(.caption2.weight(.semibold))
            Spacer()
            if AIConfig.isReady(for: .ask) {
                Button { asking ? closeAsk() : openAsk() } label: {
                    Label("Ask", systemImage: "questionmark.bubble").font(.caption2)
                }
                .buttonStyle(.plain).foregroundStyle(.tint)
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .help("Ask a question about this lecture — or about something it didn't cover (⇧⌘A)")
                Text("·").font(.caption2)
            }
            Label("⌘E to edit", systemImage: "pencil").font(.caption2)
                .help("⌘E, the eye button, or a double-click in the margin. Text is selectable — drag to copy a passage.")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 5)
        .background(.sbSurface.opacity(0.5))
    }
    private func enterEditFromPreview() { withAnimation(.easeOut(duration: 0.12)) { showPreview = false } }

    /// Existing tags (across all notes) that aren't already on this note, ranked by how often
    /// they're used and narrowed to the tag currently being typed — keeps the vocabulary tight.
    private var tagSuggestions: [String] {
        let tokens = tagText.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        let onNote = Set(tokens.map { $0.lowercased() }.filter { !$0.isEmpty })
        let partial = (tokens.last ?? "").lowercased()
        var freq: [String: (display: String, n: Int)] = [:]
        for t in state.data.notes.flatMap({ $0.tags }) where !t.isEmpty {
            freq[t.lowercased(), default: (t, 0)].n += 1
        }
        return freq.values
            .filter { !onNote.contains($0.display.lowercased()) }
            .filter { partial.isEmpty || $0.display.lowercased().contains(partial) }
            .sorted { $0.n > $1.n }
            .prefix(6).map(\.display)
    }
    /// Complete the tag being typed with a suggestion, leaving a trailing separator to continue.
    private func applyTag(_ tag: String) {
        var tokens = tagText.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if tokens.isEmpty { tokens = [""] }
        tokens[tokens.count - 1] = tag
        tagText = tokens.filter { !$0.isEmpty }.joined(separator: ", ") + ", "
        tagFieldFocused = true
    }

    /// Reading-view masthead: the note's title as a page heading, plus a quiet course/edited line.
    @ViewBuilder private var readingHeader: some View {
        if !draft.title.isEmpty || draft.courseID != nil {
            VStack(alignment: .leading, spacing: 6) {
                if !draft.title.isEmpty {
                    Text(draft.title).font(.system(.title, design: .default).weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    if let c = state.course(draft.courseID) {
                        HStack(spacing: 5) {
                            Circle().fill(c.color).frame(width: 6, height: 6)
                            Text(c.code.isEmpty ? c.name : c.code)
                        }
                    }
                    Text("edited \(draft.updatedAt.relativeShort)")
                    if !draft.tags.isEmpty { Text(draft.tags.map { "#\($0)" }.joined(separator: " ")).foregroundStyle(.tint).lineLimit(1) }
                }
                .font(.caption).foregroundStyle(.secondary)
                Divider().padding(.top, 2)
            }
        }
    }

    private func countWords(_ s: String) -> Int {
        // Drop bare markers ($ • ☐ ☑ ─ [ ]) so they aren't counted as words.
        let cleaned = s.filter { !"$•☐☑─[]".contains($0) }
        return cleaned.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
    }

    private var footer: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text("\(liveWords) word\(liveWords == 1 ? "" : "s")")
                Text("·")
                Text("edited \(draft.updatedAt.relativeShort)")
                Spacer()
            }.font(.caption2).foregroundStyle(.tertiary)
            HStack(spacing: 10) {
                CoursePicker(courseID: $draft.courseID)
                Divider().frame(height: 14)
                AssignmentPicker(assignmentID: $draft.assignmentID)
                Spacer()
            }
            HStack(spacing: 8) {
                Image(systemName: "tag").font(.caption).foregroundStyle(.secondary)
                TextField("tags, comma separated", text: $tagText).textFieldStyle(.plain).font(.caption)
                    .focused($tagFieldFocused)
                Spacer()
                Menu {
                    Button { duplicate() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                    Button { printNote() } label: { Label("Print…", systemImage: "printer") }
                    Divider()
                    Button { exportPDF() } label: { Label("Export as PDF", systemImage: "arrow.down.doc.fill") }
                    Button { exportNote(markdown: true) } label: { Label("Export as Markdown", systemImage: "arrow.down.doc") }
                    Button { exportNote(markdown: false) } label: { Label("Export as Rich Text", systemImage: "arrow.down.doc") }
                    Divider()
                    // Out of the footer row: a permanent red target beside Share is a mis-click
                    // waiting to happen. Undo covers the delete itself.
                    Button(role: .destructive) { delete() } label: { Label("Delete Note", systemImage: "trash") }
                } label: { Image(systemName: "square.and.arrow.up") }
                .menuStyle(.borderlessButton).fixedSize()
                if !embedded { Button("Done") { save() }.keyboardShortcut(.defaultAction) }
            }
            if tagFieldFocused && !tagSuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(tagSuggestions, id: \.self) { t in
                            Button { applyTag(t) } label: { Text("#\(t)").font(.caption2) }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(.sbSurface2, in: Capsule())
                                .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
                        }
                    }.padding(.horizontal, 2)
                }
                .frame(height: 24)
            }
        }.padding(10)
    }

    // MARK: Slash commands — "/" inserts a block

    private var slashCommands: [(name: String, icon: String, run: () -> Void)] {
        [("Heading 1", "textformat.size.larger", { editor.setHeading(.h1) }),
         ("Heading 2", "textformat.size", { editor.setHeading(.h2) }),
         ("Heading 3", "textformat.size.smaller", { editor.setHeading(.h3) }),
         ("Bullet list", "list.bullet", { editor.toggleBullet() }),
         ("Numbered list", "list.number", { editor.toggleNumbered() }),
         ("Checklist", "checklist", { editor.toggleChecklist() }),
         ("Quote", "text.quote", { editor.toggleQuote() }),
         ("Code block", "chevron.left.forwardslash.chevron.right", { editor.toggleCodeBlock() }),
         ("Divider", "minus", { editor.insertDivider() }),
         ("Table", "tablecells", { editor.insertTable() }),
         ("Equation", "function", { showEquation = true }),
         ("Image", "photo", { editor.insertImage() })]
    }
    private var slashBar: some View {
        let q = (editor.slashQuery ?? "").lowercased()
        let matches = slashCommands.filter { q.isEmpty || $0.name.lowercased().contains(q) }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "slash.circle").font(.caption2).foregroundStyle(.secondary)
                if matches.isEmpty { Text("No block matches").font(.caption2).foregroundStyle(.secondary) }
                ForEach(matches.indices, id: \.self) { i in
                    Button { editor.removeSlash(); matches[i].run() } label: {
                        Label(matches[i].name, systemImage: matches[i].icon).font(.caption2.weight(.medium))
                    }.buttonStyle(.borderless)
                }
            }.padding(.horizontal, 12).padding(.vertical, 6)
        }.background(.sbSurface)
    }

    // MARK: Wikilinks — autocomplete strip + backlinks

    /// Notes referenced by a finished `[[title]]` matching this note, or a "Create" option.
    private var linkMatches: [Note] {
        let q = (editor.linkQuery ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return state.data.notes
            .filter { $0.id != draft.id && !$0.title.isEmpty }
            .filter { q.isEmpty || $0.title.lowercased().contains(q) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(6).map { $0 }
    }
    private var linkAutocompleteBar: some View {
        let q = (editor.linkQuery ?? "").trimmingCharacters(in: .whitespaces)
        let exact = state.data.notes.contains { $0.title.caseInsensitiveCompare(q) == .orderedSame }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "link").font(.caption2).foregroundStyle(.secondary)
                ForEach(linkMatches) { n in
                    Button { editor.completeLink(n.title) } label: {
                        Text(n.title).font(.caption2.weight(.medium)).lineLimit(1)
                    }.buttonStyle(.borderless)
                }
                if !q.isEmpty && !exact {
                    Button { editor.completeLink(q) } label: {
                        Label("Create “\(q)”", systemImage: "plus").font(.caption2)
                    }.buttonStyle(.borderless).foregroundStyle(.tint)
                }
                if linkMatches.isEmpty && q.isEmpty {
                    Text("Type a note title…").font(.caption2).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 12).padding(.vertical, 6)
        }.background(.sbSurface)
    }

    /// Notes whose body links to this one via `[[this title]]`.
    private var backlinks: [Note] {
        let t = draft.title.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2 else { return [] }
        let needle = "[[\(t.lowercased())]]"
        return state.data.notes.filter { $0.id != draft.id && $0.body.lowercased().contains(needle) }
    }
    private var backlinksBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.s) {
                Label("Linked from", systemImage: "arrow.turn.up.left")
                    .font(.caption2.weight(.bold)).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                ForEach(backlinks) { n in
                    Button { persist(); onNavigate(n.id) } label: {
                        Text(n.title.isEmpty ? "Untitled" : n.title).font(.caption2.weight(.medium)).lineLimit(1)
                    }.buttonStyle(.borderless)
                }
            }.padding(.horizontal, 12).padding(.vertical, 6)
        }.background(.sbSurface.opacity(0.5))
    }

    /// Open a clicked `[[link]]`: navigate to the note of that title, creating it if new.
    private func openLink(_ title: String) {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        persist()
        if let existing = state.data.notes.first(where: { $0.title.caseInsensitiveCompare(t) == .orderedSame }) {
            onNavigate(existing.id)
        } else {
            let n = Note(title: t)
            state.data.notes.append(n)
            onNavigate(n.id)
        }
    }

    private func defineCard(_ def: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(defineTerm, systemImage: "character.book.closed").font(.caption.bold())
                Spacer()
                Button { defineResult = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            ScrollView {
                MarkdownText(text: DictionaryFormat.markdown(def)).font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }.frame(maxHeight: 130)
        }
        .padding(8).background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .padding(.horizontal, 8).padding(.top, 6)
    }

    private func fmtBtn(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 18) }
            .buttonStyle(.borderless).help(help)
            .onHover { setHint(help, $0) }
    }

    /// `.help`/native tooltips don't fire reliably in this app's hosted views, so a
    /// hover over any tool names it in a strip just under the toolbar instead.
    private func setHint(_ text: String, _ hovering: Bool) {
        if hovering { toolHint = text } else if toolHint == text { toolHint = nil }
    }

    /// Live status for the (easy-to-miss, background) Ollama autocomplete, so the user can
    /// see it's on, working, ready, or why it isn't — instead of a silent no-op.
    @ViewBuilder private var autocompleteStatus: some View {
        if AIConfig.mode != .ollama {
            Label("Autocomplete needs the Ollama engine", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).lineLimit(1)
        } else {
            switch editor.ghostPhase {
            case .idle:
                Label("Autocomplete on", systemImage: "wand.and.stars").foregroundStyle(.secondary)
            case .thinking:
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 10, height: 10)
                    Text("Thinking…")
                }.foregroundStyle(.secondary)
            case .ready:
                Label("Tab ⇥ to accept", systemImage: "sparkles").foregroundStyle(.tint).fontWeight(.medium)
            case .error(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(1)
            }
        }
    }
    private var sep: some View { Divider().frame(height: 14) }

    private func define() {
        let term = editor.wordToDefine
        guard !term.isEmpty else { return }
        defineTerm = term
        defineResult = DictionaryService.define(term) ?? "No definition found for “\(term)”."
    }

    /// Refresh the live split preview ~0.35s after the last keystroke (folds → markers
    /// so NotePreview renders them, and math renders via RichText/KaTeX).
    private func refreshLive() {
        guard splitLive else { return }
        liveTask?.cancel()
        liveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            liveText = editor.attributedString.expandingMath().expandingFolds().string
        }
    }
    private func refreshLiveNow() { liveText = editor.attributedString.expandingMath().expandingFolds().string }

    /// Persist ~0.7s after the last edit (coalesces keystrokes).
    private func scheduleAutosave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            persist()
        }
    }

    private func save() { saveTask?.cancel(); persist(); dismiss() }

    /// Write the draft to the store without leaving the editor (used by ✨ actions).
    private func persist() {
        if deleted { return }   // don't resurrect a note the user just deleted
        let attr = editor.attributedString.expandingMath().expandingFolds()   // math→$…$, folds→[[fold:]]
        if attr.length > 0 || !showPreview {   // capture rich content when the editor is/was live
            draft.rich = attr.rtfdData()
            draft.body = attr.string
        }
        draft.tags = tagText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // Only stamp the edit time when something actually changed. Closing the editor calls
        // save() → persist() whether or not a key was pressed, so opening a note to read it
        // used to move it to the top of "Last edited" — which made that order a record of
        // what was opened, not what was written.
        if var stored = state.data.notes.first(where: { $0.id == draft.id }) {
            stored.updatedAt = draft.updatedAt          // compare everything but the timestamp
            if stored != draft { draft.updatedAt = .now }
        } else {
            draft.updatedAt = .now
        }
        // A new note in a course opens with "Week 3 — " already in the title. That is the
        // app's typing, not the user's, so it must not keep an untouched note alive.
        let titleText = draft.title.trimmingCharacters(in: .whitespaces)
        let empty = (titleText.isEmpty || SemesterWeek.isBarePrefix(draft.title))
            && draft.body.trimmingCharacters(in: .whitespaces).isEmpty && draft.imagePath.isEmpty
        if empty {
            state.data.notes.removeAll { $0.id == draft.id }   // discard blank
        } else if let i = state.data.notes.firstIndex(where: { $0.id == draft.id }) {
            state.data.notes[i] = draft
        } else {
            state.data.notes.append(draft)
        }
    }
    private func delete() {
        deleted = true
        saveTask?.cancel()
        state.withUndo("Deleted note") { state.data.notes.removeAll { $0.id == draft.id } }
        embedded ? onClose() : dismiss()
    }

    // MARK: Duplicate / export / print

    private func duplicate() {
        persist()
        var copy = draft
        copy.id = UUID()
        copy.title = (draft.title.isEmpty ? "Untitled" : draft.title) + " copy"
        copy.createdAt = .now; copy.updatedAt = .now
        state.data.notes.append(copy)
        onNavigate(copy.id)
    }

    /// The note's text, whether or not the rich editor is mounted. Export and Print are
    /// reachable from the reading view, where `RichTextEditor` never mounts — so
    /// `editor.attributedString` is empty there, which is how Export as Rich Text came to
    /// write a file with nothing in it. Fall back to the stored RTFD, then to the plaintext
    /// mirror, so every path has real content.
    private func exportAttributed() -> NSAttributedString {
        let live = editor.attributedString
        if live.length > 0 { return live.expandingMath().expandingFolds() }
        if let data = draft.rich, let stored = NSAttributedString.fromRTFD(data), stored.length > 0 {
            return stored          // persist() already expanded math/folds before storing it
        }
        return NSAttributedString(string: draft.body,
                                  attributes: [.font: NSFont.systemFont(ofSize: 13),
                                               .foregroundColor: NSColor.labelColor])
    }

    private func exportNote(markdown: Bool) {
        persist()
        let panel = NSSavePanel()
        let name = draft.title.isEmpty ? "Note" : draft.title
        panel.nameFieldStringValue = name + (markdown ? ".md" : ".rtf")
        panel.allowedContentTypes = markdown ? [.plainText] : [.rtf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if markdown {
                let text = markdownExport(exportAttributed().string)
                try Data(text.utf8).write(to: url)
            } else {
                let attr = exportAttributed()
                let data = try attr.data(from: NSRange(location: 0, length: attr.length),
                                         documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
                try data.write(to: url)
            }
        } catch {
            // Was `try?` on both the encode and the write, so a failure left the file the
            // save panel had already created — empty, with no word of it anywhere.
            Diagnostics.log(.data, .error, "note export failed (\(markdown ? "md" : "rtf")): \(error.localizedDescription)")
        }
    }

    /// PDF is the format to hand a classmate: it renders the math instead of shipping `$…$`
    /// source, and it opens anywhere. Goes through the same Markdown + KaTeX page the
    /// reading view uses.
    private func exportPDF() {
        persist()
        let panel = NSSavePanel()
        let name = draft.title.isEmpty ? "Note" : draft.title
        panel.nameFieldStringValue = name + ".pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if NoteDocument.writePDF(title: draft.title, attributed: exportAttributed(), to: url) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            Diagnostics.log(.data, .error, "note PDF export failed")
        }
    }

    /// `RichTextController.printNote()` prints the live `NSTextView`, which doesn't exist in
    /// the reading view — printing from there did nothing at all. Fall back to the rendered
    /// document, which also prints math as math.
    private func printNote() {
        persist()
        if editor.attributedString.length > 0, !showPreview {
            editor.printNote()
            return
        }
        NoteDocument.print(title: draft.title, attributed: exportAttributed())
    }

    /// Turn the editor's plaintext mirror into portable Markdown (its list markers → md).
    private func markdownExport(_ body: String) -> String {
        var s = body
        s = s.replacingOccurrences(of: #"(?m)^• "#, with: "- ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^☐ "#, with: "- [ ] ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^☑ "#, with: "- [x] ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"─{3,}"#, with: "---", options: .regularExpression)
        return s
    }
}
