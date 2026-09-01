import SwiftUI

struct InsightsView: View {
    @EnvironmentObject var state: AppState

    private var week7: [(day: Date, minutes: Int)] { StudyStats.last7Days(state.data) }
    private var maxMin: Int { max(1, week7.map(\.minutes).max() ?? 1) }
    private var weekAvgMin: Int { week7.map(\.minutes).reduce(0, +) / max(1, week7.count) }
    private var byCourse: [(courseID: UUID?, seconds: Int)] { StudyStats.weekByCourse(state.data) }
    private var weekTotal: Int { StudyStats.secondsThisWeek(state.data) }

    var body: some View {
        ModulePane(title: "Insights") { EmptyView() } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    if AIConfig.isReady { weeklyReviewCard }
                    todayCard
                    streakCard
                    section("Last 7 days", nil, "chart.bar.fill") { barChart }
                    section("This week by course", byCourse.isEmpty ? nil : byCourse.count, "clock") { courseBars }
                    if !state.data.flashcards.isEmpty {
                        section("Flashcard retention", nil, "brain.head.profile") { retentionCard }
                    }
                    if !state.data.reading.isEmpty {
                        section("Reading", nil, "book") { readingCard }
                    }
                }.padding(DS.Space.l)
            }
        }
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

    // MARK: - Metric tiles (mono-accent — semantic color is state only)

    /// Today's counters — moved here from the Today module (which is now glance-first).
    private var todayCard: some View {
        HStack(spacing: DS.Space.m) {
            metric(timeStr(StudyStats.secondsToday(state.data)), "studied today", "clock")
            metric("\(StudyStats.pomodorosToday(state.data))", "pomodoros", "timer")
            metric("\(state.data.assignments.filter { $0.status != .done }.count)", "open tasks", "checklist")
        }
    }

    private var streakCard: some View {
        HStack(spacing: DS.Space.m) {
            metric("\(StudyStats.currentStreak(state.data))", "current streak", "flame.fill")
            metric("\(StudyStats.longestStreak(state.data))", "longest", "trophy.fill")
            metric(timeStr(weekTotal), "this week", "clock.fill")
        }
    }

    private var readingCard: some View {
        HStack(spacing: DS.Space.m) {
            metric("\(StudyStats.readingStreak(state.data))", "reading streak", "flame.fill")
            metric("\(StudyStats.pagesThisWeek(state.data))", "pages this wk", "book.pages")
            metric("\(StudyStats.booksThisYear(state.data))", "books in \(Calendar.current.component(.year, from: .now))", "checkmark.seal.fill")
        }
    }

    private func metric(_ v: String, _ l: String, _ icon: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.callout).foregroundStyle(.tint)
            Text(v).font(.title3.bold().monospacedDigit())
            Text(l).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.vertical, DS.Space.l)
        .background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }

    // MARK: - 7-day study chart

    private var barChart: some View {
        let mins = week7.map(\.minutes)
        let plotH: CGFloat = 116
        let topInset: CGFloat = 16          // headroom for value labels
        let usableH = plotH - topInset
        let avg = weekAvgMin

        return VStack(alignment: .leading, spacing: DS.Space.s) {
            ZStack(alignment: .bottomLeading) {
                // faint grid + weekly-average reference line
                GeometryReader { geo in
                    let w = geo.size.width
                    ForEach([0.0, 0.5, 1.0], id: \.self) { frac in
                        let y = topInset + usableH * (1 - frac)
                        Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y)) }
                            .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
                    }
                    if avg > 0 {
                        let y = topInset + usableH * (1 - CGFloat(avg) / CGFloat(maxMin))
                        Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y)) }
                            .stroke(.tint.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                }
                // bars — today emphasized, value floats above each bar
                HStack(alignment: .bottom, spacing: DS.Space.m) {
                    ForEach(week7, id: \.day) { item in
                        let isToday = Calendar.current.isDateInToday(item.day)
                        let h = max(2, usableH * CGFloat(item.minutes) / CGFloat(maxMin))
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isToday ? AnyShapeStyle(.tint) : AnyShapeStyle(.tint.opacity(0.4)))
                            .frame(height: h)
                            .overlay(alignment: .top) {
                                if item.minutes > 0 {
                                    Text("\(item.minutes)").font(.system(size: 9))
                                        .foregroundStyle(isToday ? .primary : .secondary)
                                        .fixedSize().offset(y: -11)
                                }
                            }
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(height: plotH)
            // weekday axis
            HStack(spacing: DS.Space.m) {
                ForEach(week7, id: \.day) { item in
                    Text(dayLabel(item.day)).font(.system(size: 9))
                        .foregroundStyle(Calendar.current.isDateInToday(item.day) ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .dsCard()
        .overlay(alignment: .topTrailing) {
            if avg > 0 {
                Text("avg \(avg)m").font(.caption2).foregroundStyle(.secondary).padding(DS.Space.m)
            }
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
        return VStack(spacing: DS.Space.m) {
            HStack(spacing: DS.Space.m) {
                metric(ret.map { "\(Int(($0 * 100).rounded()))%" } ?? "—", "retention", "target")
                metric("\(StudyStats.cardsDueToday(state.data))", "due now", "tray.full")
                metric("\(state.data.flashcards.count)", "cards", "rectangle.on.rectangle")
            }
            if let ret {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.12)).frame(height: 6)
                        Capsule().fill(.tint).frame(width: geo.size.width * CGFloat(ret), height: 6)
                    }
                }.frame(height: 6)
            }
        }
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
