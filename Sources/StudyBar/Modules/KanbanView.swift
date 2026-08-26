import SwiftUI

struct KanbanView: View {
    @EnvironmentObject var state: AppState
    @State private var editing: Assignment?

    private let columns = AssignmentStatus.allCases

    private func items(_ s: AssignmentStatus) -> [Assignment] {
        state.data.assignments.filter { $0.status == s }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }

    var body: some View {
        NavigationStack {
            ModulePane(title: "Board") {
                HStack(spacing: 8) {
                    Button { state.selectedModuleID = "assignments" } label: { Image(systemName: "list.bullet") }
                        .help("List view — same assignments")
                    Text("\(state.data.assignments.count) tasks").font(.caption).foregroundStyle(.secondary)
                }
            } content: {
                if state.data.assignments.isEmpty {
                    EmptyState(symbol: "rectangle.split.3x1", title: "Board is empty",
                               subtitle: "Assignments appear here as cards. Drag them across columns, or tap ＋ in a column.")
                } else {
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(columns, id: \.self) { col in column(col) }
                        }.padding(10)
                    }
                }
            }
            .navigationDestination(item: $editing) { AssignmentEditor(assignment: $0) }
        }
    }

    private func column(_ status: AssignmentStatus) -> some View {
        DropColumn(status: status, count: items(status).count, add: { addCard(status) }) {
            ForEach(items(status)) { a in card(a) }
        } onDropIDs: { ids in moveIDs(ids, to: status) }
    }

    private func card(_ a: Assignment) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(a.title.isEmpty ? "Untitled" : a.title).fontWeight(.medium).lineLimit(2)
            if let u = a.urgency, u > 0, a.status != .done {
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
        .background(.background, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).stroke(.separator, lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture { editing = a }
        .draggable(a.id.uuidString)
    }

    private func addCard(_ status: AssignmentStatus) {
        var a = Assignment(title: "", due: nil)
        a.status = status
        state.data.assignments.append(a)
        editing = a
    }
    private func moveIDs(_ ids: [String], to status: AssignmentStatus) {
        for id in ids {
            guard let uuid = UUID(uuidString: id),
                  let i = state.data.assignments.firstIndex(where: { $0.id == uuid }) else { continue }
            state.data.assignments[i].status = status
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
                    .background(Color.sbSurface2, in: Capsule())
                Spacer()
                Button(action: add) { Image(systemName: "plus") }.buttonStyle(.borderless).font(.caption)
            }.padding(.horizontal, 4)
            ScrollView {
                VStack(spacing: 6) { content() }
            }
        }
        .frame(width: 210)
        .padding(8)
        .background(targeted ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(Color.sbSurface),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.tint, lineWidth: targeted ? 1.5 : 0))
        .dropDestination(for: String.self) { ids, _ in onDropIDs(ids); return true } isTargeted: { targeted = $0 }
    }
}
