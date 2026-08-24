import SwiftUI

enum NoteSort: String, CaseIterable, Identifiable {
    case updated = "Last edited", created = "Date created", title = "Title"
    var id: String { rawValue }
}

struct NotesView: View {
    @EnvironmentObject var state: AppState
    @State private var editing: Note?
    @State private var search = ""
    @State private var sort = NoteSort.updated

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
        NavigationStack {
            ModulePane(title: "Notes") {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(NoteSort.allCases) { s in
                            Button { sort = s } label: { Label(s.rawValue, systemImage: sort == s ? "checkmark" : "arrow.up.arrow.down") }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    Button { screenshotNote() } label: { Image(systemName: "camera.viewfinder") }.help("Screenshot to note")
                    Button { newNote() } label: { Image(systemName: "square.and.pencil") }
                }
            } content: {
                VStack(spacing: 0) {
                    if state.data.notes.count > 4 { SearchField(text: $search).padding(8); Divider() }
                    if notes.isEmpty {
                        EmptyState(symbol: "note.text",
                                   title: state.data.notes.isEmpty ? "No notes yet" : "No matches",
                                   subtitle: state.data.notes.isEmpty ? "Capture ideas, lecture notes and reminders. Markdown supported." : "Try a different search.")
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 6) {
                                ForEach(notes) { n in NoteRow(note: n) { editing = n } }
                            }.padding(10)
                        }
                    }
                }
            }
            .navigationDestination(item: $editing) { NoteEditor(note: $0) }
            .onAppear(perform: consumePending)
            .onChange(of: state.pendingNew) { _, _ in consumePending() }
        }
    }

    private func consumePending() {
        if state.pendingNew == "notes" { state.pendingNew = nil; newNote() }
    }
    private func newNote() { editing = Note() }        // insert only on Save

    private func screenshotNote() {
        // Append first so the note survives if the popover dismisses during capture.
        let note = Note(title: "Screenshot \(Date().dayMonth)")
        let id = note.id
        state.data.notes.append(note)
        ScreenshotService.captureInteractive { name in
            guard let i = state.data.notes.firstIndex(where: { $0.id == id }) else { return }
            if let name {
                state.data.notes[i].imagePath = name
                editing = state.data.notes[i]     // opens the editor if the popover is still up
            } else {
                state.data.notes.remove(at: i)     // cancelled → discard
            }
        }
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
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 8) {
                if note.pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.orange) }
                if let img = screenshotImage(note.imagePath) {
                    Image(nsImage: img).resizable().scaledToFill()
                        .frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 5))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.title.isEmpty ? firstLine : note.title)
                        .fontWeight(.medium).lineLimit(1)
                    Text(note.body.isEmpty ? "No content" : note.body)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    HStack(spacing: 6) {
                        CourseChip(course: state.course(note.courseID))
                        ForEach(note.tags, id: \.self) { t in
                            Text("#\(t)").font(.caption2).foregroundStyle(.tint)
                        }
                    }
                }
                Spacer()
            }
            .padding(10).contentShape(Rectangle())
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }

    private var firstLine: String {
        note.body.split(separator: "\n").first.map(String.init) ?? "Untitled"
    }
}

struct NoteEditor: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Note
    @State private var tagText: String
    @State private var showPreview = false
    @State private var saveTask: Task<Void, Never>?

    init(note: Note) {
        _draft = State(initialValue: note)
        _tagText = State(initialValue: note.tags.joined(separator: ", "))
    }

    private var words: Int { draft.body.split { $0.isWhitespace || $0.isNewline }.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { save() } label: { Image(systemName: "chevron.left").fontWeight(.semibold) }
                    .buttonStyle(.borderless).help("Back (saves)").keyboardShortcut("[", modifiers: .command)
                TextField("Title", text: $draft.title).textFieldStyle(.plain).font(.title3.bold())
                Button { showPreview.toggle() } label: { Image(systemName: showPreview ? "eye.fill" : "eye") }
                    .buttonStyle(.borderless).foregroundStyle(showPreview ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)).help("Preview Markdown")
                Button { draft.pinned.toggle() } label: {
                    Image(systemName: draft.pinned ? "pin.fill" : "pin")
                }.buttonStyle(.borderless).foregroundStyle(draft.pinned ? .orange : .secondary)
            }.padding(12)
            Divider()
            if let img = screenshotImage(draft.imagePath) {
                Image(nsImage: img).resizable().scaledToFit()
                    .frame(maxHeight: 200).frame(maxWidth: .infinity)
                    .background(.background.secondary)
                Divider()
            }
            if showPreview {
                ScrollView {
                    RichText(text: draft.body.isEmpty ? "_Nothing to preview yet._" : draft.body)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
            } else {
                TextEditor(text: $draft.body)
                    .font(.body).padding(8).scrollContentBackground(.hidden)
            }
            Divider()
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    CoursePicker(courseID: $draft.courseID)
                    Divider().frame(height: 14)
                    AssignmentPicker(assignmentID: $draft.assignmentID)
                    Spacer()
                    Text("\(words) words").font(.caption2).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Image(systemName: "tag").font(.caption).foregroundStyle(.secondary)
                    TextField("tags, comma separated", text: $tagText).textFieldStyle(.plain).font(.caption)
                    Spacer()
                    Menu {
                        Button { askAI("Make flashcards from this note titled \"\(draft.title)\":\n\n\(draft.body)") } label: {
                            Label("Make flashcards", systemImage: "rectangle.on.rectangle.angled")
                        }
                        Button { askAI("Summarize this note into a few bullet points and save it as a new note titled \"\(draft.title) — summary\":\n\n\(draft.body)") } label: {
                            Label("Summarize → note", systemImage: "text.append")
                        }
                        Button { askAI("Suggest tags and a course link for this note titled \"\(draft.title)\":\n\n\(draft.body)") } label: {
                            Label("Tag & link", systemImage: "tag")
                        }
                    } label: {
                        Image(systemName: "sparkles")
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .disabled(draft.body.trimmingCharacters(in: .whitespaces).isEmpty || !AIConfig.isReady)
                    .help(AIConfig.isReady ? "Organize with the assistant" : "Enable the assistant in Settings ▸ Intelligence")
                    Button("Delete", role: .destructive) { delete() }
                    Button("Done") { save() }.keyboardShortcut(.defaultAction)
                }
            }.padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("")
        .toolbar(.hidden, for: .windowToolbar)
        // Autosave: debounce while typing, and always flush when the editor goes
        // away — including when the user switches modules from the sidebar (which
        // tears the editor down without hitting Back/Done).
        .onChange(of: draft.body)          { _, _ in scheduleAutosave() }
        .onChange(of: draft.title)         { _, _ in scheduleAutosave() }
        .onChange(of: tagText)             { _, _ in scheduleAutosave() }
        .onChange(of: draft.pinned)        { _, _ in scheduleAutosave() }
        .onChange(of: draft.courseID)      { _, _ in scheduleAutosave() }
        .onChange(of: draft.assignmentID)  { _, _ in scheduleAutosave() }
        .onDisappear { saveTask?.cancel(); persist() }
    }

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
    private func askAI(_ prompt: String) {
        persist()
        AppActions.assistant(prompt)
    }
    private func delete() {
        state.data.notes.removeAll { $0.id == draft.id }
        dismiss()
    }
}
