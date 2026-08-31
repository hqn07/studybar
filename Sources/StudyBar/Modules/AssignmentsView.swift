import SwiftUI

enum AssignmentSort: String, CaseIterable, Identifiable {
    case due = "Due date", urgency = "Urgency"
    var id: String { rawValue }
}

struct AssignmentsView: View {
    @EnvironmentObject var state: AppState
    @State private var showDone = false
    @State private var editing: Assignment?
    @State private var classifying = false
    @AppStorage("assignmentSort") private var sort = AssignmentSort.due.rawValue

    private var unsortedImports: Int { CanvasFeedImport.unclassified(state).count }

    private var sortMode: AssignmentSort { AssignmentSort(rawValue: sort) ?? .due }

    private var list: [Assignment] {
        let base = state.data.assignments.filter { showDone || $0.status != .done }
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

    private var anyRanked: Bool { state.data.assignments.contains { $0.urgency != nil && $0.status != .done } }

    var body: some View {
        NavigationStack {
            ModulePane(title: "Assignments") {
                HStack(spacing: 8) {
                    if unsortedImports > 0 {
                        Button { classifying = true } label: {
                            Label("\(unsortedImports)", systemImage: "tray.and.arrow.down")
                        }.help("Sort \(unsortedImports) imported Canvas items into courses")
                    }
                    Button { state.selectedModuleID = "board" } label: { Image(systemName: "rectangle.split.3x1") }
                        .help("Board view — same assignments")
                    if anyRanked {
                        Menu {
                            ForEach(AssignmentSort.allCases) { s in
                                Button { sort = s.rawValue } label: {
                                    Label(s.rawValue, systemImage: sortMode == s ? "checkmark" : "arrow.up.arrow.down")
                                }
                            }
                        } label: { Image(systemName: "arrow.up.arrow.down.circle") }
                        .help("Sort assignments")
                    }
                    Toggle("Done", isOn: $showDone).toggleStyle(.switch).controlSize(.mini)
                    Button { newAssignment() } label: { Image(systemName: "plus") }
                }
            } content: {
                if list.isEmpty {
                    EmptyState(symbol: "checklist", title: "No assignments",
                               subtitle: "Add homework, papers and exams with due dates.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: DS.Space.s) {
                            ForEach(list) { a in
                                AssignmentRow(assignment: a) { editing = a }
                            }
                        }.padding(DS.Space.m)
                    }
                }
            }
            .navigationDestination(item: $editing) { AssignmentEditor(assignment: $0) }
            .navigationDestination(isPresented: $classifying) { ClassifyView() }
            .onAppear(perform: consumePending)
            .onChange(of: state.pendingNew) { _, _ in consumePending() }
        }
    }

    private func consumePending() {
        if state.pendingNew == "assignments" { state.pendingNew = nil; newAssignment() }
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
            }
            Button { onEdit() } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
        }
        .padding(DS.Space.m)
        .background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }

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

    private func toggleDone() {
        guard let i = state.data.assignments.firstIndex(where: { $0.id == assignment.id }) else { return }
        let nowDone = state.data.assignments[i].status != .done
        state.data.assignments[i].status = nowDone ? .done : .todo
        // (12) Recurring: on completion, spawn next week's copy.
        if nowDone, state.data.assignments[i].recurring, let due = state.data.assignments[i].due {
            var next = state.data.assignments[i]
            next.id = UUID()
            next.status = .todo
            next.due = Calendar.current.date(byAdding: .day, value: 7, to: due)
            next.checklist = next.checklist.map { var c = $0; c.done = false; return c }
            state.data.assignments.append(next)
        }
    }

    private func open(_ s: String) {
        guard let url = URL(string: s.contains("://") ? s : "https://\(s)") else { return }
        NSWorkspace.shared.open(url)
    }
}
