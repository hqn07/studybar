import SwiftUI

enum AssignmentSort: String, CaseIterable, Identifiable {
    case due = "Due date", urgency = "Urgency"
    var id: String { rawValue }
}

struct AssignmentsView: View {
    @EnvironmentObject var state: AppState
    @State private var showDone = false
    @State private var editing: Assignment?
    @AppStorage("assignmentSort") private var sort = AssignmentSort.due.rawValue

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
                        LazyVStack(spacing: 6) {
                            ForEach(list) { a in
                                AssignmentRow(assignment: a) { editing = a }
                            }
                        }.padding(10)
                    }
                }
            }
            .navigationDestination(item: $editing) { AssignmentEditor(assignment: $0) }
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

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { toggleDone() } label: {
                Image(systemName: assignment.status == .done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(assignment.status == .done ? .green : .secondary)
                    .font(.title3)
            }.buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(assignment.title.isEmpty ? "Untitled" : assignment.title)
                    .fontWeight(.medium)
                    .strikethrough(assignment.status == .done)
                HStack(spacing: 8) {
                    if assignment.status != .done, let label = assignment.urgencyLabel {
                        urgencyPill(label, level: assignment.urgency ?? 0)
                    }
                    CourseChip(course: state.course(assignment.courseID))
                    if let due = assignment.due {
                        dueBadge(due)
                    }
                    if !assignment.checklist.isEmpty {
                        let done = assignment.checklist.filter(\.done).count
                        Text("\(done)/\(assignment.checklist.count)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if assignment.submitted && assignment.status != .done {
                        Label("Submitted", systemImage: "checkmark.seal.fill")
                            .labelStyle(.titleAndIcon).font(.caption2).foregroundStyle(.green)
                    }
                    if !assignment.link.isEmpty {
                        Button { open(assignment.link) } label: {
                            Image(systemName: "arrow.up.right.square")
                        }.buttonStyle(.borderless).font(.caption)
                    }
                }
            }
            Spacer()
            Button { onEdit() } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func urgencyPill(_ label: String, level: Int) -> some View {
        let color: Color = level >= 2 ? .red : (level == 1 ? .orange : .secondary)
        return Text(label.uppercased())
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    @ViewBuilder private func dueBadge(_ due: Date) -> some View {
        let days = assignment.daysUntilDue ?? 0
        let overdue = assignment.isOverdue
        let color: Color = overdue ? .red : (days <= 1 ? .orange : (days <= 3 ? .yellow : .secondary))
        Text(label(days: days, overdue: overdue, due: due))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
    }

    private func label(days: Int, overdue: Bool, due: Date) -> String {
        if overdue { return "Overdue · \(due.dayMonth)" }
        switch days {
        case 0: return "Due today"
        case 1: return "Due tomorrow"
        default: return "Due \(due.dayMonth) · \(days)d"
        }
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
