import SwiftUI

let weekdaySymbols = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

struct ScheduleView: View {
    @EnvironmentObject var state: AppState
    @State private var editing: ClassSession?

    private var todayWeekday: Int { Calendar.current.component(.weekday, from: .now) }
    private var nowMinutes: Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: .now)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
    private func sessions(_ wd: Int) -> [ClassSession] {
        state.data.classes.filter { $0.weekday == wd }.sorted { $0.startMinutes < $1.startMinutes }
    }
    private var nextClass: ClassSession? {
        sessions(todayWeekday).first { $0.startMinutes >= nowMinutes }
    }

    var body: some View {
        NavigationStack {
            ModulePane(title: "Schedule") {
                Button { editing = ClassSession(weekday: todayWeekday) } label: {
                    Image(systemName: "plus")
                }
            } content: {
                if state.data.classes.isEmpty {
                    EmptyState(symbol: "calendar.badge.clock", title: "No classes",
                               subtitle: "Add your weekly class times, rooms and links.")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if let n = nextClass {
                                nextBanner(n)
                            }
                            ForEach(1...7, id: \.self) { wd in
                                let items = sessions(wd)
                                if !items.isEmpty {
                                    Text(fullDay(wd).uppercased() + (wd == todayWeekday ? " · TODAY" : ""))
                                        .font(.caption2.bold())
                                        .foregroundStyle(wd == todayWeekday ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                        .padding(.horizontal, 12)
                                    ForEach(items) { s in ClassRow(session: s) { editing = s } }
                                }
                            }
                        }.padding(.vertical, 10)
                    }
                }
            }
            .navigationDestination(item: $editing) { ClassEditor(session: $0) }
        }
    }

    private func nextBanner(_ s: ClassSession) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.badge").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Next: \(title(s))").fontWeight(.semibold)
                Text("\(s.startString) – \(s.endString)\(s.room.isEmpty ? "" : " · \(s.room)")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !s.link.isEmpty {
                Button { open(s.link) } label: { Image(systemName: "video") }.buttonStyle(.borderless)
            }
        }
        .padding(12).background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 10)
    }

    private func title(_ s: ClassSession) -> String {
        let c = state.course(s.courseID)?.name
        return [c, s.title.isEmpty ? nil : s.title].compactMap { $0 }.joined(separator: " · ").ifEmpty("Class")
    }
    private func fullDay(_ wd: Int) -> String {
        ["", "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][wd]
    }
    private func open(_ s: String) {
        let u = s.contains("://") ? s : "https://\(s)"
        if let url = URL(string: u) { NSWorkspace.shared.open(url) }
    }
}

private extension String { func ifEmpty(_ d: String) -> String { isEmpty ? d : self } }

struct ClassRow: View {
    @EnvironmentObject var state: AppState
    let session: ClassSession
    let onEdit: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(state.course(session.courseID)?.color ?? .accentColor)
                .frame(width: 4, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.course(session.courseID)?.name ?? (session.title.isEmpty ? "Class" : session.title))
                    .fontWeight(.medium)
                Text("\(session.startString) – \(session.endString)\(session.room.isEmpty ? "" : " · \(session.room)")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !session.link.isEmpty {
                Button { open(session.link) } label: { Image(systemName: "video") }
                    .buttonStyle(.borderless).font(.caption)
            }
            Button(action: onEdit) { Image(systemName: "pencil") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .padding(.horizontal, 10)
    }
    private func open(_ s: String) {
        let u = s.contains("://") ? s : "https://\(s)"
        if let url = URL(string: u) { NSWorkspace.shared.open(url) }
    }
}

struct ClassEditor: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ClassSession
    init(session: ClassSession) { _draft = State(initialValue: session) }

    var body: some View {
        VStack(spacing: 0) {
            SubHeader("Class") {
                Button("Delete", role: .destructive) { state.data.classes.removeAll { $0.id == draft.id }; dismiss() }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Course").font(.caption).foregroundStyle(.secondary)
                    CoursePicker(courseID: $draft.courseID)
                }
                TextField("Label (Lecture, Lab…)", text: $draft.title).textFieldStyle(.roundedBorder)
                Picker("Day", selection: $draft.weekday) {
                    ForEach(1...7, id: \.self) { Text(weekdaySymbols[$0]).tag($0) }
                }.pickerStyle(.segmented)
                HStack {
                    timePicker("Start", $draft.startMinutes)
                    timePicker("End", $draft.endMinutes)
                }
                TextField("Room", text: $draft.room).textFieldStyle(.roundedBorder)
                TextField("Meeting link (optional)", text: $draft.link).textFieldStyle(.roundedBorder)
            }.padding(14)
            Divider()
            HStack { Spacer(); Button("Cancel") { dismiss() }
                Button("Save") { save() }.keyboardShortcut(.defaultAction) }.padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("").toolbar(.hidden, for: .windowToolbar)
    }

    private func timePicker(_ label: String, _ binding: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            DatePicker("", selection: Binding(
                get: { Calendar.current.date(bySettingHour: binding.wrappedValue / 60,
                                             minute: binding.wrappedValue % 60, second: 0, of: .now) ?? .now },
                set: { d in
                    let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                    binding.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
                }), displayedComponents: .hourAndMinute).labelsHidden()
        }
    }
    private func save() {
        if let i = state.data.classes.firstIndex(where: { $0.id == draft.id }) {
            state.data.classes[i] = draft
        } else {
            state.data.classes.append(draft)
        }
        dismiss()
    }
}
