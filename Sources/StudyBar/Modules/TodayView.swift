import SwiftUI

/// Today — a proactive glance. The hero is the single item that most deserves a head
/// start (ranked by `TodayFocus`, with an AI-written line when an engine is configured),
/// followed by an overdue flag, a week-load strip, today's classes, and the next 7 days.
/// Vanity counters (studied / pomodoros / open tasks) live in Insights now.
struct TodayView: View {
    @EnvironmentObject var state: AppState
    @State private var quickTask = ""
    @State private var aiLine: String?
    @State private var aiForID: UUID?

    // MARK: derived

    private var streak: Int { StudyStats.currentStreak(state.data) }
    private var todayWeekday: Int { Calendar.current.component(.weekday, from: .now) }
    private var nowMinutes: Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: .now)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private var focus: Assignment? { TodayFocus.top(state.data) }
    private var overdue: [Assignment] {
        state.data.assignments.filter { $0.status != .done && $0.isOverdue }
            .sorted { ($0.due ?? .distantPast) < ($1.due ?? .distantPast) }
    }
    private var todayClasses: [ClassSession] {
        state.data.classes.filter { $0.meets(on: todayWeekday) }.sorted { $0.startMinutes < $1.startMinutes }
    }
    private var nextClass: ClassSession? { todayClasses.first { $0.endMinutes >= nowMinutes } }
    private func inSession(_ c: ClassSession) -> Bool { c.startMinutes <= nowMinutes && c.endMinutes >= nowMinutes }

    private var next7: [Assignment] {
        state.data.assignments
            .filter { $0.status != .done }
            .filter { if let d = $0.daysUntilDue { return d >= 0 && d <= 7 } else { return false } }
            .filter { $0.id != focus?.id }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }

    // MARK: body

    var body: some View {
        ModulePane(title: greeting) { streakChip } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    heroCard
                    if !overdue.isEmpty { overdueBanner }
                    weekStrip
                    quickAddBlock
                    if !todayClasses.isEmpty {
                        section("Today", todayClasses.count, "clock") {
                            ForEach(todayClasses) { classRow($0) }
                        }
                    }
                    if !next7.isEmpty {
                        section("Next 7 days", next7.count, "calendar") {
                            ForEach(next7) { assignmentRow($0) }
                        }
                    }
                }.padding(DS.Space.l)
            }
        }
        .task(id: focus?.id) { await refreshAILine() }
    }

    /// Fetch the AI hero line for the current focus item (falls back silently to `reason`).
    private func refreshAILine() async {
        aiLine = nil
        guard let a = focus else { aiForID = nil; return }
        aiForID = a.id
        if let line = await TodayFocus.aiLine(for: a, data: state.data), aiForID == a.id {
            withAnimation(.easeOut(duration: 0.25)) { aiLine = line }
        }
    }

    // MARK: - Hero

    @ViewBuilder private var heroCard: some View {
        if let a = focus { focusHero(a) }
        else if let c = nextClass { classHero(c) }
        else { caughtUpHero }
    }

    /// The proactive hero — accent-tinted card, the top-ranked item, its reason (AI or
    /// heuristic), and two actions. The whole card isn't a button (it holds buttons); the
    /// title opens the assignment.
    private func focusHero(_ a: Assignment) -> some View {
        let days = a.daysUntilDue ?? 99
        let dueLabel = a.isOverdue ? "\(-days)d overdue" : (days == 0 ? "Due today" : days == 1 ? "Tomorrow" : (a.due?.dayMonth ?? ""))
        let dueStatus: Chip.Status = a.isOverdue ? .now : (days <= 3 ? .week : .neutral)
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            Label("One thing worth a head start", systemImage: "sparkles")
                .font(.caption2.weight(.bold)).textCase(.uppercase).foregroundStyle(.tint)
            Button { state.selectedModuleID = "assignments" } label: {
                Text(a.title.isEmpty ? "Untitled" : a.title)
                    .font(.title3.weight(.semibold)).lineLimit(2)
                    .foregroundStyle(.primary).multilineTextAlignment(.leading)
            }.buttonStyle(.plain)
            HStack(spacing: DS.Space.s) {
                CourseChip(course: state.course(a.courseID))
                if !dueLabel.isEmpty { Chip(dueLabel, .status(dueStatus)) }
            }
            Text(aiLine ?? TodayFocus.reason(a))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Space.m) {
                Button { AppActions.startFocus(label: a.title); state.selectedModuleID = "timefocus" } label: {
                    Label("Start focus", systemImage: "timer")
                }.buttonStyle(.borderedProminent).controlSize(.small)
                if AIConfig.isReady {
                    Button { AppActions.assistant(DailyPlan.prompt(state.data)) } label: {
                        Label("Plan my day", systemImage: "sparkles")
                    }.buttonStyle(.bordered).controlSize(.small)
                }
            }.padding(.top, DS.Space.xs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Space.l)
        .background(.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(.tint.opacity(0.25), lineWidth: 0.5))
    }

    private func classHero(_ c: ClassSession) -> some View {
        let course = state.course(c.courseID)
        let live = inSession(c)
        let until = c.startMinutes - nowMinutes
        return Button { state.selectedModuleID = "schedule" } label: {
            HStack(spacing: DS.Space.l) {
                RoundedRectangle(cornerRadius: 2).fill(course?.color ?? .accentColor).frame(width: 4)
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(live ? "IN CLASS NOW" : "NEXT CLASS").font(.caption2.weight(.bold)).tracking(0.6)
                        .foregroundStyle(live ? Color.dsNow : .accentColor)
                    Text(course?.name ?? (c.title.isEmpty ? "Class" : c.title)).font(.title3.weight(.semibold)).lineLimit(1)
                    HStack(spacing: DS.Space.s) {
                        Text("\(c.startString) – \(c.endString)").font(.caption).foregroundStyle(.secondary)
                        if !c.room.isEmpty { Text("· \(c.room)").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Spacer(minLength: DS.Space.s)
                if live { Chip("Now", .status(.now)) }
                else if until < 60 { Chip("in \(max(0, until))m", .status(.week)) }
                else { Chip(c.startString, .status(.neutral)) }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(DS.Space.l).frame(minHeight: 74)
            .background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        }.buttonStyle(.plain)
    }

    private var caughtUpHero: some View {
        HStack(spacing: DS.Space.l) {
            Image(systemName: "checkmark.seal.fill").font(.title2).foregroundStyle(Color.dsDone)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("All caught up").font(.callout.weight(.semibold))
                Text(streak > 0 ? "\(streak)-day streak going — start a focus session to keep it."
                                : "Nothing urgent on the horizon. Add a course or start a focus session.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DS.Space.s)
        }
        .padding(DS.Space.l).frame(maxWidth: .infinity, alignment: .leading)
        .background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }

    // MARK: - Overdue flag

    private var overdueBanner: some View {
        Button { state.selectedModuleID = "assignments" } label: {
            HStack(spacing: DS.Space.m) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.dsNow)
                Text("\(overdue.count) overdue").font(.callout.weight(.semibold))
                Text(overdue.prefix(2).map { $0.title.isEmpty ? "Untitled" : $0.title }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: DS.Space.s)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.m)
            .background(Color.dsNow.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(Color.dsNow.opacity(0.25), lineWidth: 0.5))
        }.buttonStyle(.plain)
    }

    // MARK: - Week-load strip

    private var weekStrip: some View {
        let load = TodayFocus.load(state.data, days: 7)
        let maxV = CGFloat(max(1, load.max() ?? 1))
        let cal = Calendar.current
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionHeader(title: "This week", systemImage: "chart.bar")
            HStack(alignment: .bottom, spacing: DS.Space.s) {
                ForEach(0..<7, id: \.self) { i in
                    let day = cal.date(byAdding: .day, value: i, to: cal.startOfDay(for: .now)) ?? .now
                    VStack(spacing: 4) {
                        Text(load[i] == 0 ? "·" : "\(load[i])")
                            .font(.caption2.monospacedDigit()).foregroundStyle(load[i] == 0 ? .tertiary : .secondary)
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 3).fill(.sbSurface2).frame(height: 40)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(i == 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.tint.opacity(0.45)))
                                .frame(height: load[i] == 0 ? 0 : max(5, CGFloat(load[i]) / maxV * 40))
                        }
                        Text(String(day.formatted(.dateTime.weekday(.narrow))))
                            .font(.caption2).foregroundStyle(i == 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    }.frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: - Rows

    private func classRow(_ c: ClassSession) -> some View {
        let course = state.course(c.courseID)
        let live = inSession(c)
        let isNext = c.id == nextClass?.id
        return Button { state.selectedModuleID = "schedule" } label: {
            HStack(spacing: DS.Space.m) {
                Text(c.startString).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .leading)
                Circle().fill(course?.color ?? .accentColor).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(course?.name ?? (c.title.isEmpty ? "Class" : c.title)).font(.callout.weight(.medium)).lineLimit(1)
                    if !c.room.isEmpty { Text(c.room).font(.caption2).foregroundStyle(.secondary) }
                }
                Spacer(minLength: DS.Space.s)
                if live { Chip("Now", .status(.now)) }
                else if isNext { Chip("Next", .status(.week)) }
            }
            .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.m)
            .background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        }.buttonStyle(.plain)
    }

    private func assignmentRow(_ a: Assignment) -> some View {
        let days = a.daysUntilDue ?? 99
        let label = days == 0 ? "Today" : days == 1 ? "Tomorrow" : (a.due?.dayMonth ?? "")
        let status: Chip.Status = days == 0 ? .now : (days <= 3 ? .week : .neutral)
        return Button { state.selectedModuleID = "assignments" } label: {
            HStack(spacing: DS.Space.m) {
                Circle().fill(state.course(a.courseID)?.color ?? Color.secondary).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(a.title.isEmpty ? "Untitled" : a.title).font(.callout.weight(.medium)).lineLimit(1)
                    CourseChip(course: state.course(a.courseID))
                }
                Spacer(minLength: DS.Space.s)
                if TodayFocus.weight(a.title) >= 0.9 { Chip("project", .tag) }
                if !label.isEmpty { Chip(label, .status(status)) }
            }
            .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.m + 1)
            .background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
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
            }
            if showParsePreview { parsePreview }
        }
    }

    private var parsePreview: some View {
        let p = parsedQuick
        return HStack(spacing: DS.Space.s) {
            Image(systemName: p.isAssignment ? "checklist" : "circle").font(.caption2).foregroundStyle(.secondary)
            Text(p.title.isEmpty ? "…" : p.title).font(.caption).lineLimit(1)
            if let c = state.course(p.courseID) { CourseChip(course: c) }
            if let due = p.due { Chip(due.dayMonth, .status(dueStatus(due))) }
            Spacer(minLength: DS.Space.s)
            Chip(p.isAssignment ? "Assignment" : "Task", .tag)
        }
        .padding(.horizontal, DS.Space.xs).transition(.opacity)
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
        var a = Assignment(title: p.title, courseID: p.courseID, due: p.due)
        a.urgency = p.priority >= 2 ? 2 : nil
        state.data.assignments.append(a)
        quickTask = ""
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
