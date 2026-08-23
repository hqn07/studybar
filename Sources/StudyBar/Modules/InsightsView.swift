import SwiftUI

struct InsightsView: View {
    @EnvironmentObject var state: AppState

    private var week7: [(day: Date, minutes: Int)] { StudyStats.last7Days(state.data) }
    private var maxMin: Int { max(1, week7.map(\.minutes).max() ?? 1) }
    private var byCourse: [(courseID: UUID?, seconds: Int)] { StudyStats.weekByCourse(state.data) }
    private var weekTotal: Int { StudyStats.secondsThisWeek(state.data) }

    var body: some View {
        ModulePane(title: "Insights") { EmptyView() } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    streakCard
                    section("LAST 7 DAYS") { barChart }
                    section("THIS WEEK BY COURSE") { courseBars }
                    if !state.data.reading.isEmpty {
                        section("READING") { readingCard }
                    }
                }.padding(14)
            }
        }
    }

    private var streakCard: some View {
        HStack(spacing: 12) {
            metric("\(StudyStats.currentStreak(state.data))", "current streak", "flame.fill", .orange)
            metric("\(StudyStats.longestStreak(state.data))", "longest", "trophy.fill", .yellow)
            metric(timeStr(weekTotal), "this week", "clock.fill", .accentColor)
        }
    }

    private func metric(_ v: String, _ l: String, _ icon: String, _ color: Color) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).foregroundStyle(color)
            Text(v).font(.title3.bold().monospacedDigit())
            Text(l).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var readingCard: some View {
        HStack(spacing: 12) {
            metric("\(StudyStats.readingStreak(state.data))", "reading streak", "flame.fill", .orange)
            metric("\(StudyStats.pagesThisWeek(state.data))", "pages this wk", "book.pages", .accentColor)
            metric("\(StudyStats.booksThisYear(state.data))", "books in \(Calendar.current.component(.year, from: .now))", "checkmark.seal.fill", .green)
        }
    }

    private var barChart: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(week7, id: \.day) { item in
                VStack(spacing: 4) {
                    Text(item.minutes > 0 ? "\(item.minutes)" : "")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Calendar.current.isDateInToday(item.day) ? AnyShapeStyle(.tint) : AnyShapeStyle(.tint.opacity(0.5)))
                        .frame(height: max(3, CGFloat(item.minutes) / CGFloat(maxMin) * 90))
                    Text(dayLabel(item.day)).font(.system(size: 9)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity)
            }
        }
        .frame(height: 130)
        .padding(10).background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var courseBars: some View {
        VStack(spacing: 8) {
            if byCourse.isEmpty {
                Text("No study time logged this week. Start a Pomodoro or Stopwatch.")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                let maxSec = max(1, byCourse.map(\.seconds).max() ?? 1)
                ForEach(Array(byCourse.enumerated()), id: \.offset) { _, row in
                    let course = state.course(row.courseID)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(course?.name ?? "Unassigned").font(.caption.weight(.medium))
                            Spacer()
                            Text(timeStr(row.seconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(course?.color ?? .accentColor)
                                .frame(width: max(6, geo.size.width * CGFloat(row.seconds) / CGFloat(maxSec)), height: 8)
                        }.frame(height: 8)
                    }
                }
            }
        }
    }

    @ViewBuilder private func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption2.bold()).foregroundStyle(.secondary)
            c()
        }
    }

    private func dayLabel(_ d: Date) -> String {
        let wd = Calendar.current.component(.weekday, from: d)
        return weekdaySymbols[wd]
    }
    private func timeStr(_ s: Int) -> String {
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}
