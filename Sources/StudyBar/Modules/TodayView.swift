import SwiftUI
import EventKit

struct TodayView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var cal = CalendarService()
    @State private var quickTask = ""

    private var upNext: [EKEvent] {
        cal.events.filter { $0.endDate >= .now && !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }.prefix(3).map { $0 }
    }

    private var streak: Int { StudyStats.currentStreak(state.data) }
    private var todayMin: Int { StudyStats.secondsToday(state.data) / 60 }

    private var dueToday: [Assignment] {
        state.data.assignments.filter {
            guard $0.status != .done, let d = $0.daysUntilDue else { return false }
            return d <= 0
        }.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }
    private var dueSoon: [Assignment] {
        state.data.assignments.filter {
            guard $0.status != .done, let d = $0.daysUntilDue else { return false }
            return d > 0 && d <= 3
        }.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }
    private var todayWeekday: Int { Calendar.current.component(.weekday, from: .now) }
    private var nowMinutes: Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: .now)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
    private var nextClass: ClassSession? {
        state.data.classes
            .filter { $0.weekday == todayWeekday && $0.endMinutes >= nowMinutes }
            .sorted { $0.startMinutes < $1.startMinutes }.first
    }

    var body: some View {
        ModulePane(title: greeting) {
            streakChip
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    statRow
                    quickAdd
                    if !upNext.isEmpty {
                        section("UP NEXT") { ForEach(Array(upNext.enumerated()), id: \.offset) { _, e in eventCard(e) } }
                    }
                    if !currentlyReading.isEmpty {
                        section("CURRENTLY READING") { ForEach(currentlyReading) { readingCard($0) } }
                    }
                    if let n = nextClass { section("NEXT CLASS") { classCard(n) } }
                    if !dueToday.isEmpty {
                        section("DUE TODAY") { ForEach(dueToday) { assignmentCard($0, urgent: true) } }
                    }
                    if !dueSoon.isEmpty {
                        section("NEXT 3 DAYS") { ForEach(dueSoon) { assignmentCard($0, urgent: false) } }
                    }
                    if dueToday.isEmpty && dueSoon.isEmpty && nextClass == nil {
                        Text("Nothing urgent. Add a course and assignment to get started, or start a focus session.")
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
                    }
                }.padding(12)
            }
        }
        .onAppear { if cal.authorized { cal.load(days: 2) } }
    }

    private var currentlyReading: [ReadingItem] {
        state.data.reading.filter { $0.shelf == 1 }.sorted { $0.updatedAt > $1.updatedAt }.prefix(3).map { $0 }
    }

    private func readingCard(_ item: ReadingItem) -> some View {
        HStack(spacing: 10) {
            CoverThumb(coverPath: item.coverPath, size: CGSize(width: 34, height: 48))
            Button { state.selectedModuleID = "reading" } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).fontWeight(.medium).lineLimit(1)
                    ProgressView(value: item.progress).tint(.accentColor)
                    Text(item.totalPages > 0 ? "\(item.currentPage)/\(item.totalPages) p" : "\(item.currentPage) p")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }.buttonStyle(.plain)
            Spacer()
            Button { state.bumpReading(item.id, by: 1) } label: { Image(systemName: "plus") }.buttonStyle(.bordered)
            Button { state.bumpReading(item.id, by: 10) } label: { Text("+10") }.buttonStyle(.bordered).font(.caption)
        }
        .padding(10).background(.background.secondary, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }

    private func eventCard(_ e: EKEvent) -> some View {
        Button { state.selectedModuleID = "calendar" } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3).fill(e.calendar.cgColor.map { Color(cgColor: $0) } ?? .accentColor)
                    .frame(width: 4, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.title ?? "Event").fontWeight(.medium).lineLimit(1)
                    Text(e.startDate.formatted(date: .omitted, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "calendar").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(10).background(.background.secondary, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        }.buttonStyle(.plain)
    }

    // MARK: pieces

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: .now)
        switch h { case 0..<12: return "Good morning"; case 12..<17: return "Good afternoon"; default: return "Good evening" }
    }

    private var streakChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "flame.fill").foregroundStyle(streak > 0 ? .orange : .secondary)
            Text("\(streak)").fontWeight(.bold)
            Text("day streak").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var statRow: some View {
        HStack(spacing: 10) {
            statTile("\(todayMin)m", "studied today", "clock", "timefocus")
            statTile("\(StudyStats.pomodorosToday(state.data))", "pomodoros", "timer", "timefocus")
            statTile("\(state.data.assignments.filter { $0.status != .done }.count)", "open tasks", "checklist", "assignments")
        }
    }

    private func statTile(_ v: String, _ l: String, _ icon: String, _ jump: String) -> some View {
        Button { state.selectedModuleID = jump } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).foregroundStyle(.tint)
                Text(v).font(.title3.bold().monospacedDigit())
                Text(l).font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).padding(.vertical, 10)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
    }

    private var quickAdd: some View {
        HStack(spacing: 8) {
            TextField("Quick add a task…", text: $quickTask, onCommit: addTask)
                .textFieldStyle(.roundedBorder)
            Button { addTask() } label: { Image(systemName: "plus.circle.fill") }
                .buttonStyle(.borderless).disabled(quickTask.isEmpty)
            Button { state.pendingNew = "notes"; state.selectedModuleID = "notes" } label: {
                Image(systemName: "note.text.badge.plus")
            }.buttonStyle(.borderless).help("New note")
            Button { state.selectedModuleID = "timefocus" } label: {
                Image(systemName: "timer")
            }.buttonStyle(.borderless).help("Start a timer")
            if AIConfig.isReady {
                Button {
                    AppActions.assistant("Look at my open assignments, due dates and classes, and give me a short prioritized plan for today. Propose tasks or study blocks I can add.")
                } label: {
                    Image(systemName: "sparkles")
                }.buttonStyle(.borderless).help("Plan my day with the assistant")
            }
        }
    }

    private func addTask() {
        let t = quickTask.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        state.data.todos.append(TodoItem(text: t))
        quickTask = ""
    }

    @ViewBuilder private func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption2.bold()).foregroundStyle(.secondary)
            c()
        }
    }

    private func classCard(_ s: ClassSession) -> some View {
        Button { state.selectedModuleID = "schedule" } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3).fill(state.course(s.courseID)?.color ?? .accentColor).frame(width: 4, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.course(s.courseID)?.name ?? (s.title.isEmpty ? "Class" : s.title)).fontWeight(.medium)
                    Text("\(s.startString) – \(s.endString)\(s.room.isEmpty ? "" : " · \(s.room)")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !s.link.isEmpty {
                    Image(systemName: "video").foregroundStyle(.tint)
                }
            }
            .padding(10).background(.background.secondary, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        }.buttonStyle(.plain)
    }

    private func assignmentCard(_ a: Assignment, urgent: Bool) -> some View {
        Button { state.selectedModuleID = "assignments" } label: {
            HStack(spacing: 10) {
                Image(systemName: "circle").foregroundStyle(urgent ? .orange : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(a.title.isEmpty ? "Untitled" : a.title).fontWeight(.medium)
                    HStack(spacing: 6) {
                        CourseChip(course: state.course(a.courseID))
                        if let d = a.due {
                            Text(a.isOverdue ? "Overdue" : d.dayMonth)
                                .font(.caption2).foregroundStyle(a.isOverdue ? .red : .secondary)
                        }
                    }
                }
                Spacer()
            }
            .padding(10).background(.background.secondary, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        }.buttonStyle(.plain)
    }
}
