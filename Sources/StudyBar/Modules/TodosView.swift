import SwiftUI

enum TodoSort: String, CaseIterable, Identifiable {
    case smart = "Priority & due", due = "Due date", created = "Newest"
    var id: String { rawValue }
}

struct TodosView: View {
    @EnvironmentObject var state: AppState
    @State private var newText = ""
    @State private var hideDone = true
    @State private var sort = TodoSort.smart
    @State private var editing: TodoItem?
    @FocusState private var addFocused: Bool

    private var items: [TodoItem] {
        var list = state.data.todos.filter { !hideDone || !$0.done }
        switch sort {
        case .smart:
            list.sort { a, b in
                if a.done != b.done { return !a.done }
                if a.priority != b.priority { return a.priority > b.priority }
                return (a.due ?? .distantFuture) < (b.due ?? .distantFuture)
            }
        case .due:
            list.sort { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
        case .created:
            list.sort { $0.createdAt > $1.createdAt }
        }
        return list
    }

    var body: some View {
        NavigationStack {
            ModulePane(title: "To-Do") {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(TodoSort.allCases) { s in
                            Button { sort = s } label: { Label(s.rawValue, systemImage: sort == s ? "checkmark" : "arrow.up.arrow.down") }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    Toggle("Hide done", isOn: $hideDone).toggleStyle(.switch).controlSize(.mini)
                }
            } content: {
                VStack(spacing: 0) {
                    HStack {
                        TextField("Add a task…", text: $newText, onCommit: add)
                            .textFieldStyle(.roundedBorder).focused($addFocused)
                        Button("Add", action: add).disabled(newText.isEmpty)
                    }.padding(10)
                    .onAppear { if state.pendingNew == "todos" { state.pendingNew = nil; addFocused = true } }
                    .onChange(of: state.pendingNew) { _, v in if v == "todos" { state.pendingNew = nil; addFocused = true } }
                    Divider()
                    if items.isEmpty {
                        EmptyState(symbol: "checkmark.circle", title: "All clear", subtitle: "No tasks. Add one above.")
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 4) {
                                ForEach(items) { item in TodoRow(item: item) { editing = item } }
                            }.padding(10)
                        }
                    }
                }
            }
            .navigationDestination(item: $editing) { TodoEditor(item: $0) }
        }
    }

    private func add() {
        let t = newText.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        state.data.todos.append(TodoItem(text: t))
        newText = ""
    }
}

struct TodoRow: View {
    @EnvironmentObject var state: AppState
    let item: TodoItem
    let onEdit: () -> Void
    private let colors: [Color] = [.secondary, .blue, .dsNow]

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Button { toggle() } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.done ? AnyShapeStyle(Color.dsDone) : AnyShapeStyle(.secondary))
            }.buttonStyle(.plain)
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.text).strikethrough(item.done).foregroundStyle(item.done ? .secondary : .primary)
                    HStack(spacing: DS.Space.s) {
                        CourseChip(course: state.course(item.courseID))
                        if let due = item.due {
                            Text(dueLabel(due)).font(.caption2)
                                .foregroundStyle(item.isOverdue ? Color.dsNow : Color.secondary)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button { cyclePriority() } label: {
                Circle().fill(colors[item.priority]).frame(width: 8, height: 8)
            }.buttonStyle(.plain).help("Priority")
            Button { state.withUndo("Deleted task") { state.data.todos.removeAll { $0.id == item.id } } } label: {
                Image(systemName: "xmark")
            }.buttonStyle(.borderless).foregroundStyle(.secondary).font(.caption)
        }
        .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
        .background(Color.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }

    private func dueLabel(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return "Today" }
        if Calendar.current.isDateInTomorrow(d) { return "Tomorrow" }
        return d.dayMonth
    }
    private func toggle() {
        guard let i = state.data.todos.firstIndex(where: { $0.id == item.id }) else { return }
        state.data.todos[i].done.toggle()
    }
    private func cyclePriority() {
        guard let i = state.data.todos.firstIndex(where: { $0.id == item.id }) else { return }
        state.data.todos[i].priority = (state.data.todos[i].priority + 1) % 3
    }
}

struct TodoEditor: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var draft: TodoItem
    @State private var hasDue: Bool
    init(item: TodoItem) {
        _draft = State(initialValue: item)
        _hasDue = State(initialValue: item.due != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            SubHeader("Task") {
                Button("Delete", role: .destructive) { state.withUndo("Deleted task") { state.data.todos.removeAll { $0.id == draft.id } }; dismiss() }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                TextField("Task", text: $draft.text).textFieldStyle(.roundedBorder)
                HStack {
                    Text("Priority").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $draft.priority) {
                        Text("Low").tag(0); Text("Normal").tag(1); Text("High").tag(2)
                    }.pickerStyle(.segmented).labelsHidden()
                }
                HStack {
                    Text("Course").font(.caption).foregroundStyle(.secondary)
                    CoursePicker(courseID: $draft.courseID)
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Due date", isOn: $hasDue).toggleStyle(.switch)
                    if hasDue {
                        DatePicker("Due", selection: Binding(get: { draft.due ?? .now }, set: { draft.due = $0 }),
                                   displayedComponents: .date)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notes").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $draft.notes).frame(height: 60).font(.callout)
                        .scrollContentBackground(.hidden)
                        .background(Color.sbSurface, in: RoundedRectangle(cornerRadius: 6))
                }
            }.padding(14)
            Divider()
            HStack { Spacer(); Button("Cancel") { dismiss() }
                Button("Save") { save() }.keyboardShortcut(.defaultAction) }.padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("").toolbar(.hidden, for: .windowToolbar)
    }

    private func save() {
        if !hasDue { draft.due = nil }
        if draft.text.trimmingCharacters(in: .whitespaces).isEmpty {
            state.data.todos.removeAll { $0.id == draft.id }
        } else if let i = state.data.todos.firstIndex(where: { $0.id == draft.id }) {
            state.data.todos[i] = draft
        }
        dismiss()
    }
}
