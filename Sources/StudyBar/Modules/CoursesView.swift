import SwiftUI

struct CoursesView: View {
    @EnvironmentObject var state: AppState
    @State private var editing: Course?
    @State private var detailID: UUID?

    var body: some View {
        NavigationStack {
            ModulePane(title: "Courses") {
                Button { editing = Course(name: "") } label: {
                    Image(systemName: "plus")
                }
            } content: {
                if state.data.courses.isEmpty {
                    EmptyState(symbol: "graduationcap", title: "No courses",
                               subtitle: "Add your classes — assignments, notes and links attach to them.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(state.data.courses) { c in
                                CourseRow(course: c, onOpen: { detailID = c.id }, onEdit: { editing = c })
                            }
                        }.padding(10)
                    }
                }
            }
            .navigationDestination(item: $editing) { CourseEditor(course: $0) }
            .navigationDestination(item: $detailID) { CourseDetailView(courseID: $0) }
        }
    }
}

struct CourseRow: View {
    @EnvironmentObject var state: AppState
    let course: Course
    let onOpen: () -> Void
    let onEdit: () -> Void

    private var counts: (Int, Int) {
        (state.data.assignments.filter { $0.courseID == course.id && $0.status != .done }.count,
         state.data.notes.filter { $0.courseID == course.id }.count)
    }

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3).fill(course.color).frame(width: 5, height: 34)
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(course.name.isEmpty ? "Untitled" : course.name).fontWeight(.medium)
                        HStack(spacing: 6) {
                            if !course.code.isEmpty { Text(course.code) }
                            if !course.instructor.isEmpty { Text("· \(course.instructor)") }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !course.grade.isEmpty {
                        Text(course.grade).font(.caption.bold())
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(course.color.opacity(0.2), in: Capsule()).foregroundStyle(course.color)
                    }
                    let (a, n) = counts
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(a) due · \(n) notes").font(.caption2).foregroundStyle(.secondary)
                        Text("\(course.credits, specifier: "%g") cr").font(.caption2).foregroundStyle(.tertiary)
                    }
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button(action: onEdit) { Image(systemName: "pencil") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct CourseDetailView: View {
    @EnvironmentObject var state: AppState
    let courseID: UUID
    @State private var editing: Course?
    @State private var editingAssignment: Assignment?

    private var course: Course? { state.data.courses.first { $0.id == courseID } }
    private var assignments: [Assignment] {
        state.data.assignments.filter { $0.courseID == courseID && $0.status != .done }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }
    private var classes: [ClassSession] {
        state.data.classes.filter { $0.courseID == courseID }.sorted { $0.weekday < $1.weekday || ($0.weekday == $1.weekday && $0.startMinutes < $1.startMinutes) }
    }
    private var links: [QuickLink] { state.data.links.filter { $0.courseID == courseID } }
    private var notes: [Note] { state.data.notes.filter { $0.courseID == courseID } }
    private var reading: [ReadingItem] { state.data.reading.filter { $0.courseID == courseID } }

    var body: some View {
        VStack(spacing: 0) {
            SubHeader(course?.name ?? "Course") {
                if let c = course { Button { editing = c } label: { Image(systemName: "pencil") }.buttonStyle(.borderless) }
            }
            Divider()
            if let c = course {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        headerCard(c)
                        if !assignments.isEmpty {
                            section("OPEN ASSIGNMENTS (\(assignments.count))") {
                                ForEach(assignments) { a in assignmentRow(a) }
                            }
                        }
                        if !classes.isEmpty {
                            section("CLASSES") { ForEach(classes) { cl in classRow(cl) } }
                        }
                        if !links.isEmpty {
                            section("LINKS") { ForEach(links) { l in linkRow(l) } }
                        }
                        if !reading.isEmpty {
                            section("READING") { ForEach(reading) { r in readingRow(r) } }
                        }
                        if !notes.isEmpty {
                            section("NOTES (\(notes.count))") {
                                ForEach(notes.prefix(5)) { n in
                                    Text(n.title.isEmpty ? "Untitled" : n.title).font(.callout)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(9).background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                                }
                                Button("Open in Notes") { state.selectedModuleID = "notes" }.font(.caption).buttonStyle(.borderless)
                            }
                        }
                    }.padding(14)
                }
            } else {
                EmptyState(symbol: "graduationcap", title: "Course removed", subtitle: "")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("").toolbar(.hidden, for: .windowToolbar)
        .navigationDestination(item: $editing) { CourseEditor(course: $0) }
        .navigationDestination(item: $editingAssignment) { AssignmentEditor(assignment: $0) }
    }

    private func headerCard(_ c: Course) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 4).fill(c.color).frame(width: 6, height: 54)
            VStack(alignment: .leading, spacing: 3) {
                Text([c.code, c.instructor].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    if !c.room.isEmpty { Label(c.room, systemImage: "mappin.and.ellipse").font(.caption) }
                    Label("\(c.credits, specifier: "%g") cr", systemImage: "number").font(.caption)
                }.foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("None") { setGrade("") }
                Divider()
                ForEach(GradeScale.letters, id: \.self) { g in Button(g) { setGrade(g) } }
            } label: {
                VStack(spacing: 0) {
                    Text(c.grade.isEmpty ? "—" : c.grade).font(.title2.bold()).foregroundStyle(c.color)
                    Text("grade").font(.caption2).foregroundStyle(.secondary)
                }
            }.menuStyle(.borderlessButton).fixedSize()
        }
        .padding(12).background(c.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    private func assignmentRow(_ a: Assignment) -> some View {
        HStack(spacing: 8) {
            Button { toggleDone(a) } label: { Image(systemName: "circle").foregroundStyle(.secondary) }.buttonStyle(.plain)
            Button { editingAssignment = a } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(a.title.isEmpty ? "Untitled" : a.title).fontWeight(.medium)
                    if let d = a.due { Text(a.isOverdue ? "Overdue · \(d.dayMonth)" : "Due \(d.dayMonth)").font(.caption2).foregroundStyle(a.isOverdue ? .red : .secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(9).background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }
    private func classRow(_ cl: ClassSession) -> some View {
        HStack {
            Text(weekdaySymbols[cl.weekday]).font(.caption.bold()).frame(width: 34, alignment: .leading)
            Text("\(cl.startString) – \(cl.endString)").font(.caption)
            if !cl.room.isEmpty { Text("· \(cl.room)").font(.caption2).foregroundStyle(.secondary) }
            Spacer()
        }.padding(9).background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }
    private func linkRow(_ l: QuickLink) -> some View {
        Button { openURL(l.url) } label: {
            HStack { Image(systemName: l.symbol.isEmpty ? "link" : l.symbol).foregroundStyle(.tint)
                Text(l.title.isEmpty ? l.url : l.title); Spacer(); Image(systemName: "arrow.up.right.square").font(.caption) }
                .padding(9).background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }
    private func readingRow(_ r: ReadingItem) -> some View {
        HStack(spacing: 8) {
            Text(r.title).fontWeight(.medium).lineLimit(1)
            Spacer()
            Text("\(Int(r.progress * 100))%").font(.caption2).foregroundStyle(.secondary)
        }.padding(9).background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption2.bold()).foregroundStyle(.secondary)
            c()
        }
    }
    private func setGrade(_ g: String) {
        guard let i = state.data.courses.firstIndex(where: { $0.id == courseID }) else { return }
        state.data.courses[i].grade = g
    }
    private func toggleDone(_ a: Assignment) {
        guard let i = state.data.assignments.firstIndex(where: { $0.id == a.id }) else { return }
        state.data.assignments[i].status = .done
    }
    private func openURL(_ s: String) {
        let u = s.contains("://") ? s : "https://\(s)"
        if let url = URL(string: u) { NSWorkspace.shared.open(url) }
    }
}

struct CourseEditor: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Course
    init(course: Course) { _draft = State(initialValue: course) }

    var body: some View {
        VStack(spacing: 0) {
            SubHeader("Course") {
                Button("Delete", role: .destructive) { delete() }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                TextField("Name", text: $draft.name).textFieldStyle(.roundedBorder)
                HStack {
                    TextField("Code", text: $draft.code).textFieldStyle(.roundedBorder)
                    TextField("Room", text: $draft.room).textFieldStyle(.roundedBorder)
                }
                TextField("Instructor", text: $draft.instructor).textFieldStyle(.roundedBorder)
                HStack {
                    Text("Credits").font(.caption).foregroundStyle(.secondary)
                    Stepper(value: $draft.credits, in: 0...12, step: 0.5) {
                        Text("\(draft.credits, specifier: "%g")")
                    }.fixedSize()
                    Spacer()
                    Text("Grade").font(.caption).foregroundStyle(.secondary)
                    Menu {
                        Button("None") { draft.grade = "" }
                        Divider()
                        ForEach(GradeScale.letters, id: \.self) { g in Button(g) { draft.grade = g } }
                    } label: { Text(draft.grade.isEmpty ? "—" : draft.grade).frame(minWidth: 30) }.fixedSize()
                }
                Text("Color").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 7), spacing: 8) {
                    ForEach(Palette.swatches, id: \.self) { hex in
                        Button { draft.colorHex = hex } label: {
                            Circle().fill(Color(hex: hex) ?? .gray)
                                .frame(width: 24, height: 24)
                                .overlay(Circle().stroke(.primary, lineWidth: draft.colorHex == hex ? 2 : 0))
                        }.buttonStyle(.plain)
                    }
                }
            }.padding(14)
            Divider()
            HStack { Spacer(); Button("Cancel") { dismiss() }
                Button("Save") { save() }.keyboardShortcut(.defaultAction) }.padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("")
        .toolbar(.hidden, for: .windowToolbar)
    }

    private func save() {
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty {
            state.data.courses.removeAll { $0.id == draft.id }
        } else if let i = state.data.courses.firstIndex(where: { $0.id == draft.id }) {
            state.data.courses[i] = draft
        } else {
            state.data.courses.append(draft)
        }
        dismiss()
    }
    private func delete() {
        state.data.courses.removeAll { $0.id == draft.id }
        // Detach references
        for i in state.data.assignments.indices where state.data.assignments[i].courseID == draft.id {
            state.data.assignments[i].courseID = nil
        }
        for i in state.data.notes.indices where state.data.notes[i].courseID == draft.id {
            state.data.notes[i].courseID = nil
        }
        dismiss()
    }
}
