import SwiftUI
import Charts

struct InsightsView: View {
    @EnvironmentObject var state: AppState
    @AppStorage("weeklyStudyGoalMinutes") private var goalMinutes = 0

    private var week7: [(day: Date, minutes: Int)] { StudyStats.last7Days(state.data) }
    private var maxMin: Int { max(1, week7.map(\.minutes).max() ?? 1) }
    private var weekAvgMin: Int { week7.map(\.minutes).reduce(0, +) / max(1, week7.count) }
    private var byCourse: [(courseID: UUID?, seconds: Int)] { StudyStats.weekByCourse(state.data) }
    private var weekTotal: Int { StudyStats.secondsThisWeek(state.data) }

    // What the store can actually answer. Time entries only exist if the Pomodoro timer gets
    // used and reading stats only if books are tracked, so those sections are shown when there
    // is something in them rather than standing there empty implying you did nothing.
    private var done7: [(day: Date, count: Int)] { StudyStats.completionsLast7(state.data) }
    private var doneWeek: Int { StudyStats.completedThisWeek(state.data) }
    private var doneByCourse: [(courseID: UUID?, count: Int)] { StudyStats.completedThisWeekByCourse(state.data) }
    private var notesWeek: (notes: Int, words: Int) { StudyStats.notesThisWeek(state.data) }
    private var load: (overdue: Int, week: Int, open: Int) { StudyStats.workload(state.data) }
    /// Anything ever finished — including the work completed before completion times were
    /// recorded, which is most of it in a store upgraded from an earlier version.
    private var everCompleted: Bool { StudyStats.completedTotal(state.data) > 0 }
    private var undatedCompletions: Int { StudyStats.completedUndated(state.data) }
    private var hasDatedCompletions: Bool { !StudyStats.completionDays(state.data).isEmpty }
    private var tracksTime: Bool { !state.data.timeEntries.isEmpty }

    var body: some View {
        ModulePane(title: "Insights") {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    if AIConfig.isReady { weeklyReviewCard }
                    thisWeekCard
                    // Two columns once there's room for two charts side by side; one when narrow.
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 440), spacing: DS.Space.l, alignment: .top)],
                              alignment: .leading, spacing: DS.Space.xl) {
                        section("Work finished", nil, "checkmark.circle") { completionsChart }
                        if !doneByCourse.isEmpty {
                            section("Finished this week by course", doneByCourse.count, "checklist") { doneCourseBars }
                        }
                        section("What's ahead", nil, "tray.full") { workloadCard }
                        if tracksTime {
                            weeklyGoalCard
                            if !streakStats.allSatisfy(\.isEmpty) { glanceCard(GlanceRow(stats: streakStats)) }
                            section("Study time, last 7 days", nil, "chart.bar.fill") { barChart }
                            section("Time this week by course", byCourse.isEmpty ? nil : byCourse.count, "clock") { courseBars }
                        }
                        if !state.data.flashcards.isEmpty {
                            section("Flashcard retention", nil, "brain.head.profile") { retentionCard }
                        }
                        if !state.data.reading.isEmpty {
                            section("Reading", nil, "book") { readingCard }
                        }
                    }
                }.padding(DS.Space.l)
            }
        }
    }

    // MARK: - The week, in what the app actually knows

    private var thisWeekCard: some View {
        let total = StudyStats.completedTotal(state.data), streak = StudyStats.completionStreak(state.data)
        return glanceCard(GlanceRow(stats: [
            GlanceStat(value: "\(doneWeek)", label: "finished this week", isEmpty: doneWeek == 0),
            GlanceStat(value: "\(total)", label: "finished in total", isEmpty: total == 0),
            GlanceStat(value: "\(streak)", label: "day streak", isEmpty: streak == 0),
            GlanceStat(value: "\(notesWeek.notes)", label: notesWeek.notes == 1 ? "note written" : "notes written", isEmpty: notesWeek.notes == 0),
            GlanceStat(value: notesWeek.words >= 1000 ? String(format: "%.1fk", Double(notesWeek.words) / 1000) : "\(notesWeek.words)",
                       label: "words", isEmpty: notesWeek.words == 0),
        ], emptyText: "Nothing finished or written this week yet"))
    }

    /// A glance row on the card surface.
    private func glanceCard(_ row: GlanceRow) -> some View {
        row.padding(DS.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }

    /// Completions per day. Empty until something is checked off, so it says how to fill it
    /// rather than drawing a flat line and implying a week of nothing.
    @ViewBuilder private var completionsChart: some View {
        if everCompleted {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                if !hasDatedCompletions {
                    Label("\(undatedCompletions) finished before StudyBar started recording *when* — this fills in from your next one.",
                          systemImage: "clock.arrow.circlepath")
                        .font(.caption).foregroundStyle(.secondary)
                }
                chartBody
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Nothing checked off yet").font(.callout.weight(.medium))
                Text("Mark an assignment done and this fills in — Assignments ▸ This week is the short list.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open this week") { state.selectedModuleID = "assignments" }
                    .buttonStyle(.borderedProminent).controlSize(.small).padding(.top, 2)
            }
            .padding(DS.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        }
    }

    private var chartBody: some View {
        Group {
            Chart {
                ForEach(done7, id: \.day) { d in
                    BarMark(x: .value("Day", dayLabel(d.day)), y: .value("Finished", d.count))
                        .foregroundStyle(Calendar.current.isDateInToday(d.day)
                                         ? AnyShapeStyle(.tint) : AnyShapeStyle(.tint.opacity(0.45)))
                        .cornerRadius(3)
                }
            }
            .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
            .frame(height: 120)
        }
    }

    private var doneCourseBars: some View {
        let top = max(1, doneByCourse.map(\.count).max() ?? 1)
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            ForEach(doneByCourse, id: \.courseID) { row in
                HStack(spacing: DS.Space.m) {
                    if let c = state.course(row.courseID) {
                        Circle().fill(c.color).frame(width: 7, height: 7)
                        Text(c.code.isEmpty ? c.name : c.code).font(.caption)
                    } else {
                        Text("No course").font(.caption).foregroundStyle(.secondary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary).frame(height: 6)
                            Capsule().fill(.tint)
                                .frame(width: geo.size.width * CGFloat(row.count) / CGFloat(top), height: 6)
                        }.frame(maxHeight: .infinity, alignment: .center)
                    }.frame(height: 12)
                    Text("\(row.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var workloadCard: some View {
        glanceCard(GlanceRow(stats: [
            GlanceStat(value: "\(load.week)", label: "due in 7 days", isEmpty: load.week == 0),
            GlanceStat(value: "\(load.overdue)", label: "overdue", isEmpty: load.overdue == 0),
            GlanceStat(value: "\(load.open)", label: "open in total", isEmpty: load.open == 0),
        ], emptyText: "Nothing open — you're clear"))
    }

    // MARK: - Weekly review (AI habit hook)

    private var weeklyReviewCard: some View {
        Button { AppActions.assistant(WeeklyReview.prompt(state.data)) } label: {
            HStack(spacing: DS.Space.l) {
                Image(systemName: "sparkles").font(.title3).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Weekly review").font(.callout.weight(.semibold))
                    Text("Recap your week and get a plan for the next one")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: DS.Space.s)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(DS.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(.tint.opacity(0.25), lineWidth: 0.5))
        }.buttonStyle(.plain)
    }

    // MARK: - Weekly goal

    private var weeklyGoalCard: some View {
        let done = weekTotal / 60
        return HStack(spacing: DS.Space.l) {
            if goalMinutes > 0 {
                WeeklyGoalRing(doneMinutes: done, goalMinutes: goalMinutes, size: 54, line: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Weekly goal").font(.callout.weight(.semibold))
                    Text(done >= goalMinutes
                         ? "\(StudyGoal.label(done)) studied — goal reached 🎉"
                         : "\(StudyGoal.label(done)) of \(StudyGoal.label(goalMinutes)) · \(StudyGoal.label(goalMinutes - done)) to go")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: DS.Space.s)
                Menu { WeeklyGoalMenu(goalMinutes: $goalMinutes) } label: {
                    Image(systemName: "slider.horizontal.3")
                    .accessibilityLabel("Change your weekly goal")
                }.menuStyle(.borderlessButton).fixedSize().help("Change your weekly goal")
            } else {
                Image(systemName: "target").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Set a weekly study goal").font(.callout.weight(.semibold))
                    Text("Give your streak a number to beat").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: DS.Space.s)
                Menu("Set goal") { WeeklyGoalMenu(goalMinutes: $goalMinutes) }.fixedSize()
            }
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
    }

    // MARK: - Glance rows

    private var streakStats: [GlanceStat] {
        let current = StudyStats.currentStreak(state.data), longest = StudyStats.longestStreak(state.data)
        return [GlanceStat(value: "\(current)", label: "current streak, days", isEmpty: current == 0),
                GlanceStat(value: "\(longest)", label: "longest streak, days", isEmpty: longest == 0),
                GlanceStat(value: timeStr(weekTotal), label: "studied this week", isEmpty: weekTotal < 60)]
    }

    private var readingCard: some View {
        let streak = StudyStats.readingStreak(state.data), pages = StudyStats.pagesThisWeek(state.data)
        let books = StudyStats.booksThisYear(state.data)
        return glanceCard(GlanceRow(stats: [
            GlanceStat(value: "\(streak)", label: "reading streak, days", isEmpty: streak == 0),
            GlanceStat(value: "\(pages)", label: "pages this week", isEmpty: pages == 0),
            GlanceStat(value: "\(books)", label: "books in \(Calendar.current.component(.year, from: .now))", isEmpty: books == 0),
        ], emptyText: "No reading logged yet"))
    }

    // MARK: - 7-day study chart

    private var barChart: some View {
        let avg = weekAvgMin
        return Chart {
            ForEach(week7, id: \.day) { item in
                BarMark(x: .value("Day", item.day, unit: .day),
                        y: .value("Minutes", item.minutes),
                        width: .ratio(0.62))
                    .foregroundStyle(Calendar.current.isDateInToday(item.day)
                                     ? AnyShapeStyle(.tint) : AnyShapeStyle(.tint.opacity(0.4)))
                    .cornerRadius(4)
                    .annotation(position: .top, spacing: 2) {
                        if item.minutes > 0 {
                            Text("\(item.minutes)").font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
            }
            if avg > 0 {
                RuleMark(y: .value("Average", avg))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.tint.opacity(0.55))
            }
        }
        .chartXAxis {
            AxisMarks(values: week7.map(\.day)) { value in
                AxisValueLabel {
                    if let d = value.as(Date.self) {
                        Text(dayLabel(d)).font(.system(size: 9))
                            .foregroundStyle(Calendar.current.isDateInToday(d) ? .primary : .secondary)
                    }
                }
            }
        }
        .chartYAxis(.hidden)
        .frame(height: 128)
        .animation(.snappy, value: week7.map(\.minutes))   // Swift Charts eases data changes
        .dsCard()
        .overlay(alignment: .topTrailing) {
            if avg > 0 { Text("avg \(avg)m").font(.caption2).foregroundStyle(.secondary).padding(DS.Space.m) }
        }
    }

    // MARK: - Time by course (course color = identity, allowed)

    private var courseBars: some View {
        VStack(spacing: DS.Space.m) {
            if byCourse.isEmpty {
                Text("No study time logged this week. Start a Pomodoro or Stopwatch.")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                let maxSec = max(1, byCourse.map(\.seconds).max() ?? 1)
                ForEach(Array(byCourse.enumerated()), id: \.offset) { _, row in
                    let course = state.course(row.courseID)
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        HStack(spacing: DS.Space.s) {
                            Circle().fill(course?.color ?? .secondary).frame(width: 7, height: 7)
                            Text(course?.name ?? "Unassigned").font(.caption.weight(.medium)).lineLimit(1)
                            Spacer()
                            Text(timeStr(row.seconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.secondary.opacity(0.12)).frame(height: 8)
                                Capsule().fill(course?.color ?? .accentColor)
                                    .frame(width: max(6, geo.size.width * CGFloat(row.seconds) / CGFloat(maxSec)), height: 8)
                            }
                        }.frame(height: 8)
                    }
                }
            }
        }
    }

    // MARK: - Flashcard retention

    private var retentionCard: some View {
        let ret = StudyStats.flashcardRetention(state.data)
        let due = StudyStats.cardsDueToday(state.data)
        return VStack(alignment: .leading, spacing: DS.Space.m) {
            GlanceRow(stats: [
                GlanceStat(value: ret.map { "\(Int(($0 * 100).rounded()))%" } ?? "", label: "retention", isEmpty: ret == nil),
                GlanceStat(value: "\(due)", label: "due now", isEmpty: due == 0),
                GlanceStat(value: "\(state.data.flashcards.count)", label: "cards"),
            ])
            if let ret {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.12)).frame(height: 6)
                        Capsule().fill(.tint).frame(width: geo.size.width * CGFloat(ret), height: 6)
                    }
                }.frame(height: 6)
            }
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }

    // MARK: - Helpers

    @ViewBuilder private func section<C: View>(_ title: String, _ count: Int?, _ icon: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionHeader(title: title, count: count, systemImage: icon)
            c()
        }
    }

    private func dayLabel(_ d: Date) -> String {
        weekdaySymbols[Calendar.current.component(.weekday, from: d)]
    }
    private func timeStr(_ s: Int) -> String {
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}
