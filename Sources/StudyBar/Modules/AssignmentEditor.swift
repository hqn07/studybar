import SwiftUI

struct AssignmentEditor: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let assignment: Assignment

    @State private var draft: Assignment
    @State private var hasDue: Bool
    @State private var newCheck = ""
    // Inline AI: propose checklist steps for this assignment; user picks which to add.
    @State private var stepsLoading = false
    @State private var stepsRaw = ""
    @State private var stepsProposed: [String]?
    @State private var stepsInclude: Set<Int> = []
    @State private var stepsTask: Task<Void, Never>?

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
            HStack {
                Text("Checklist").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if AIConfig.isReady {
                    Button { breakIntoSteps() } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "sparkles")
                            Text("Break into steps").font(.caption.weight(.medium))
                        }.foregroundStyle(.tint)
                    }.buttonStyle(.borderless).disabled(stepsLoading || draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Let AI propose a checklist for this assignment — you pick which steps to keep")
                }
            }
            if stepsLoading || stepsProposed != nil { stepsReviewCard }
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

    // MARK: Inline AI — propose a checklist (on-object, propose → accept)

    private var stepsReviewCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(.tint)
                Text(stepsLoading ? "Planning steps" : "Proposed steps — pick which to add")
                    .font(.caption.weight(.semibold))
                if stepsLoading { ProgressView().controlSize(.small) }
                Spacer()
                Text(AIConfig.mode.title).font(.caption2).foregroundStyle(.secondary)
                if !stepsLoading {
                    Button { cancelSteps() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            if stepsLoading {
                Text(stepsRaw.isEmpty ? "Thinking…" : stepsRaw)
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let steps = stepsProposed {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    Button { toggleStep(i) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: stepsInclude.contains(i) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(stepsInclude.contains(i) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            Text(step).font(.callout).foregroundStyle(.primary)
                            Spacer()
                        }
                    }.buttonStyle(.plain)
                }
                HStack {
                    Button { addSteps() } label: {
                        Label("Add \(stepsInclude.count) step\(stepsInclude.count == 1 ? "" : "s")", systemImage: "plus.circle")
                    }.buttonStyle(.borderedProminent).controlSize(.small).disabled(stepsInclude.isEmpty)
                    Spacer()
                    Button("Discard") { cancelSteps() }.buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(.tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.tint.opacity(0.25)))
    }

    private func toggleStep(_ i: Int) {
        if stepsInclude.contains(i) { stepsInclude.remove(i) } else { stepsInclude.insert(i) }
    }

    private func breakIntoSteps() {
        guard AIConfig.isReady, let provider = AIService.makeProvider() else { return }
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        stepsLoading = true; stepsRaw = ""; stepsProposed = nil; stepsInclude = []
        let due = draft.due.map { " Due \($0.formatted(date: .abbreviated, time: .omitted))." } ?? ""
        let ctx = "Assignment: \(title).\(due)" + (draft.notes.isEmpty ? "" : " Notes: \(draft.notes)")
        let sys = "You are a study planner. Break the assignment into 3–7 concrete, actionable steps a student can check off, in the order they should be done. One step per line — imperative and short, and end each step with a rough time estimate in parentheses, e.g. \"Draft the introduction (~30 min)\". No numbering, no bullets, no preamble, no other text."
        stepsTask?.cancel()
        stepsTask = Task {
            let msgs = [AIMessage(role: .user, text: ctx)]
            let out: String?
            if let ollama = provider as? OllamaProvider {
                out = try? await ollama.completePlainStreaming(system: sys, messages: msgs) { p in stepsRaw = p }
            } else {
                out = try? await provider.completePlain(system: sys, messages: msgs)
            }
            await MainActor.run {
                stepsLoading = false
                let steps = parseSteps(out ?? stepsRaw)
                stepsProposed = steps.isEmpty ? nil : steps
                stepsInclude = Set(steps.indices)
            }
        }
    }

    /// One step per line; strip any numbering/bullets the model added anyway.
    private func parseSteps(_ s: String) -> [String] {
        let lines = s.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let t = line.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"^\s*(\d+[.)]|[-•*])\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
        return Array(lines.prefix(10))
    }

    private func addSteps() {
        guard let steps = stepsProposed else { return }
        let chosen = steps.enumerated()
            .filter { stepsInclude.contains($0.offset) }
            .map { ChecklistItem(text: $0.element) }
        draft.checklist.append(contentsOf: chosen)
        cancelSteps()
    }

    private func cancelSteps() {
        stepsTask?.cancel(); stepsTask = nil
        stepsLoading = false; stepsProposed = nil; stepsRaw = ""; stepsInclude = []
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
