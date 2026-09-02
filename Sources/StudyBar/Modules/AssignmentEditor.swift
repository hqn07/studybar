import SwiftUI

struct AssignmentEditor: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let assignment: Assignment

    @State private var draft: Assignment
    @State private var hasDue: Bool
    @State private var newCheck = ""

    init(assignment: Assignment) {
        self.assignment = assignment
        _draft = State(initialValue: assignment)
        _hasDue = State(initialValue: assignment.due != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            SubHeader("Assignment") {
                Button("Delete", role: .destructive) { delete() }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    field("Title") { TextField("e.g. Essay draft", text: $draft.title) }
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Course").font(.caption).foregroundStyle(.secondary)
                            CoursePicker(courseID: $draft.courseID)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Status").font(.caption).foregroundStyle(.secondary)
                            Picker("", selection: $draft.status) {
                                ForEach(AssignmentStatus.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }.labelsHidden().fixedSize()
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Has due date", isOn: $hasDue).toggleStyle(.switch)
                        if hasDue {
                            DatePicker("Due", selection: Binding(
                                get: { draft.due ?? .now },
                                set: { draft.due = $0 }
                            ), displayedComponents: [.date, .hourAndMinute])
                            Toggle("Repeats weekly", isOn: $draft.recurring)
                        }
                    }
                    field("Link") { TextField("https://…", text: $draft.link) }
                    checklistSection
                    field("Notes") {
                        TextEditor(text: $draft.notes).frame(height: 70)
                            .overlay(alignment: .topTrailing) { AITextMenu(text: $draft.notes, context: draft.title).padding(6) }
                            .font(.callout).scrollContentBackground(.hidden)
                            .background(.sbSurface, in: RoundedRectangle(cornerRadius: 6))
                    }
                }.padding(14)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }.padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("")
        .toolbar(.hidden, for: .windowToolbar)
    }

    private var checklistSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Checklist").font(.caption).foregroundStyle(.secondary)
            ForEach($draft.checklist) { $item in
                HStack {
                    Toggle("", isOn: $item.done).labelsHidden()
                    TextField("Step", text: $item.text)
                    Button { draft.checklist.removeAll { $0.id == item.id } } label: {
                        Image(systemName: "minus.circle")
                    }.buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            HStack {
                TextField("Add step…", text: $newCheck, onCommit: addCheck)
                Button("Add", action: addCheck).disabled(newCheck.isEmpty)
            }
        }
    }

    private func addCheck() {
        let t = newCheck.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        draft.checklist.append(ChecklistItem(text: t))
        newCheck = ""
    }

    @ViewBuilder private func field<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            c().textFieldStyle(.roundedBorder)
        }
    }

    private func save() {
        if !hasDue { draft.due = nil }
        guard !draft.title.trimmingCharacters(in: .whitespaces).isEmpty else {
            state.data.assignments.removeAll { $0.id == draft.id }   // discard blank
            dismiss(); return
        }
        if let i = state.data.assignments.firstIndex(where: { $0.id == draft.id }) {
            state.data.assignments[i] = draft
        } else {
            state.data.assignments.append(draft)
        }
        // Reminder 1 day before due.
        let key = draft.id.uuidString
        Notifier.cancel(id: key)
        if let due = draft.due, draft.status != .done {
            Notifier.schedule(id: key, title: "Due soon: \(draft.title)",
                              body: "Due \(due.dayMonth).",
                              at: Calendar.current.date(byAdding: .day, value: -1, to: due) ?? due,
                              assignmentID: draft.id)
        }
        dismiss()
    }

    private func delete() {
        state.withUndo("Deleted assignment") { state.data.assignments.removeAll { $0.id == draft.id } }
        Notifier.cancel(id: draft.id.uuidString)
        dismiss()
    }
}
