import SwiftUI
import EventKit

struct TodayView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var cal = CalendarService()
    @State private var quickTask = ""

    // MARK: derived

    private var upNext: [EKEvent] {
        cal.events.filter { $0.endDate >= .now && !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }.prefix(3).map { $0 }
    }
    private var streak: Int { StudyStats.currentStreak(state.data) }
    private var todayMin: Int { StudyStats.secondsToday(state.data) / 60 }
    private var week7Min: [Int] { StudyStats.last7Days(state.data).map(\.minutes) }
    private var openTasks: Int { state.data.assignments.filter { $0.status != .done }.count }

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
    private var currentlyReading: [ReadingItem] {
        state.data.reading.filter { $0.shelf == 1 }.sorted { $0.updatedAt > $1.updatedAt }.prefix(3).map { $0 }
    }

    private var todayWeekday: Int { Calendar.current.component(.weekday, from: .now) }
    private var nowMinutes: Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: .now)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
    private var nextClass: ClassSession? {
        state.data.classes
            .filter { $0.meets(on: todayWeekday) && $0.endMinutes >= nowMinutes }
            .sorted { $0.startMinutes < $1.startMinutes }.first
    }

    // MARK: hero resolution — the single "what do I do now"

    private func inSession(_ c: ClassSession) -> Bool { c.startMinutes <= nowMinutes && c.endMinutes >= nowMinutes }
    private var overdueFirst: Assignment? { dueToday.first(where: { $0.isOverdue }) }

    private enum Hero { case cls(ClassSession), assignment(Assignment), reading(ReadingItem), caughtUp }
    /// "What do I do now" — attention order, not just chronology.
    private var hero: Hero {
        if let c = nextClass, inSession(c) { return .cls(c) }   // you're literally in class
        if let a = overdueFirst { return .assignment(a) }        // overdue beats an upcoming class
        if let c = nextClass { return .cls(c) }
        if let a = dueToday.first { return .assignment(a) }
        if let a = dueSoon.first { return .assignment(a) }
        if let r = currentlyReading.first { return .reading(r) }
        return .caughtUp
    }
    private var heroAssignmentID: UUID? { if case .assignment(let a) = hero { return a.id }; return nil }
    private var heroReadingID: UUID? { if case .reading(let r) = hero { return r.id }; return nil }

    // MARK: body

    var body: some View {
        ModulePane(title: greeting) {
            streakChip
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    heroCard
                    statRow
                    quickAddBlock

                    let dueTodayList = dueToday.filter { $0.id != heroAssignmentID }
                    let dueSoonList = dueSoon.filter { $0.id != heroAssignmentID }
                    let readingList = currentlyReading.filter { $0.id != heroReadingID }

                    if !dueTodayList.isEmpty {
                        section("Due today", dueTodayList.count, "exclamationmark.circle") {
                            ForEach(dueTodayList) { assignmentRow($0, urgent: true) }
                        }
                    }
                    if !dueSoonList.isEmpty {
                        section("Next 3 days", dueSoonList.count, "calendar") {
                            ForEach(dueSoonList) { assignmentRow($0, urgent: false) }
                        }
                    }
                    if !upNext.isEmpty {
                        section("Up next", upNext.count, "clock") {
                            ForEach(Array(upNext.enumerated()), id: \.offset) { _, e in eventRow(e) }
                        }
                    }
                    if !readingList.isEmpty {
                        section("Currently reading", readingList.count, "book") {
                            ForEach(readingList) { readingRow($0) }
                        }
                    }
                }.padding(DS.Space.l)
            }
        }
        .onAppear { if cal.authorized { cal.load(days: 2) } }
    }

    // MARK: - Hero card

    @ViewBuilder private var heroCard: some View {
        switch hero {
        case .cls(let c):        classHero(c)
        case .assignment(let a): assignmentHero(a)
        case .reading(let r):    readingHero(r)
        case .caughtUp:          caughtUpHero
        }
    }

    /// Leading semantic stripe + card surface, whole thing tappable.
    private func heroFrame<C: View>(stripe: Color, jump: String, @ViewBuilder _ content: () -> C) -> some View {
        Button { state.selectedModuleID = jump } label: {
            HStack(spacing: DS.Space.l) {
                RoundedRectangle(cornerRadius: 2).fill(stripe).frame(width: 4)
                content()
                Spacer(minLength: DS.Space.s)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Space.l)
            .frame(minHeight: 74)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(stripe.opacity(0.25), lineWidth: 0.5))
        }.buttonStyle(.plain)
    }

    private func eyebrow(_ text: String, _ color: Color) -> some View {
        Text(text.uppercased()).font(.caption2.weight(.bold)).tracking(0.6).foregroundStyle(color)
    }

    private func classHero(_ c: ClassSession) -> some View {
        let course = state.course(c.courseID)
        let inSession = c.startMinutes <= nowMinutes && c.endMinutes >= nowMinutes
        let until = c.startMinutes - nowMinutes
        return heroFrame(stripe: course?.color ?? .accentColor, jump: "schedule") {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                eyebrow(inSession ? "In class now" : "Next class", inSession ? .dsNow : .accentColor)
                Text(course?.name ?? (c.title.isEmpty ? "Class" : c.title))
                    .font(.title3.weight(.semibold)).lineLimit(1)
                HStack(spacing: DS.Space.s) {
                    Text("\(c.startString) – \(c.endString)").font(.caption).foregroundStyle(.secondary)
                    if !c.room.isEmpty { Text("· \(c.room)").font(.caption).foregroundStyle(.secondary) }
                    if !c.link.isEmpty { Image(systemName: "video.fill").font(.caption2).foregroundStyle(.tint) }
                }
            }
            Spacer(minLength: DS.Space.s)
            if inSession { Chip("Now", .status(.now)) }
            else if until < 60 { Chip("in \(max(0, until))m", .status(.week)) }
            else { Chip(c.startString, .status(.neutral)) }
        }
    }

    private func assignmentHero(_ a: Assignment) -> some View {
        let urgent = (a.daysUntilDue ?? 99) <= 0
        let label = a.isOverdue ? "Overdue" : (a.daysUntilDue == 0 ? "Due today" : (a.due?.dayMonth ?? "Due soon"))
        return heroFrame(stripe: urgent ? .dsNow : .dsWeek, jump: "assignments") {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                eyebrow(a.isOverdue ? "Overdue" : "Next due", urgent ? .dsNow : .dsWeek)
                Text(a.title.isEmpty ? "Untitled" : a.title)
                    .font(.title3.weight(.semibold)).lineLimit(2)
                CourseChip(course: state.course(a.courseID))
            }
            Spacer(minLength: DS.Space.s)
            Chip(label, .status(urgent ? .now : .week))
        }
    }

    private func readingHero(_ r: ReadingItem) -> some View {
        heroFrame(stripe: .accentColor, jump: "reading") {
            CoverThumb(coverPath: r.coverPath, size: CGSize(width: 34, height: 48))
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                eyebrow("Pick up reading", .accentColor)
                Text(r.title).font(.callout.weight(.semibold)).lineLimit(1)
                ProgressView(value: r.progress).tint(.accentColor)
                Text(r.totalPages > 0 ? "\(r.currentPage)/\(r.totalPages) p" : "\(r.currentPage) p")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var caughtUpHero: some View {
        HStack(spacing: DS.Space.l) {
            Image(systemName: "checkmark.seal.fill").font(.title2).foregroundStyle(Color.dsDone)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("All caught up").font(.callout.weight(.semibold))
                Text(streak > 0 ? "\(streak)-day streak going — start a focus session to keep it."
                                : "Nothing urgent. Start a focus session or add a course to get going.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DS.Space.s)
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }

    // MARK: - Stat row

    private var statRow: some View {
        HStack(spacing: DS.Space.m) {
            statTile("\(todayMin)m", "studied today", "clock", "timefocus", spark: week7Min)
            statTile("\(StudyStats.pomodorosToday(state.data))", "pomodoros", "timer", "timefocus")
            statTile("\(openTasks)", "open tasks", "checklist", "assignments")
        }
    }

    private func statTile(_ v: String, _ l: String, _ icon: String, _ jump: String, spark: [Int]? = nil) -> some View {
        Button { state.selectedModuleID = jump } label: {
            VStack(spacing: DS.Space.xs) {
                Image(systemName: icon).font(.caption).foregroundStyle(.tint)
                Text(v).font(.title3.bold().monospacedDigit())
                Text(l).font(.caption2).foregroundStyle(.secondary)
                if let spark { Sparkline(values: spark).frame(height: 16).padding(.top, 1) }
            }
            .frame(maxWidth: .infinity).padding(.vertical, DS.Space.m)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        }.buttonStyle(.plain)
    }

    // MARK: - Quick add + Plan my day

    private var parsedQuick: QuickParse.Result { QuickParse.parse(quickTask, courses: state.data.courses) }
    private var showParsePreview: Bool {
        !quickTask.trimmingCharacters(in: .whitespaces).isEmpty
            && (parsedQuick.due != nil || parsedQuick.courseID != nil || parsedQuick.isAssignment)
    }

    private var quickAddBlock: some View {
        VStack(spacing: DS.Space.m) {
            HStack(spacing: DS.Space.m) {
                TextField("Quick add — “essay fri for chem”", text: $quickTask, onCommit: addTask)
                    .textFieldStyle(.roundedBorder)
                Button { addTask() } label: { Image(systemName: "plus.circle.fill") }
                    .buttonStyle(.borderless).disabled(quickTask.isEmpty)
                Button { state.pendingNew = "notes"; state.selectedModuleID = "notes" } label: {
                    Image(systemName: "note.text.badge.plus")
                }.buttonStyle(.borderless).help("New note")
                Button { state.selectedModuleID = "timefocus" } label: {
                    Image(systemName: "timer")
                }.buttonStyle(.borderless).help("Start a timer")
            }
            if showParsePreview { parsePreview }
            if AIConfig.isReady {
                Button {
                    AppActions.assistant(DailyPlan.prompt(state.data))
                } label: {
                    Label("Plan my day", systemImage: "sparkles").frame(maxWidth: .infinity)
                }.buttonStyle(.bordered).controlSize(.large).tint(.accentColor)
                .help("Plan my day with the assistant")
            }
        }
    }

    private var parsePreview: some View {
        let p = parsedQuick
        return HStack(spacing: DS.Space.s) {
            Image(systemName: p.isAssignment ? "checklist" : "circle")
                .font(.caption2).foregroundStyle(.secondary)
            Text(p.title.isEmpty ? "…" : p.title).font(.caption).lineLimit(1)
            if let c = state.course(p.courseID) { CourseChip(course: c) }
            if let due = p.due { Chip(due.dayMonth, .status(dueStatus(due))) }
            Spacer(minLength: DS.Space.s)
            Chip(p.isAssignment ? "Assignment" : "Task", .tag)
        }
        .padding(.horizontal, DS.Space.xs)
        .transition(.opacity)
    }

    private func dueStatus(_ due: Date) -> Chip.Status {
        let days = Calendar.current.dateComponents([.day],
            from: Calendar.current.startOfDay(for: .now),
            to: Calendar.current.startOfDay(for: due)).day ?? 99
        return days <= 0 ? .now : (days <= 3 ? .week : .neutral)
    }

    private func addTask() {
        let raw = quickTask.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        let p = QuickParse.parse(raw, courses: state.data.courses)
        if p.isAssignment {
            state.data.assignments.append(Assignment(title: p.title, courseID: p.courseID, due: p.due))
        } else {
            state.data.todos.append(TodoItem(text: p.title, priority: p.priority, courseID: p.courseID, due: p.due))
        }
        quickTask = ""
    }

    // MARK: - Rows

    private func assignmentRow(_ a: Assignment, urgent: Bool) -> some View {
        let label = a.isOverdue ? "Overdue" : (a.daysUntilDue == 0 ? "Today" : (a.due?.dayMonth ?? ""))
        return Button { state.selectedModuleID = "assignments" } label: {
            HStack(spacing: DS.Space.l) {
                Image(systemName: "circle").font(.system(size: 14))
                    .foregroundStyle(urgent ? Color.dsNow : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(a.title.isEmpty ? "Untitled" : a.title).font(.callout.weight(.medium)).lineLimit(1)
                    CourseChip(course: state.course(a.courseID))
                }
                Spacer(minLength: DS.Space.s)
                if !label.isEmpty { Chip(label, .status(urgent ? .now : .week)) }
            }
            .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.m + 1)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        }.buttonStyle(.plain)
    }

    private func eventRow(_ e: EKEvent) -> some View {
        Button { state.selectedModuleID = "calendar" } label: {
            HStack(spacing: DS.Space.l) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(e.calendar.cgColor.map { Color(cgColor: $0) } ?? .accentColor)
                    .frame(width: 4, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.title ?? "Event").font(.callout.weight(.medium)).lineLimit(1)
                    Text(e.startDate.formatted(date: .omitted, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: DS.Space.s)
                Image(systemName: "calendar").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.m + 1)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        }.buttonStyle(.plain)
    }

    private func readingRow(_ item: ReadingItem) -> some View {
        HStack(spacing: DS.Space.l) {
            CoverThumb(coverPath: item.coverPath, size: CGSize(width: 30, height: 42))
            Button { state.selectedModuleID = "reading" } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.callout.weight(.medium)).lineLimit(1)
                    ProgressView(value: item.progress).tint(.accentColor)
                    Text(item.totalPages > 0 ? "\(item.currentPage)/\(item.totalPages) p" : "\(item.currentPage) p")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }.buttonStyle(.plain)
            Spacer(minLength: DS.Space.s)
            Button { state.bumpReading(item.id, by: 1) } label: { Image(systemName: "plus") }.buttonStyle(.bordered)
            Button { state.bumpReading(item.id, by: 10) } label: { Text("+10").font(.caption) }.buttonStyle(.bordered)
        }
        .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.m)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }

    // MARK: - Pieces

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

    @ViewBuilder private func section<C: View>(_ title: String, _ count: Int, _ icon: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionHeader(title: title, count: count, systemImage: icon)
            c()
        }
    }
}

/// Minimal area+line sparkline for a stat tile. Emphasized endpoint = latest.
private struct Sparkline: View {
    let values: [Int]
    var body: some View {
        GeometryReader { geo in
            let maxV = CGFloat(max(1, values.max() ?? 1))
            let n = CGFloat(max(1, values.count - 1))
            let pts = values.enumerated().map { i, v in
                CGPoint(x: geo.size.width * CGFloat(i) / n,
                        y: geo.size.height * (1 - CGFloat(v) / maxV))
            }
            ZStack {
                Path { p in
                    guard let first = pts.first, let last = pts.last else { return }
                    p.move(to: CGPoint(x: first.x, y: geo.size.height))
                    for pt in pts { p.addLine(to: pt) }
                    p.addLine(to: CGPoint(x: last.x, y: geo.size.height))
                    p.closeSubpath()
                }.fill(.tint.opacity(0.15))
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: first); for pt in pts.dropFirst() { p.addLine(to: pt) }
                }.stroke(.tint, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                if let last = pts.last {
                    Circle().fill(.tint).frame(width: 4, height: 4).position(last)
                }
            }
        }
    }
}
