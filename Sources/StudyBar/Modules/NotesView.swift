import SwiftUI
import UniformTypeIdentifiers

enum NoteSort: String, CaseIterable, Identifiable {
    case updated = "Last edited", created = "Date created", title = "Title"
    var id: String { rawValue }
}

struct NotesView: View {
    @EnvironmentObject var state: AppState
    @State private var editing: Note?           // narrow/popover: pushed note
    @State private var selection: UUID?         // wide window: selected note in the split
    @State private var newDraft: Note?          // wide window: a not-yet-saved new note
    @State private var search = ""
    @State private var sort = NoteSort.updated

    /// The split (list + editor) needs real width; below this we push one note at a time.
    private let splitMinWidth: CGFloat = 640

    private var notes: [Note] {
        var list = state.data.notes
        if !search.isEmpty {
            list = list.filter {
                $0.title.localizedCaseInsensitiveContains(search) ||
                $0.body.localizedCaseInsensitiveContains(search) ||
                $0.tags.contains { $0.localizedCaseInsensitiveContains(search) }
            }
        }
        switch sort {
        case .updated: list.sort { $0.updatedAt > $1.updatedAt }
        case .created: list.sort { $0.createdAt > $1.createdAt }
        case .title:   list.sort { $0.title.localizedCompare($1.title) == .orderedAscending }
        }
        // Pinned always float to the top.
        return list.sorted { ($0.pinned ? 1 : 0) > ($1.pinned ? 1 : 0) }
    }

    var body: some View {
        GeometryReader { geo in
            let split = geo.size.width >= splitMinWidth
            NavigationStack {
                ModulePane(title: "Notes") { toolbar(split: split) } content: {
                    if split { splitBody } else { stackBody }
                }
                .navigationDestination(item: $editing) { note in
                    NoteEditor(note: note, onNavigate: { id in
                        if let n = state.data.notes.first(where: { $0.id == id }) { editing = n }
                    })
                }
                .onAppear { consumePending(split: split) }
                .onChange(of: state.pendingNew) { _, _ in consumePending(split: split) }
            }
        }
    }

    @ViewBuilder private func toolbar(split: Bool) -> some View {
        HStack(spacing: 8) {
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

    private var stackBody: some View {
        VStack(spacing: 0) {
            if state.data.notes.count > 4 { SearchField(text: $search).padding(8); Divider() }
            if notes.isEmpty {
                notesEmptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(notes) { n in NoteRow(note: n) { editing = n } }
                    }.padding(10)
                }
            }
        }
    }

    // MARK: Wide window — master-detail split

    private var splitBody: some View {
        HStack(spacing: 0) {
            listPane.frame(width: 268)
            Divider()
            detailPane.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var listPane: some View {
        VStack(spacing: 0) {
            if state.data.notes.count > 4 { SearchField(text: $search).padding(8); Divider() }
            if notes.isEmpty {
                notesEmptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(notes) { n in
                            NoteRow(note: n, selected: n.id == selection) { select(n.id) }
                        }
                    }.padding(8)
                }
            }
        }
        .background(.background.secondary.opacity(0.35))
    }

    @ViewBuilder private var detailPane: some View {
        if let sel = selection, let note = noteForSelection(sel) {
            NoteEditor(note: note, embedded: true,
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
                   subtitle: state.data.notes.isEmpty ? "Capture ideas, lecture notes and reminders. Markdown supported." : "Try a different search.")
    }

    /// The note behind the current selection — a saved note, or the pending new draft.
    private func noteForSelection(_ id: UUID) -> Note? {
        state.data.notes.first { $0.id == id } ?? (newDraft?.id == id ? newDraft : nil)
    }
    private func select(_ id: UUID) { selection = id; newDraft = nil }

    // MARK: Actions (fork by surface width)

    private func consumePending(split: Bool) {
        if state.pendingNew == "notes" { state.pendingNew = nil; newNote(split: split) }
    }
    private func newNote(split: Bool) {
        let n = Note()
        if split { newDraft = n; selection = n.id }   // editor inserts it on first edit
        else { editing = n }                          // insert only on Save
    }

    private func newFromTemplate(_ t: NoteTemplates.Template, split: Bool) {
        let attr = t.build()
        var n = Note(title: t.title)
        n.rich = attr.rtfdData(); n.body = attr.string
        state.data.notes.append(n)                    // has content → insert now
        if split { selection = n.id; newDraft = nil } else { editing = n }
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
    let onOpen: () -> Void

    init(note: Note, selected: Bool = false, onOpen: @escaping () -> Void) {
        self.note = note; self.selected = selected; self.onOpen = onOpen
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 8) {
                if note.pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.orange) }
                if let img = screenshotImage(note.imagePath) {
                    Image(nsImage: img).resizable().scaledToFill()
                        .frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 5))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.listTitle)
                        .fontWeight(.medium).lineLimit(1)
                    Text(note.previewText.isEmpty ? "No content" : note.previewText)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    HStack(spacing: DS.Space.s) {
                        CourseChip(course: state.course(note.courseID))
                        ForEach(note.tags, id: \.self) { t in Chip(t, .tag) }
                    }
                }
                Spacer()
            }
            .padding(DS.Space.m).contentShape(Rectangle())
            .background(selected ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.background.secondary),
                        in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(.tint.opacity(0.5), lineWidth: 1)
                }
            }
        }.buttonStyle(.plain)
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
    @State private var focusMode = false
    @State private var deleted = false   // once deleted, the teardown autosave must not re-add it
    @AppStorage("notesAutocomplete") private var autocompleteOn = false
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

    init(note: Note, embedded: Bool = false, onClose: @escaping () -> Void = {}, onNavigate: @escaping (UUID) -> Void = { _ in }) {
        self.embedded = embedded
        self.onClose = onClose
        self.onNavigate = onNavigate
        _draft = State(initialValue: note)
        _tagText = State(initialValue: note.tags.joined(separator: ", "))
        startedEmpty = note.title.isEmpty && note.body.isEmpty && note.rich == nil
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
                    .background(.background.secondary)
                Divider()
            }
            if !showPreview && !focusMode {
                formatBar
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
            editorOrPreview
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
                let hs = editor.headings()
                if hs.isEmpty { Text("No headings yet") }
                else { ForEach(hs.indices, id: \.self) { i in Button(hs[i].title) { editor.scrollTo(hs[i].location) } } }
            } label: { Image(systemName: "list.bullet.rectangle") }
                .menuStyle(.borderlessButton).fixedSize().foregroundStyle(.secondary)
                .onHover { setHint("Outline — jump to a heading", $0) }
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
            .help("Full preview (renders Markdown & LaTeX)")
            .onHover { setHint(showPreview ? "Back to editing" : "Preview (renders Markdown & LaTeX)", $0) }
            Button { draft.pinned.toggle() } label: {
                Image(systemName: draft.pinned ? "pin.fill" : "pin")
            }.buttonStyle(.borderless).foregroundStyle(draft.pinned ? .orange : .secondary)
            .onHover { setHint(draft.pinned ? "Unpin note" : "Pin note", $0) }
            Button { withAnimation(.easeInOut(duration: 0.2)) { focusMode.toggle() } } label: {
                Image(systemName: focusMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }.buttonStyle(.borderless).foregroundStyle(focusMode ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .onHover { setHint(focusMode ? "Exit focus mode" : "Focus mode — hide the chrome", $0) }
        }.padding(12)
    }

    // Formatting toolbar — drives the NSTextView through the controller.
    private var formatBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 11) {
                fmtBtn("arrow.uturn.backward", "Undo (⌘Z)") { editor.undo() }
                fmtBtn("arrow.uturn.forward", "Redo (⌘⇧Z)") { editor.redo() }
                sep
                fmtBtn("bold", "Bold") { editor.toggleTrait(.boldFontMask) }
                fmtBtn("italic", "Italic") { editor.toggleTrait(.italicFontMask) }
                fmtBtn("underline", "Underline") { editor.toggleAttribute(.underlineStyle) }
                fmtBtn("strikethrough", "Strikethrough") { editor.toggleAttribute(.strikethroughStyle) }
                sep
                Menu {
                    Button("Body") { editor.setHeading(.body) }
                    Button("Heading 1") { editor.setHeading(.h1) }
                    Button("Heading 2") { editor.setHeading(.h2) }
                    Button("Heading 3") { editor.setHeading(.h3) }
                } label: { Image(systemName: "textformat.size") }.menuStyle(.borderlessButton).fixedSize()
                    .help("Text style — Body / Heading 1–3")
                    .onHover { setHint("Text style — Body / Heading 1–3", $0) }
                fmtBtn("list.bullet", "Bullet list — Tab to indent, Return to continue") { editor.toggleBullet() }
                fmtBtn("list.number", "Numbered list — Tab to indent, Return to continue") { editor.toggleNumbered() }
                fmtBtn("checklist", "Checklist — tap a box to check it off") { editor.toggleChecklist() }
                fmtBtn("text.quote", "Block quote") { editor.toggleQuote() }
                fmtBtn("chevron.left.forwardslash.chevron.right", "Code block") { editor.toggleCodeBlock() }
                fmtBtn("minus", "Divider") { editor.insertDivider() }
                fmtBtn("rectangle.compress.vertical", "Collapse selection into a section") {
                    if editor.hasSelection { foldTitle = ""; foldPrompt = true }
                }
                sep
                Button { colorMode = (colorMode == .highlight ? nil : .highlight) } label: { Image(systemName: "highlighter") }
                    .buttonStyle(.borderless).foregroundStyle(colorMode == .highlight ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .help("Highlight color").onHover { setHint("Highlight color", $0) }
                Button { colorMode = (colorMode == .foreground ? nil : .foreground) } label: { Image(systemName: "paintpalette") }
                    .buttonStyle(.borderless).foregroundStyle(colorMode == .foreground ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .help("Text color").onHover { setHint("Text color", $0) }
                sep
                fmtBtn("function", "Insert equation") { showEquation = true }
                fmtBtn("tablecells", "Insert table — right-click it to add/remove rows & columns, or Tab to add a row") { editor.insertTable() }
                fmtBtn("photo", "Insert image — or drag / paste a screenshot straight in") { editor.insertImage() }
                fmtBtn("character.book.closed", "Define the selected word") { define() }
            }.padding(.horizontal, 10).padding(.vertical, 5)
        }
    }

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
            ScrollView {
                NotePreview(text: draft.body.isEmpty ? "_Nothing to preview yet._" : draft.body)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
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
                .background(.background.secondary)
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

    private func countWords(_ s: String) -> Int {
        s.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
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
                Spacer()
                Menu {
                    Button { askAI { "Make flashcards from this note titled \"\($0.title)\":\n\n\($0.body)" } } label: {
                        Label("Make flashcards", systemImage: "rectangle.on.rectangle.angled")
                    }
                    Button { askAI { "Summarize this note into a few bullet points and save it as a new note titled \"\($0.title) — summary\":\n\n\($0.body)" } } label: {
                        Label("Summarize → note", systemImage: "text.append")
                    }
                    Button { askAI { "Suggest tags and a course link for this note titled \"\($0.title)\":\n\n\($0.body)" } } label: {
                        Label("Tag & link", systemImage: "tag")
                    }
                } label: { Image(systemName: "sparkles") }
                .menuStyle(.borderlessButton).fixedSize()
                .disabled(!AIConfig.isReady)
                .help(AIConfig.isReady ? "Organize with the assistant" : "Enable the assistant in Settings ▸ Intelligence")
                Menu {
                    Button { duplicate() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                    Button { editor.printNote() } label: { Label("Print…", systemImage: "printer") }
                    Divider()
                    Button { exportNote(markdown: true) } label: { Label("Export as Markdown", systemImage: "arrow.down.doc") }
                    Button { exportNote(markdown: false) } label: { Label("Export as Rich Text", systemImage: "arrow.down.doc") }
                } label: { Image(systemName: "square.and.arrow.up") }
                .menuStyle(.borderlessButton).fixedSize()
                Button("Delete", role: .destructive) { delete() }
                if !embedded { Button("Done") { save() }.keyboardShortcut(.defaultAction) }
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
        }.background(.background.secondary)
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
        }.background(.background.secondary)
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
        }.background(.background.secondary.opacity(0.5))
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
        .padding(8).background(.background.secondary, in: RoundedRectangle(cornerRadius: DS.Radius.card))
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
        draft.updatedAt = .now
        let empty = draft.title.trimmingCharacters(in: .whitespaces).isEmpty
            && draft.body.trimmingCharacters(in: .whitespaces).isEmpty && draft.imagePath.isEmpty
        if empty {
            state.data.notes.removeAll { $0.id == draft.id }   // discard blank
        } else if let i = state.data.notes.firstIndex(where: { $0.id == draft.id }) {
            state.data.notes[i] = draft
        } else {
            state.data.notes.append(draft)
        }
    }
    private func askAI(_ make: (Note) -> String) {
        persist()
        AppActions.assistant(make(draft))
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

    private func exportNote(markdown: Bool) {
        persist()
        let panel = NSSavePanel()
        let name = draft.title.isEmpty ? "Note" : draft.title
        panel.nameFieldStringValue = name + (markdown ? ".md" : ".rtf")
        panel.allowedContentTypes = markdown ? [.plainText] : [.rtf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if markdown {
            try? markdownExport(draft.body).data(using: .utf8)?.write(to: url)
        } else {
            let attr = editor.attributedString.expandingMath().expandingFolds()
            let data = try? attr.data(from: NSRange(location: 0, length: attr.length),
                                      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            try? data?.write(to: url)
        }
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
