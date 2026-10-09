import SwiftUI

/// A thing in one of the lists — what a row is, what the window has selected, what ⌘K remembers.
enum ItemRef: Hashable {
    case note(UUID), assignment(UUID), deck(UUID), book(UUID), link(UUID), readLater(UUID), citation(UUID), snippet(UUID)

    /// "note:<uuid>" — how ⌘K's recents store it.
    var recentKey: String {
        switch self {
        case .note(let id): "note:\(id.uuidString)"
        case .assignment(let id): "assignment:\(id.uuidString)"
        case .deck(let id): "deck:\(id.uuidString)"
        case .book(let id): "book:\(id.uuidString)"
        case .link(let id): "link:\(id.uuidString)"
        case .readLater(let id): "readLater:\(id.uuidString)"
        case .citation(let id): "citation:\(id.uuidString)"
        case .snippet(let id): "snippet:\(id.uuidString)"
        }
    }

    init?(recentKey: String) {
        let parts = recentKey.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
        switch parts[0] {
        case "note": self = .note(id)
        case "assignment": self = .assignment(id)
        case "deck": self = .deck(id)
        case "book": self = .book(id)
        case "link": self = .link(id)
        case "readLater": self = .readLater(id)
        case "citation": self = .citation(id)
        case "snippet": self = .snippet(id)
        default: return nil
        }
    }
}

struct ItemAction: Identifiable {
    let title: String
    let systemImage: String
    var shortcut: String? = nil
    var destructive = false
    let run: () -> Void
    var id: String { title }
}

/// A note action that runs in the note's editor: Notes opens the note, its editor takes this once.
struct PendingNoteAction: Equatable {
    enum Kind { case makeCards, quizMe, studyNotes, exportPDF, edit }
    let id: UUID
    let kind: Kind
}

/// What can be done to each kind of item — one list feeding both the row's context menu and
/// ⌘K, so the two never drift. Removal always goes through Undo (and the Trash); decks are
/// never removed from here, since a deck's cards go with it.
@MainActor
enum ItemActions {
    static func title(of ref: ItemRef, in data: AppData) -> String? {
        switch ref {
        case .note(let id): data.notes.first { $0.id == id }?.listTitle
        case .assignment(let id): data.assignments.first { $0.id == id }.map { $0.title.isEmpty ? "Untitled" : $0.title }
        case .deck(let id): data.decks.first { $0.id == id }.map { $0.name.isEmpty ? "Untitled deck" : $0.name }
        case .book(let id): data.reading.first { $0.id == id }?.title
        case .link(let id): data.links.first { $0.id == id }.map { $0.title.isEmpty ? $0.url : $0.title }
        case .readLater(let id): data.readingList.first { $0.id == id }?.title
        case .citation(let id): data.references.first { $0.id == id }?.title
        case .snippet(let id): data.snippets.first { $0.id == id }.map { $0.title.isEmpty ? $0.keyword : $0.title }
        }
    }

    static func actions(for ref: ItemRef, state: AppState) -> [ItemAction] {
        guard title(of: ref, in: state.data) != nil else { return [] }
        switch ref {
        case .note(let id): return note(id, state)
        case .assignment(let id): return assignment(id, state)
        case .deck(let id): return [
            ItemAction(title: "Review", systemImage: "play.fill") { state.pendingReview = true; state.pendingDeck = id; go("flashcards", state) },
            ItemAction(title: "Open", systemImage: "rectangle.on.rectangle.angled") { state.pendingDeck = id; go("flashcards", state) },
        ]
        case .book(let id): return book(id, state)
        case .link(let id):
            let url = state.data.links.first { $0.id == id }?.url ?? ""
            return [
                ItemAction(title: "Open in browser", systemImage: "safari") { openURL(url) },
                ItemAction(title: "Copy link", systemImage: "doc.on.doc") { copy(url) },
                ItemAction(title: "Edit…", systemImage: "pencil") { edit(ref, in: "library", state) },
                remove("Delete", "Deleted link", state) { $0.links.removeAll { $0.id == id } },
            ]
        case .readLater(let id):
            let item = state.data.readingList.first { $0.id == id }
            return [
                ItemAction(title: "Open in browser", systemImage: "safari") { openURL(item?.url ?? "") },
                ItemAction(title: "Copy link", systemImage: "doc.on.doc") { copy(item?.url ?? "") },
                ItemAction(title: item?.read == true ? "Mark unread" : "Mark read", systemImage: "checkmark.circle") {
                    if let i = state.data.readingList.firstIndex(where: { $0.id == id }) { state.data.readingList[i].read.toggle() }
                },
                remove("Delete", "Removed from Read later", state) { $0.readingList.removeAll { $0.id == id } },
            ]
        case .citation(let id):
            let r = state.data.references.first { $0.id == id }
            return [
                ItemAction(title: "Copy citation", systemImage: "doc.on.doc") { if let r { copy(citation(r)) } },
                ItemAction(title: "Edit…", systemImage: "pencil") { edit(ref, in: "citations", state) },
                ItemAction(title: "Copy in-text citation", systemImage: "text.quote") { if let r { copy(CitationFormatter.inText(r)) } },
                remove("Delete", "Deleted citation", state) { $0.references.removeAll { $0.id == id } },
            ]
        case .snippet(let id): return [
            ItemAction(title: "Copy", systemImage: "doc.on.doc") { copySnippet(id, state: state) },
            ItemAction(title: "Edit…", systemImage: "pencil") { edit(ref, in: "snippets", state) },
            remove("Delete", "Deleted snippet", state) { $0.snippets.removeAll { $0.id == id } },
        ]
        }
    }

    // MARK: Per kind

    private static func note(_ id: UUID, _ state: AppState) -> [ItemAction] {
        func inEditor(_ k: PendingNoteAction.Kind) { open(id, state); state.pendingNoteAction = .init(id: id, kind: k) }
        return [
            ItemAction(title: "Open", systemImage: "note.text") { open(id, state) },
            ItemAction(title: "Make flashcards…", systemImage: "rectangle.on.rectangle.angled") { inEditor(.makeCards) },
            ItemAction(title: "Quiz me", systemImage: "checklist") { inEditor(.quizMe) },
            ItemAction(title: "Study notes…", systemImage: "text.badge.star") { inEditor(.studyNotes) },
            ItemAction(title: "Edit", systemImage: "pencil", shortcut: "⌘E") { inEditor(.edit) },
            ItemAction(title: "Export as PDF", systemImage: "arrow.down.doc") { inEditor(.exportPDF) },
            ItemAction(title: "Open in New Tab", systemImage: "plus.square.on.square") {
                WindowManager.shared.newTab(moduleID: "notes") { $0.openNote = id }
            },
            ItemAction(title: "Open in New Window", systemImage: "macwindow.badge.plus") {
                WindowManager.shared.newWindow(moduleID: "notes") { $0.openNote = id }
            },
            remove("Move to Trash", "Deleted note", state) { $0.notes.removeAll { $0.id == id } },
        ]
    }

    private static func assignment(_ id: UUID, _ state: AppState) -> [ItemAction] {
        guard let a = state.data.assignments.first(where: { $0.id == id }) else { return [] }
        let done = a.status == .done
        var out = [ItemAction(title: done ? "Mark not done" : "Mark done", systemImage: done ? "arrow.uturn.backward" : "checkmark") {
            toggleDone(id, state: state)
        }]
        if !done, a.due != nil {
            out.append(ItemAction(title: "Snooze 1 day", systemImage: "clock") { AppActions.snoozeAssignment(id: id, days: 1) })
            out.append(ItemAction(title: "Snooze 1 week", systemImage: "clock") { AppActions.snoozeAssignment(id: id, days: 7) })
        }
        out += [
            ItemAction(title: "Add to today's plan", systemImage: "calendar.badge.plus") {
                if let a = state.data.assignments.first(where: { $0.id == id }) {
                    _ = state.planAssignment(a, on: Date())
                    UserDefaults.standard.set("plan", forKey: "scheduleMode")
                    go("schedule", state)
                }
            },
            ItemAction(title: "Start focus", systemImage: "timer") { AppActions.startFocus(label: a.title); go("timefocus", state) },
            ItemAction(title: "Edit…", systemImage: "pencil") { edit(.assignment(id), in: "assignments", state) },
            ItemAction(title: a.isArchived ? "Restore" : "Archive", systemImage: a.isArchived ? "arrow.uturn.backward" : "archivebox") {
                setArchived(id, !a.isArchived, state: state)
            },
            remove("Delete", "Deleted assignment", state) { $0.assignments.removeAll { $0.id == id } },
        ]
        return out
    }

    private static func book(_ id: UUID, _ state: AppState) -> [ItemAction] {
        guard let b = state.data.reading.first(where: { $0.id == id }) else { return [] }
        return [
            ItemAction(title: "Open", systemImage: "book") { state.pendingBook = .init(id: id, page: nil); go("reading", state) },
            ItemAction(title: "Edit…", systemImage: "pencil") { edit(.book(id), in: "reading", state) },
            ItemAction(title: b.done ? "Mark unread" : "Mark done", systemImage: b.done ? "arrow.uturn.left" : "checkmark.circle") {
                state.toggleReadingDone(id)
            },
            ItemAction(title: "Add to Reading List", systemImage: "bookmark") { _ = state.addToReadingList(b) },
            remove("Delete", "Deleted book", state) { $0.reading.removeAll { $0.id == id } },
        ]
    }

    // MARK: Shared with the rows

    /// Done ↔ not done; finishing a weekly item adds next week's copy.
    static func toggleDone(_ id: UUID, state: AppState) {
        guard let i = state.data.assignments.firstIndex(where: { $0.id == id }) else { return }
        let nowDone = state.data.assignments[i].status != .done
        state.data.assignments[i].setDone(nowDone)
        if nowDone, state.data.assignments[i].recurring, let due = state.data.assignments[i].due {
            var next = state.data.assignments[i]
            next.id = UUID()
            next.status = .todo
            next.due = Calendar.current.date(byAdding: .day, value: 7, to: due)
            next.checklist = next.checklist.map { var c = $0; c.done = false; return c }
            state.data.assignments.append(next)
        }
    }

    static func setArchived(_ id: UUID, _ on: Bool, state: AppState) {
        state.withUndo(on ? "Archived assignment" : "Restored assignment") {
            guard let i = state.data.assignments.firstIndex(where: { $0.id == id }) else { return }
            state.data.assignments[i].archived = on ? true : nil
        }
    }

    /// The citation in the style Citations is set to, without markdown emphasis.
    static func citation(_ r: Reference) -> String {
        let style = CiteStyle(rawValue: UserDefaults.standard.string(forKey: "citeStyle") ?? "") ?? .apa
        return CitationFormatter.format(r, style: style).replacingOccurrences(of: "*", with: "")
    }

    /// A snippet's body with its placeholders filled, on the clipboard (not recorded in clipboard history).
    static func copySnippet(_ id: UUID, state: AppState) {
        guard let i = state.data.snippets.firstIndex(where: { $0.id == id }) else { return }
        state.clipboard.enabled = false
        copy(SnippetExpand.run(state.data.snippets[i].body))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { state.clipboard.enabled = true }
        state.data.snippets[i].uses += 1
    }

    // MARK: Plumbing

    private static func remove(_ title: String, _ undoLabel: String, _ state: AppState,
                               _ mutation: @escaping (inout AppData) -> Void) -> ItemAction {
        ItemAction(title: title, systemImage: "trash", destructive: true) { state.withUndo(undoLabel) { mutation(&state.data) } }
    }

    private static func go(_ module: String, _ state: AppState) {
        WindowOpener.open?("main")
        state.globalSearch = ""
        state.selectedModuleID = module
    }

    private static func open(_ id: UUID, _ state: AppState) {
        state.pendingOpenNote = id
        go("notes", state)
    }

    private static func edit(_ ref: ItemRef, in module: String, _ state: AppState) {
        if module == "library" { UserDefaults.standard.set(LibraryTab.links.rawValue, forKey: "libraryTab") }
        state.pendingEdit = ref
        go(module, state)
    }

    private static func openURL(_ s: String) {
        guard let url = URL(string: s.contains("://") ? s : "https://\(s)") else { return }
        NSWorkspace.shared.open(url)
    }

    private static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

/// The selected row of the left pane's list, published up to the window (for ⌘K).
struct SelectionKey: PreferenceKey {
    static let defaultValue: ItemRef? = nil
    static func reduce(value: inout ItemRef?, nextValue: () -> ItemRef?) { value = nextValue() ?? value }
}

extension View {
    /// The row's context menu: its kind's actions, the destructive one after a divider.
    @MainActor func itemContextMenu(_ ref: ItemRef, state: AppState) -> some View {
        contextMenu {
            ForEach(ItemActions.actions(for: ref, state: state)) { a in
                if a.destructive { Divider() }
                Button(role: a.destructive ? .destructive : nil, action: a.run) { Label(a.title, systemImage: a.systemImage) }
            }
        }
    }
}
