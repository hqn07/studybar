import SwiftUI

struct KanbanView: View {
    @EnvironmentObject var state: AppState
    @State private var editing: Assignment?

    private let columns = AssignmentStatus.allCases

    /// A column's width: an even share of the board, never narrower than a readable card
    /// (below that the board scrolls sideways).
    static func columnWidth(available: CGFloat, count: Int, spacing: CGFloat) -> CGFloat {
        max(220, (available - spacing * CGFloat(count - 1)) / CGFloat(count))
    }

    private func items(_ s: AssignmentStatus) -> [Assignment] {
        // Archived work is out of play — it shouldn't sit in a column waiting to be dragged.
        state.data.assignments.filter { $0.status == s && !$0.isArchived }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }

    var body: some View {
        NavigationStack {
            ModulePane(title: "Board", controls: {
                Button("List") { state.selectedModuleID = "assignments" }
                    .help("List view — same assignments")
                Text("\(state.data.assignments.filter { !$0.isArchived }.count) tasks").font(.caption).foregroundStyle(.secondary)
            }) {
                if state.data.assignments.isEmpty {
                    EmptyState(symbol: "rectangle.split.3x1", title: "Board is empty",
                               subtitle: "Assignments appear here as cards. Drag them across columns, or tap ＋ in a column.")
                } else {
                    // The columns share the board's width; below three readable columns it scrolls sideways.
                    GeometryReader { g in
                        let width = Self.columnWidth(available: g.size.width - 2 * DS.Space.m, count: columns.count, spacing: DS.Space.m)
                        ScrollView(.horizontal, showsIndicators: true) {
                            HStack(alignment: .top, spacing: DS.Space.m) {
                                ForEach(columns, id: \.self) { col in column(col).frame(width: width) }
                            }.padding(DS.Space.m)
                        }
                    }
                }
            }
            .navigationDestination(item: $editing) { AssignmentEditor(assignment: $0) }
        }
    }

    private func column(_ status: AssignmentStatus) -> some View {
        let list = items(status)
        return DropColumn(status: status, count: list.count, add: { addCard(status) }) {
            ForEach(list) { a in card(a) }
        } onDropIDs: { ids in moveIDs(ids, to: status) }
    }

    private func card(_ a: Assignment) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(a.title.isEmpty ? "Untitled" : a.title).fontWeight(.medium).lineLimit(2)
            if let u = a.urgency, u > 0, a.isOpen {
                Chip(u >= 2 ? "Now" : "This week", .status(u >= 2 ? .now : .week))
            }
            HStack(spacing: DS.Space.s) {
                CourseChip(course: state.course(a.courseID))
                if let d = a.due {
                    Text(d.dayMonth).font(.caption2).foregroundStyle(a.isOverdue ? Color.dsNow : Color.secondary)
                }
            }
            if !a.checklist.isEmpty {
                let done = a.checklist.filter(\.done).count
                Text("\(done)/\(a.checklist.count) subtasks").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(DS.Space.s + 1).frame(maxWidth: .infinity, alignment: .leading)
        .background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).stroke(.separator, lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture { editing = a }
        .draggable(a.id.uuidString)
    }

    private func addCard(_ status: AssignmentStatus) {
        var a = Assignment(title: "", due: nil)
        a.status = status
        if status == .done { a.setDone(true) } else if a.completedAt != nil { a.setDone(false); a.status = status }
        state.data.assignments.append(a)
        editing = a
    }
    private func moveIDs(_ ids: [String], to status: AssignmentStatus) {
        for id in ids {
            guard let uuid = UUID(uuidString: id),
                  let i = state.data.assignments.firstIndex(where: { $0.id == uuid }) else { continue }
            state.data.assignments[i].status = status
            if status == .done { state.data.assignments[i].setDone(true) }
            else if state.data.assignments[i].completedAt != nil { state.data.assignments[i].setDone(false); state.data.assignments[i].status = status }
        }
    }
}

/// A board column that accepts dropped card IDs.
struct DropColumn<Content: View>: View {
    let status: AssignmentStatus
    let count: Int
    let add: () -> Void
    @ViewBuilder var content: () -> Content
    let onDropIDs: ([String]) -> Void
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(status.rawValue).font(.subheadline.bold())
                Text("\(count)").font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.sbSurface2, in: Capsule())
                Spacer()
                Button(action: add) { Image(systemName: "plus").accessibilityLabel("Add an assignment") }.buttonStyle(.borderless).font(.caption)
            }.padding(.horizontal, 4)
            ScrollView {
                LazyVStack(spacing: 6) { content() }   // a term's worth of cards: only the visible ones are built
            }
        }
        // No panel behind a column — the cards are the only boxes. A column shows itself only as
        // a drop target, its corners concentric with the cards' (a 10 four points inside a 14).
        .padding(DS.Space.xs)
        .background(targeted ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: DS.Radius.modal))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.modal).stroke(.tint, lineWidth: targeted ? 1.5 : 0))
        .contentShape(Rectangle())   // with no fill, the empty part of a column still takes a drop
        .dropDestination(for: String.self) { ids, _ in onDropIDs(ids); return true } isTargeted: { targeted = $0 }
    }
}
