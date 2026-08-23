import SwiftUI

/// (Session history) Every logged focus / pomodoro / stopwatch block.
struct SessionsView: View {
    @EnvironmentObject var state: AppState
    @State private var renaming: TimeEntry?
    @State private var newLabel = ""

    private var grouped: [(Date, [TimeEntry])] {
        let dict = Dictionary(grouping: state.data.timeEntries) { Calendar.current.startOfDay(for: $0.date) }
        return dict.keys.sorted(by: >).map { ($0, dict[$0]!.sorted { $0.date > $1.date }) }
    }

    var body: some View {
        ModulePane(title: "Sessions") {
            Text(totalStr).font(.caption).foregroundStyle(.secondary)
        } content: {
            if state.data.timeEntries.isEmpty {
                EmptyState(symbol: "clock.arrow.circlepath", title: "No sessions yet",
                           subtitle: "Completed Pomodoro, Focus and Stopwatch sessions are logged here.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(grouped, id: \.0) { day, items in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(dayHeader(day)).font(.caption.bold())
                                        .foregroundStyle(Calendar.current.isDateInToday(day) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                    Spacer()
                                    Text(timeStr(items.reduce(0) { $0 + $1.seconds }))
                                        .font(.caption).foregroundStyle(.secondary)
                                }.padding(.horizontal, 12)
                                ForEach(items) { row($0) }
                            }
                        }
                    }.padding(.vertical, 10)
                }
            }
        }
        .overlay {
            if renaming != nil {
                ZStack {
                    Color.black.opacity(0.28).ignoresSafeArea().onTapGesture { renaming = nil }
                    VStack(spacing: 12) {
                        Text("Rename session").font(.headline)
                        TextField("Label", text: $newLabel).textFieldStyle(.roundedBorder)
                            .frame(width: 220).onSubmit { commitRename() }
                        HStack(spacing: 10) {
                            Button("Cancel") { renaming = nil }.keyboardShortcut(.cancelAction)
                            Button("Save") { commitRename() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding(20).frame(maxWidth: 280)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator)).shadow(radius: 20)
                }
            }
        }
    }

    private func row(_ e: TimeEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: kindIcon(e.kind)).frame(width: 18).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.label.isEmpty ? kindName(e.kind) : e.label).fontWeight(.medium).lineLimit(1)
                HStack(spacing: 6) {
                    CourseChip(course: state.course(e.courseID))
                    if let a = state.data.assignments.first(where: { $0.id == e.assignmentID }) {
                        Text("· \(a.title)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(e.date.formatted(date: .omitted, time: .shortened))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Text(timeStr(e.seconds)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Menu {
                Button("Rename") { renaming = e; newLabel = e.label }
                Button("Delete", role: .destructive) { state.data.timeEntries.removeAll { $0.id == e.id } }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
        }
        .padding(10).background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 10)
    }

    private func commitRename() {
        guard let e = renaming, let i = state.data.timeEntries.firstIndex(where: { $0.id == e.id }) else { return }
        state.data.timeEntries[i].label = newLabel
        renaming = nil
    }

    private var totalStr: String { timeStr(StudyStats.secondsThisWeek(state.data)) + " this week" }
    private func dayHeader(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return "TODAY" }
        if Calendar.current.isDateInYesterday(d) { return "YESTERDAY" }
        return d.formatted(.dateTime.weekday(.wide).month().day()).uppercased()
    }
    private func kindIcon(_ k: String) -> String {
        switch k { case "stopwatch": return "stopwatch"; case "focus": return "moon.stars"; default: return "timer" }
    }
    private func kindName(_ k: String) -> String {
        switch k { case "stopwatch": return "Stopwatch"; case "focus": return "Focus"; default: return "Pomodoro" }
    }
    private func timeStr(_ s: Int) -> String {
        let h = s / 3600, m = (s % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(s)s"
    }
}
