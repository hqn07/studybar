import SwiftUI
import UniformTypeIdentifiers

enum AssignmentSort: String, CaseIterable, Identifiable {
    case due = "Due date", urgency = "Urgency"
    var id: String { rawValue }
}

/// What the list is scoped to. A term's worth of imported coursework is a few hundred rows,
/// which is a list nobody works from — so the default is the part you can actually act on
/// this week, and everything else is one click away.
enum AssignmentScope: String, CaseIterable, Identifiable {
    case week = "This week", overdue = "Overdue", all = "All", archived = "Archived"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .week: "calendar"; case .overdue: "exclamationmark.triangle"
        case .all: "tray.full"; case .archived: "archivebox"
        }
    }

    /// Whether `a` is in this scope — one rule for the list, the number on its glance, and
    /// Today's tile and banner that open it, so a number you click is the list you land on.
    /// Counts leave `showDone` off: they count open work.
    func includes(_ a: Assignment, hideBusywork: Bool, showDone: Bool = false) -> Bool {
        // Attendance and admin stay in the store and in All — they're just not what you
        // open the app to look at.
        if hideBusywork, a.isBusywork, self == .week || self == .overdue { return false }
        switch self {
        case .archived: return a.isArchived
        case .all:      return !a.isArchived && (showDone || a.status != .done)
        case .overdue:  return a.isOpen && a.isOverdue
        case .week:     return !a.isArchived && (showDone || a.status != .done) && Self.isThisWeek(a)
        }
    }

    /// Due within the next week, already overdue, or undated (a captured task) — i.e. the
    /// things there is any point looking at today.
    static func isThisWeek(_ a: Assignment) -> Bool {
        guard let days = a.daysUntilDue else { return true }   // no due date = a loose task
        return days <= 7
    }
}

struct AssignmentsView: View {
    @EnvironmentObject var state: AppState
    @State private var showDone = false
    @State private var editing: Assignment?
    @State private var classifying = false
    @State private var deduping = false
    @State private var quickAdd = ""
    @State private var selectedID: UUID?
    @FocusState private var quickFocused: Bool
    @AppStorage("assignmentSort") private var sort = AssignmentSort.due.rawValue
    @AppStorage("assignmentScope") private var scope = AssignmentScope.week.rawValue
    /// Once items are sorted, hiding the housekeeping is what makes the list usable.
    @AppStorage("assignmentHideBusywork") private var hideBusywork = true
    @State private var triaging = false

    private var legacyTodos: Int { state.data.todos.count }

    private var unsortedImports: Int { CanvasFeedImport.unclassified(state).count }

    private var sortMode: AssignmentSort { AssignmentSort(rawValue: sort) ?? .due }
    private var scopeMode: AssignmentScope { AssignmentScope(rawValue: scope) ?? .week }

    /// Imported rather than typed, and more than a week past due: the tail that makes the
    /// list unusable. A week is the line because anything imported that is still untouched
    /// after one is not going to be done in here. Offered, never archived automatically.
    private var stale: [Assignment] {
        state.data.assignments.filter { $0.isOpen && $0.sourceUID != nil && ($0.daysUntilDue ?? 0) < -7 }
    }

    private var triagedCount: Int { state.data.assignments.filter { $0.kind != nil }.count }
    /// The housekeeping this scope leaves out — what "N housekeeping hidden" counts.
    private var busyworkCount: Int {
        state.data.assignments.filter {
            scopeMode.includes($0, hideBusywork: false, showDone: showDone) && !scopeMode.includes($0, hideBusywork: true, showDone: showDone)
        }.count
    }

    private var list: [Assignment] {
        let base = state.data.assignments.filter { scopeMode.includes($0, hideBusywork: hideBusywork, showDone: showDone) }
        switch sortMode {
        case .due:
            return base.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
        case .urgency:
            // Ranked first (Now→Later), unranked last; ties break by due date.
            return base.sorted { lhs, rhs in
                let l = lhs.urgency ?? -1, r = rhs.urgency ?? -1
                if l != r { return l > r }
                return (lhs.due ?? .distantFuture) < (rhs.due ?? .distantFuture)
            }
        }
    }

    private var anyRanked: Bool { state.data.assignments.contains { $0.urgency != nil && $0.isOpen } }

    var body: some View {
        NavigationStack {
            ModulePane(title: "Assignments",
                       primary: ModuleAction(title: "New", systemImage: "plus", help: "New assignment") { newAssignment() },
                       controls: {
                if unsortedImports > 0 {
                    Button { classifying = true } label: {
                        Label("\(unsortedImports)", systemImage: "tray.and.arrow.down")
                    }.help("Sort \(unsortedImports) imported Canvas items into courses")
                }
            }, more: {
                Button { state.selectedModuleID = "board" } label: { Label("Board view", systemImage: "rectangle.split.3x1") }
                Button { deduping = true } label: { Label("Find duplicate assignments…", systemImage: "square.on.square") }
                Button { triaging = true } label: {
                    Label(triagedCount == 0 ? "Sort imported items into work, attendance and admin…"
                          : "Sort the \(state.data.assignments.filter { $0.isOpen && $0.kind == nil }.count) unsorted items…",
                          systemImage: "tray.2")
                }
                if anyRanked {
                    Menu {
                        ForEach(AssignmentSort.allCases) { s in
                            Button { sort = s.rawValue } label: {
                                Label(s.rawValue, systemImage: sortMode == s ? "checkmark" : "arrow.up.arrow.down")
                            }
                        }
                    } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
                }
                Divider()
                Button { exportDeadlines(open: true) } label: { Label("Add Deadlines to Calendar…", systemImage: "calendar.badge.plus") }
                Button { exportDeadlines(open: false) } label: { Label("Save Deadlines as .ics…", systemImage: "square.and.arrow.down") }
                Divider()
                Toggle("Show done", isOn: $showDone)
            }) {
                VStack(spacing: 0) {
                    quickAddBar
                    scopeBar
                    if legacyTodos > 0 { importBanner; Divider() }
                    if scopeMode != .archived, !stale.isEmpty { staleBanner; Divider() }
                    if list.isEmpty {
                        EmptyState(symbol: emptySymbol, title: emptyTitle, subtitle: emptySubtitle)
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 0) {
                                    ForEach(list) { a in
                                        AssignmentRow(assignment: a) { editing = a }
                                            .kbSelected(a.id == selectedID)
                                            .id(a.id)
                                            .transition(.move(edge: .leading).combined(with: .opacity))
                                    }
                                }.padding(DS.Space.m)
                                .animation(.snappy(duration: 0.28), value: list)   // complete/add slides, not pops
                            }
                            .keyboardListNav(ids: list.map(\.id), selection: $selectedID,
                                             onActivate: { id in editing = list.first { $0.id == id } },
                                             onEscape: { selectedID = nil })
                            .onChange(of: selectedID) { _, id in
                                if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) } }
                            }
                        }
                    }
                }
            }
            .navigationDestination(item: $editing) { AssignmentEditor(assignment: $0).moduleColumn(DS.Width.form) }
            .navigationDestination(isPresented: $classifying) { ClassifyView().moduleColumn() }
            .navigationDestination(isPresented: $deduping) { DuplicateReviewView().moduleColumn() }
            .navigationDestination(isPresented: $triaging) { TriageReviewView().moduleColumn() }
            .onAppear(perform: consumePending)
            .onChange(of: state.pendingNew) { _, _ in consumePending() }
        }
    }

    // MARK: Scope — the list you work from, not the list of everything

    /// The scopes as glance numbers you click — the summary and the filter in one strip.
    private var scopeBar: some View {
        HStack(spacing: DS.Space.m) {
            GlanceFilter(items: AssignmentScope.allCases.map { s in
                GlanceFilter.Item(id: s.rawValue, count: count(for: s), label: s.rawValue.lowercased(), help: help(for: s),
                                  selected: scopeMode == s) { withAnimation(.snappy(duration: 0.2)) { scope = s.rawValue } }
            })
            if busyworkCount > 0 {
                Button { withAnimation(.snappy(duration: 0.2)) { hideBusywork.toggle() } } label: {
                    Text(hideBusywork ? "\(busyworkCount) housekeeping hidden" : "Showing housekeeping")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(hideBusywork
                      ? "Attendance and admin are hidden from This week and Overdue — click to show them"
                      : "Click to hide attendance and admin again")
            }
            Spacer()
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.bottom, DS.Space.s)
    }

    private func count(for s: AssignmentScope) -> Int {
        state.data.assignments.filter { s.includes($0, hideBusywork: hideBusywork) }.count
    }

    private func help(for s: AssignmentScope) -> String {
        switch s {
        case .week: "Due in the next 7 days, overdue, or undated"
        case .overdue: "Past due and not done"
        case .all: "Every open assignment"
        case .archived: "Put aside — still here, not deleted"
        }
    }

    private var emptySymbol: String { scopeMode == .week ? "checkmark.circle" : "checklist" }
    private var emptyTitle: String {
        switch scopeMode {
        case .week: "Nothing due this week"
        case .overdue: "Nothing overdue"
        case .archived: "Nothing archived"
        case .all: "No assignments"
        }
    }
    private var emptySubtitle: String {
        switch scopeMode {
        case .week: "Later work is still under All."
        case .overdue: "You're caught up."
        case .archived: "Archived assignments stay here until you restore them."
        case .all: "Add homework, papers and exams — or a quick task above."
        }
    }

    /// Imported coursework that went past due weeks ago is what turns the list into a wall.
    /// Archiving is a one-click, undoable move — not a delete, and never automatic.
    private var staleBanner: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: "archivebox").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(stale.count) imported \(stale.count == 1 ? "assignment is" : "assignments are") more than a week past due")
                    .font(.callout)
                Text("Archive them to clear the list — they stay under Archived, and Undo puts them back.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Archive \(stale.count)") { archiveStale() }
                .buttonStyle(.borderedProminent).controlSize(.small)
        }
        .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
    }

    private func archiveStale() {
        let ids = Set(stale.map(\.id))
        guard !ids.isEmpty else { return }
        state.withUndo("Archived \(ids.count) assignment\(ids.count == 1 ? "" : "s")") {
            for i in state.data.assignments.indices where ids.contains(state.data.assignments[i].id) {
                state.data.assignments[i].archived = true
            }
        }
    }

    // MARK: Quick add — the lightweight task capture that used to be the To-Do module.

    private var quickAddBar: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: "plus.circle.fill").foregroundStyle(.tint)
            TextField("Add a task or assignment…", text: $quickAdd)
                .textFieldStyle(.plain).focused($quickFocused)
                .onSubmit(addQuick)
            if !quickAdd.isEmpty {
                Button("Add", action: addQuick).buttonStyle(.borderless).font(.caption)
            }
        }
        .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)
        .background(.sbSurface.opacity(0.5))
    }

    /// One-tap, undoable import of the old To-Do list into Assignments. Non-destructive:
    /// backed up first (if a backup folder is set) and reversible via the undo banner.
    private var importBanner: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: "tray.and.arrow.down").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(legacyTodos) to-do\(legacyTodos == 1 ? "" : "s") from the old list")
                    .font(.callout.weight(.medium))
                Text("To-Do merged into Assignments. Import to keep them here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Import", action: importTodos).buttonStyle(.borderedProminent).controlSize(.small)
        }
        .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)
        .background(.tint.opacity(0.08))
    }

    private func addQuick() {
        let t = quickAdd.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        state.data.assignments.append(Assignment(task: t))
        quickAdd = ""
        quickFocused = true
    }

    private func importTodos() {
        let todos = state.data.todos
        guard !todos.isEmpty else { return }
        _ = BackupManager.backupNow(state.data)   // best-effort snapshot before the move
        state.withUndo("Import \(todos.count) to-do\(todos.count == 1 ? "" : "s")") {
            for t in todos {
                let a = Assignment(migrating: t)
                state.data.assignments.append(a)
                // Repoint any time-block that had planned this to-do onto the new assignment.
                let blocks = state.data.timeBlocks ?? []
                if blocks.contains(where: { $0.todoID == t.id }) {
                    var updated = blocks
                    for i in updated.indices where updated[i].todoID == t.id {
                        updated[i].assignmentID = a.id; updated[i].todoID = nil
                    }
                    state.data.timeBlocks = updated
                }
            }
            state.data.todos.removeAll()
        }
    }

    private func consumePending() {
        if state.pendingNew == "assignments" { state.pendingNew = nil; quickFocused = true }
    }
    /// Open deadlines as a calendar file. Add hands it to Calendar, which asks which calendar to
    /// put them in; Save is for Google Calendar or Outlook.
    private func exportDeadlines(open: Bool) {
        let text = ICSExport.calendar(state.data.assignments, courses: state.data.courses)
        let url: URL
        if open {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("StudyBar deadlines.ics")
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "StudyBar deadlines.ics"
            panel.allowedContentTypes = [UTType(filenameExtension: "ics") ?? .data]
            guard panel.runModal() == .OK, let picked = panel.url else { return }
            url = picked
        }
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { Diagnostics.log(.data, .error, "deadlines .ics: \(error.localizedDescription)"); return }
        if open, let calendar = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.open([url], withApplicationAt: calendar, configuration: NSWorkspace.OpenConfiguration())
        } else if !open {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func newAssignment() {
        editing = Assignment(title: "", due: Calendar.current.date(byAdding: .day, value: 1, to: .now))
    }
}

struct AssignmentRow: View {
    @EnvironmentObject var state: AppState
    let assignment: Assignment
    let onEdit: () -> Void

    private var done: Bool { assignment.status == .done }

    // Course · points · subtasks — the one clean secondary line.
    private var subtitle: String {
        var parts: [String] = []
        if let c = state.course(assignment.courseID) { parts.append(c.code.isEmpty ? c.name : c.code) }
        if let p = assignment.points, p > 0 { parts.append("\(Int(p)) pts") }
        if !assignment.checklist.isEmpty {
            parts.append("\(assignment.checklist.filter(\.done).count)/\(assignment.checklist.count) subtasks")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: DS.Space.l) {
            Button { toggleDone() } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(done ? AnyShapeStyle(Color.dsDone) : AnyShapeStyle(.secondary))
            }.buttonStyle(.plain)
                .accessibilityLabel(done ? "Mark not done" : "Mark done")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DS.Space.xs) {
                    Text(assignment.title.isEmpty ? "Untitled" : assignment.title)
                        .font(.callout.weight(.medium)).strikethrough(done).lineLimit(1)
                    if assignment.sourceFeedID != nil {
                        Image(systemName: "link").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.tint).help("Imported from a Canvas feed")
                    }
                }
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            Spacer(minLength: DS.Space.s)

            statusChip
            dueText
            if !assignment.link.isEmpty {
                Button { open(assignment.link) } label: { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel("Open link")
            }
            Button { onEdit() } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .accessibilityLabel("Edit assignment")
        }
        .padding(DS.Space.m)
        .sbRowSeparator(leading: DS.Space.m)
        .contextMenu {
            Button { toggleDone() } label: {
                Label(done ? "Mark not done" : "Mark done", systemImage: done ? "arrow.uturn.backward" : "checkmark")
            }
            if !done, assignment.due != nil {
                Button { AppActions.snoozeAssignment(id: assignment.id, days: 1) } label: { Label("Snooze 1 day", systemImage: "clock") }
                Button { AppActions.snoozeAssignment(id: assignment.id, days: 7) } label: { Label("Snooze 1 week", systemImage: "clock") }
            }
            Button { onEdit() } label: { Label("Edit…", systemImage: "pencil") }
            Button { setArchived(!assignment.isArchived) } label: {
                Label(assignment.isArchived ? "Restore" : "Archive",
                      systemImage: assignment.isArchived ? "arrow.uturn.backward" : "archivebox")
            }
            Divider()
            Button(role: .destructive) {
                state.withUndo("Deleted assignment") { state.data.assignments.removeAll { $0.id == assignment.id } }
            } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func setArchived(_ on: Bool) { ItemActions.setArchived(assignment.id, on, state: state) }

    @ViewBuilder private var statusChip: some View {
        if !done {
            if assignment.submitted {
                Chip("Submitted", .status(.done), systemImage: "checkmark.seal.fill")
            } else if let label = assignment.urgencyLabel {
                Chip(label, .status(urgencyStatus(assignment.urgency ?? 0)))
            }
        }
    }
    private func urgencyStatus(_ level: Int) -> Chip.Status { level >= 2 ? .now : (level == 1 ? .week : .neutral) }

    @ViewBuilder private var dueText: some View {
        if let due = assignment.due {
            let days = assignment.daysUntilDue ?? 0
            let color: Color = assignment.isOverdue ? .dsNow : (days <= 1 ? .dsWeek : (days <= 3 ? .orange : .secondary))
            Text(dueLabel(days: days, overdue: assignment.isOverdue))
                .font(.caption2.weight(.semibold)).foregroundStyle(color)
                .help(due.formatted(date: .abbreviated, time: .omitted))
        }
    }
    private func dueLabel(days: Int, overdue: Bool) -> String {
        if overdue { return "Overdue" }
        switch days { case 0: return "Today"; case 1: return "1d"; default: return "\(days)d" }
    }

    /// (12) Recurring: finishing a weekly item adds next week's copy — shared with ⌘K.
    private func toggleDone() { ItemActions.toggleDone(assignment.id, state: state) }

    private func open(_ s: String) {
        guard let url = URL(string: s.contains("://") ? s : "https://\(s)") else { return }
        NSWorkspace.shared.open(url)
    }
}
