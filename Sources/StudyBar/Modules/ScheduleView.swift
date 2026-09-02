import SwiftUI
import AppKit
import UniformTypeIdentifiers

let weekdaySymbols = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

/// A parsed batch of draft classes awaiting review (drives the import sheet).
struct ClassImportBatch: Identifiable, Hashable { let id = UUID(); var drafts: [ClassSession] }
private let weekdayLetters = ["", "S", "M", "T", "W", "T", "F", "S"]

/// Which face of the unified Schedule is showing: the recurring weekly class grid, or
/// the day-by-day time-block planner. Persisted so it survives module switches.
enum ScheduleMode: String { case week, plan }

/// The unified **Schedule** module — a Week / Plan toggle over two views that used to be
/// separate modules: the weekly class grid (`WeekGridView`) and the time-block day
/// planner (`DayPlannerView`, formerly "Time Blocking"). Each face keeps its own polished
/// interaction model and toolbar; this wrapper just picks which one to show.
struct ScheduleView: View {
    @AppStorage("scheduleMode") private var modeRaw = ScheduleMode.week.rawValue
    var body: some View {
        if ScheduleMode(rawValue: modeRaw) == .plan { DayPlannerView() } else { WeekGridView() }
    }
}

/// A shared Week / Plan segmented control for either face's toolbar.
struct ScheduleModePicker: View {
    @AppStorage("scheduleMode") private var modeRaw = ScheduleMode.week.rawValue
    var body: some View {
        Picker("", selection: $modeRaw) {
            Text("Week").tag(ScheduleMode.week.rawValue)
            Text("Plan").tag(ScheduleMode.plan.rawValue)
        }
        .pickerStyle(.segmented).labelsHidden().frame(width: 128).fixedSize()
        .help("Week grid · time-block planner")
    }
}

/// A weekly timetable: weekday columns × a time ruler, with each class drawn as a block
/// spanning its real duration (so a two-period lab is a tall block). A class that meets
/// on several days (MWF) is one record shown in each of those columns.
struct WeekGridView: View {
    @EnvironmentObject var state: AppState
    @State private var editing: ClassSession?
    @State private var importBatch: ClassImportBatch?
    @State private var importError: String?
    @State private var weekOffset = 0        // 0 = this week; ± pages through weeks
    @AppStorage("useClassPeriods") private var useClassPeriods = false

    private let hourHeight: CGFloat = 52
    private var gutter: CGFloat { useClassPeriods ? 54 : 44 }
    private var pxPerMin: CGFloat { hourHeight / 60 }

    private var cal: Calendar { Calendar.current }
    private var today: Int { cal.component(.weekday, from: .now) }
    private var isCurrentWeek: Bool { weekOffset == 0 }

    /// The week currently shown (this week shifted by `weekOffset`).
    private var displayedWeek: DateInterval {
        let now = cal.date(byAdding: .weekOfYear, value: weekOffset, to: .now) ?? .now
        return cal.dateInterval(of: .weekOfYear, for: now) ?? DateInterval(start: now, duration: 604800)
    }
    /// The calendar date of weekday `wd` within the displayed week.
    private func date(for wd: Int) -> Date? {
        let start = displayedWeek.start
        let delta = (wd - cal.component(.weekday, from: start) + 7) % 7
        return cal.date(byAdding: .day, value: delta, to: start)
    }
    /// Planned time-blocks on the displayed week's instance of weekday `wd`.
    private func blockCount(for wd: Int) -> Int {
        guard let d = date(for: wd) else { return 0 }
        return (state.data.timeBlocks ?? []).filter { cal.isDate($0.day, inSameDayAs: d) }.count
    }
    private var nowMinutes: Int {
        let c = cal.dateComponents([.hour, .minute], from: .now); return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// Mon–Fri always; Sat / Sun appended only when a class actually meets then.
    private var visibleDays: [Int] {
        var days = [2, 3, 4, 5, 6]
        let used = Set(state.data.classes.filter { !$0.isAsync }.flatMap { $0.weekdays })
        if used.contains(7) { days.append(7) }
        if used.contains(1) { days.append(1) }
        return days
    }
    private func classes(on wd: Int) -> [ClassSession] {
        state.data.classes.filter { !$0.isAsync && $0.meets(on: wd) }
    }
    /// Online classes with no set meeting time — shown in a strip, not on the grid.
    private var asyncClasses: [ClassSession] {
        state.data.classes.filter { $0.isAsync }
    }
    private var range: (lo: Int, hi: Int) {
        let mins = state.data.classes.flatMap { [$0.startMinutes, $0.endMinutes] }
        let lo = min(8 * 60, mins.min() ?? 9 * 60)
        let hi = max(17 * 60, mins.max() ?? 17 * 60)
        return (max(0, (lo / 60) * 60), min(24 * 60, ((hi + 59) / 60) * 60))
    }

    private var nextClass: (session: ClassSession, day: Int)? {
        let occ = state.data.classes.filter { !$0.isAsync }.flatMap { c in c.weekdays.map { (c, $0) } }
        if let n = occ.filter({ $0.1 == today && $0.0.endMinutes >= nowMinutes })
            .sorted(by: { $0.0.startMinutes < $1.0.startMinutes }).first { return (n.0, n.1) }
        return nil
    }

    var body: some View {
        NavigationStack {
            ModulePane(title: "Schedule") {
                HStack(spacing: 8) {
                    ScheduleModePicker()
                    Menu {
                        Toggle("Class periods (UF)", isOn: $useClassPeriods)
                        Divider()
                        Button { runImport() } label: { Label("Import from .ics…", systemImage: "square.and.arrow.down") }
                        if mergeableCount > 0 {
                            Divider()
                            Button {
                                mergeDuplicates()
                            } label: { Label("Merge \(mergeableCount) duplicate \(mergeableCount == 1 ? "class" : "classes")", systemImage: "arrow.triangle.merge") }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    Button { addClass(day: today, at: nil) } label: { Image(systemName: "plus") }
                        .help("Add a class")
                }
            } content: {
                if state.data.classes.isEmpty {
                    VStack(spacing: DS.Space.m) {
                        EmptyState(symbol: "calendar.badge.clock", title: "No classes yet",
                                   subtitle: "Add your weekly classes — pick the days it meets (MWF is one class) and its time.")
                        HStack(spacing: DS.Space.s) {
                            Button { addClass(day: today, at: nil) } label: { Label("Add a class", systemImage: "plus") }
                            Button { runImport() } label: { Label("Import .ics", systemImage: "square.and.arrow.down") }
                        }.buttonStyle(.bordered).controlSize(.small)
                    }
                } else {
                    VStack(spacing: 0) {
                        weekNavBar
                        Divider()
                        if let n = nextClass { nextBanner(n.session); Divider() }
                        if !asyncClasses.isEmpty { onlineStrip; Divider() }
                        if state.data.classes.contains(where: { !$0.isAsync }) {
                            grid
                        } else {
                            EmptyState(symbol: "video", title: "Online classes only",
                                       subtitle: "Your classes have no set meeting time — they're listed above. Add a class with days to see the weekly grid.")
                        }
                    }
                }
            }
            .navigationDestination(item: $editing) { ClassEditor(session: $0) }
            .navigationDestination(item: $importBatch) { ClassImportView(drafts: $0.drafts) }
            .alert("Couldn't import", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) { importError = nil }
            } message: { Text(importError ?? "") }
        }
    }

    /// Pick an .ics file, parse it into draft classes, and open the review sheet.
    private func runImport() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let t = UTType(filenameExtension: "ics") { panel.allowedContentTypes = [t] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            importError = "Couldn't read that file."; return
        }
        let drafts = ClassImport.fromICS(text)
        if drafts.isEmpty { importError = "No class events found in that calendar." }
        else { importBatch = ClassImportBatch(drafts: drafts) }
    }

    // MARK: Next-up banner

    private func nextBanner(_ s: ClassSession) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.badge").font(.title3).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Next: \(title(s))").font(.callout.weight(.semibold))
                Text("\(s.startString) – \(s.endString)\(s.room.isEmpty ? "" : " · \(s.room)")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !s.link.isEmpty {
                Button { open(s.link) } label: { Image(systemName: "video") }.buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    /// Off-grid strip for async online classes — tap to edit, or open the meeting link.
    private var onlineStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.s) {
                Label("ONLINE", systemImage: "video").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                ForEach(asyncClasses) { c in
                    HStack(spacing: 6) {
                        if let col = state.course(c.courseID)?.color { Circle().fill(col).frame(width: 6, height: 6) }
                        Text(state.course(c.courseID)?.code.nonEmpty ?? (c.title.isEmpty ? "Class" : c.title))
                            .font(.caption.weight(.medium)).lineLimit(1)
                        if !c.link.isEmpty {
                            Button { open(c.link) } label: { Image(systemName: "arrow.up.forward.app") }
                                .buttonStyle(.borderless).help("Open meeting link")
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.sbSurface, in: Capsule())
                    .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
                    .contentShape(Capsule())
                    .onTapGesture { editing = c }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, DS.Space.s)
        }
    }

    // MARK: Grid

    private var grid: some View {
        let (lo, hi) = range
        let days = visibleDays
        let totalHeight = CGFloat(hi - lo) * pxPerMin
        return GeometryReader { geo in
            let dayWidth = max(56, (geo.size.width - gutter) / CGFloat(days.count))
            VStack(spacing: 0) {
                headerRow(days: days, dayWidth: dayWidth)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        ZStack(alignment: .topLeading) {
                            hourLines(lo: lo, hi: hi, width: gutter + dayWidth * CGFloat(days.count))
                            // Today column highlight (only when viewing the current week).
                            if isCurrentWeek, let ti = days.firstIndex(of: today) {
                                Rectangle().fill(.tint.opacity(0.05))
                                    .frame(width: dayWidth, height: totalHeight)
                                    .offset(x: gutter + CGFloat(ti) * dayWidth)
                            }
                            // Column separators + tap-to-add background.
                            ForEach(Array(days.enumerated()), id: \.element) { i, wd in
                                columnLayer(wd: wd, index: i, lo: lo, dayWidth: dayWidth, totalHeight: totalHeight)
                            }
                            if isCurrentWeek, let ti = days.firstIndex(of: today) {
                                nowLine(lo: lo, hi: hi, x: gutter + CGFloat(ti) * dayWidth, width: dayWidth)
                            }
                            // Anchor for auto-scrolling to the current time on open.
                            Color.clear.frame(width: 1, height: 1)
                                .offset(y: y(min(hi, max(lo, nowMinutes)), lo: lo)).id("now")
                        }
                        .frame(width: gutter + dayWidth * CGFloat(days.count), height: totalHeight, alignment: .topLeading)
                    }
                    .onAppear {
                        guard nowMinutes >= lo && nowMinutes <= hi else { return }
                        DispatchQueue.main.async { proxy.scrollTo("now", anchor: .center) }
                    }
                }
            }
        }
    }

    /// Week navigation: page through weeks, jump back to this one.
    private var weekNavBar: some View {
        HStack(spacing: DS.Space.m) {
            Button { withAnimation { weekOffset -= 1 } } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
            Text(weekRangeLabel).font(.callout.weight(.semibold)).contentTransition(.numericText())
            Button { withAnimation { weekOffset += 1 } } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
            Spacer()
            if !isCurrentWeek {
                Button("This week") { withAnimation { weekOffset = 0 } }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, DS.Space.s)
    }
    private var weekRangeLabel: String {
        let s = displayedWeek.start, e = cal.date(byAdding: .day, value: 6, to: s) ?? s
        let f = DateFormatter(); f.dateFormat = "MMM d"
        let base = "\(f.string(from: s)) – \(f.string(from: e))"
        return isCurrentWeek ? "This week · \(base)" : base
    }

    private func headerRow(days: [Int], dayWidth: CGFloat) -> some View {
        let due = weekDue
        return HStack(spacing: 0) {
            Color.clear.frame(width: gutter, height: 50)
            ForEach(days, id: \.self) { wd in
                let isTodayCol = isCurrentWeek && wd == today
                VStack(spacing: 3) {
                    HStack(spacing: 4) {
                        Text(weekdayLetters[wd]).font(.subheadline.weight(.bold))
                        if let d = date(for: wd) {
                            Text("\(cal.component(.day, from: d))").font(.caption)
                        }
                    }
                    .foregroundStyle(isTodayCol ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background { if isTodayCol { Capsule().fill(.tint) } }
                    markerRow(due[wd] ?? [], blocks: blockCount(for: wd))
                }
                .frame(width: dayWidth, height: 50)
            }
        }
        .frame(height: 50)                 // don't let the flexible spacer stretch the header
    }

    /// Under a weekday: due-marker dots (red for exams/quizzes, accent otherwise) plus a small
    /// count of planned time-blocks on that day.
    @ViewBuilder private func markerRow(_ items: [Assignment], blocks: Int) -> some View {
        HStack(spacing: 3) {
            ForEach(items.prefix(3)) { a in
                Circle().fill(isExam(a) ? Color.red : Color.accentColor).frame(width: 5, height: 5)
            }
            if items.count > 3 { Text("+\(items.count - 3)").font(.system(size: 8)).foregroundStyle(.secondary) }
            if blocks > 0 {
                HStack(spacing: 1) {
                    Image(systemName: "square.stack").font(.system(size: 7))
                    Text("\(blocks)").font(.system(size: 8, weight: .semibold))
                }.foregroundStyle(.tint)
            }
        }
        .frame(height: 9)
        .help(items.isEmpty ? "" : dueHelp(items))
    }
    private func dueHelp(_ items: [Assignment]) -> String {
        items.map { a in
            let t = a.title.isEmpty ? "Untitled" : a.title
            return a.due.map { "\(t) — due \($0.formatted(date: .omitted, time: .shortened))" } ?? t
        }.joined(separator: "\n")
    }
    private func isExam(_ a: Assignment) -> Bool {
        let t = a.title.lowercased()
        return ["exam", "midterm", "final", "quiz", "test"].contains { t.contains($0) }
    }
    /// Open assignments due in the displayed calendar week, bucketed by weekday (1=Sun…7=Sat).
    private var weekDue: [Int: [Assignment]] {
        let wi = displayedWeek
        var out: [Int: [Assignment]] = [:]
        for a in state.data.assignments where a.status != .done {
            guard let d = a.due, wi.contains(d) else { continue }
            out[cal.component(.weekday, from: d), default: []].append(a)
        }
        for k in out.keys { out[k]?.sort { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) } }
        return out
    }

    @ViewBuilder private func hourLines(lo: Int, hi: Int, width: CGFloat) -> some View {
        // Hour lines + labels (the time ruler).
        ForEach(Array(stride(from: lo, through: hi, by: 60)), id: \.self) { m in
            HStack(alignment: .top, spacing: 0) {
                Text(hourLabel(m)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: gutter - 6, alignment: .trailing).offset(y: -6)
                Rectangle().fill(.separator.opacity(0.4)).frame(height: 0.5).padding(.leading, 6)
            }
            .offset(y: y(m, lo: lo))
        }
        // Period numbers in the gutter (opt-in), centered on each period band.
        if useClassPeriods {
            ForEach(ClassPeriods.uf.filter { $0.start >= lo && $0.end <= hi }) { p in
                Text(p.label)
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.tint)
                    .frame(width: 16, height: 14)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                    .offset(x: 2, y: y((p.start + p.end) / 2, lo: lo) - 7)
            }
        }
    }

    private func columnLayer(wd: Int, index i: Int, lo: Int, dayWidth: CGFloat, totalHeight: CGFloat) -> some View {
        let x = gutter + CGFloat(i) * dayWidth
        return ZStack(alignment: .topLeading) {
            // Left separator.
            Rectangle().fill(.separator.opacity(0.4)).frame(width: 0.5, height: totalHeight)
            // Tap empty space → add a class at that day + time.
            Color.clear.frame(width: dayWidth, height: totalHeight).contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { v in
                    addClass(day: wd, at: snap(lo + Int(v.location.y / pxPerMin)))
                })
            ForEach(laid(classes(on: wd)), id: \.c.id) { item in
                classBlock(item.c, lane: item.lane, lanes: item.lanes, lo: lo, dayWidth: dayWidth)
            }
        }
        .frame(width: dayWidth, height: totalHeight, alignment: .topLeading)
        .offset(x: x)
    }

    private func classBlock(_ c: ClassSession, lane: Int, lanes: Int, lo: Int, dayWidth: CGFloat) -> some View {
        let laneW = (dayWidth - 3 - CGFloat(lanes - 1) * 2) / CGFloat(lanes)
        let color = state.course(c.courseID)?.color ?? .accentColor
        let h = max(24, CGFloat(c.endMinutes - c.startMinutes) * pxPerMin)
        return Button { editing = c } label: {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.course(c.courseID)?.code.nonEmpty ?? (c.title.isEmpty ? "Class" : c.title))
                        .font(.caption.weight(.bold)).lineLimit(1)
                    if h > 30 {
                        Text(blockTimeLabel(c))
                            .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if h > 46, !c.room.isEmpty {
                        Label(c.room, systemImage: "mappin").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 3).padding(.vertical, 3)
            .frame(width: laneW, height: h, alignment: .topLeading)
            .background(color.opacity(0.22), in: RoundedRectangle(cornerRadius: DS.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(color.opacity(0.5), lineWidth: 0.5))
            .overlay(alignment: .topTrailing) {
                if c.isOnline && !c.link.isEmpty {
                    Image(systemName: "video.fill").font(.system(size: 8)).foregroundStyle(color).padding(3)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !c.link.isEmpty { Button { open(c.link) } label: { Label("Open link", systemImage: "video") } }
            Button("Edit") { editing = c }
            Button("Delete", role: .destructive) { state.withUndo("Delete class") { state.data.classes.removeAll { $0.id == c.id } } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11yLabel(c))
        .accessibilityHint("Edit class")
        .offset(x: 2 + CGFloat(lane) * (laneW + 2), y: y(c.startMinutes, lo: lo))
    }

    private func a11yLabel(_ c: ClassSession) -> String {
        let name = state.course(c.courseID)?.code.nonEmpty ?? (c.title.isEmpty ? "Class" : c.title)
        var s = "\(name), \(c.startString) to \(c.endString)"
        if !c.room.isEmpty { s += ", room \(c.room)" }
        if c.isOnline { s += ", online" }
        return s
    }

    private func nowLine(lo: Int, hi: Int, x: CGFloat, width: CGFloat) -> some View {
        Group {
            if nowMinutes >= lo && nowMinutes <= hi {
                HStack(spacing: 0) {
                    Circle().fill(.red).frame(width: 5, height: 5)
                    Rectangle().fill(.red).frame(height: 1)
                }
                .frame(width: width)
                .offset(x: x - 2, y: y(nowMinutes, lo: lo))
            }
        }
    }

    // MARK: Layout helpers

    private func blockTimeLabel(_ c: ClassSession) -> String {
        let time = "\(c.startString.dropAMPM)-\(c.endString.dropAMPM)"
        if useClassPeriods, let p = ClassPeriods.spanLabel(start: c.startMinutes, end: c.endMinutes) { return "\(p) · \(time)" }
        return time
    }
    private func y(_ minutes: Int, lo: Int) -> CGFloat { CGFloat(minutes - lo) * pxPerMin }
    private func snap(_ m: Int) -> Int { max(0, min(24 * 60, Int((Double(m) / 30).rounded()) * 30)) }
    private func hourLabel(_ m: Int) -> String {
        let h = m / 60, ampm = h < 12 ? "a" : "p", h12 = h % 12 == 0 ? 12 : h % 12
        return "\(h12)\(ampm)"
    }

    /// Column layout for a day's classes: overlapping classes get side-by-side lanes.
    private func laid(_ items: [ClassSession]) -> [(c: ClassSession, lane: Int, lanes: Int)] {
        let sorted = items.sorted { $0.startMinutes < $1.startMinutes }
        var out: [(ClassSession, Int, Int)] = []
        var cluster: [ClassSession] = []; var laneEnd: [Int] = []; var laneOf: [UUID: Int] = [:]; var maxEnd = Int.min
        func flush() {
            let lanes = max(1, laneEnd.count)
            for c in cluster { out.append((c, laneOf[c.id] ?? 0, lanes)) }
            cluster.removeAll(); laneEnd.removeAll(); laneOf.removeAll(); maxEnd = Int.min
        }
        for c in sorted {
            if !cluster.isEmpty && c.startMinutes >= maxEnd { flush() }
            if let free = laneEnd.firstIndex(where: { $0 <= c.startMinutes }) { laneEnd[free] = c.endMinutes; laneOf[c.id] = free }
            else { laneOf[c.id] = laneEnd.count; laneEnd.append(c.endMinutes) }
            cluster.append(c); maxEnd = max(maxEnd, c.endMinutes)
        }
        flush()
        return out.map { ($0.0, $0.1, $0.2) }
    }

    // MARK: Actions

    // MARK: Merge duplicate classes (same course/time/room on different days → one class)

    /// Group key for "the same class, different day".
    private func mergeKey(_ c: ClassSession) -> String {
        "\(c.courseID?.uuidString ?? "-")|\(c.title)|\(c.startMinutes)|\(c.endMinutes)|\(c.room)|\(c.link)"
    }
    /// How many class records would disappear if duplicates were merged.
    private var mergeableCount: Int {
        let groups = Dictionary(grouping: state.data.classes, by: mergeKey)
        return groups.values.reduce(0) { $0 + max(0, $1.count - 1) }
    }
    private func mergeDuplicates() {
        state.withUndo("Merge classes") {
            let groups = Dictionary(grouping: state.data.classes, by: mergeKey)
            var result: [ClassSession] = []
            for g in groups.values {
                if g.count == 1 { result.append(g[0]); continue }
                var merged = g[0]
                let allDays = Set(g.flatMap { $0.weekdays }).sorted()
                merged.days = allDays
                merged.weekday = allDays.first ?? merged.weekday
                result.append(merged)
            }
            state.data.classes = result.sorted { ($0.weekdays.first ?? 0, $0.startMinutes) < ($1.weekdays.first ?? 0, $1.startMinutes) }
        }
    }

    private func addClass(day wd: Int, at start: Int?) {
        let s = start ?? 9 * 60
        var c = ClassSession(courseID: nil)
        c.days = [wd]; c.weekday = wd
        c.startMinutes = s; c.endMinutes = min(24 * 60, s + 50)
        editing = c
    }
    private func title(_ s: ClassSession) -> String {
        let c = state.course(s.courseID)?.name
        return [c, s.title.isEmpty ? nil : s.title].compactMap { $0 }.joined(separator: " · ").ifEmpty("Class")
    }
    private func open(_ s: String) {
        let u = s.contains("://") ? s : "https://\(s)"
        if let url = URL(string: u) { NSWorkspace.shared.open(url) }
    }
}

private extension String {
    func ifEmpty(_ d: String) -> String { isEmpty ? d : self }
    var nonEmpty: String? { isEmpty ? nil : self }
    /// "9:35 AM" → "9:35" (the grid columns are too narrow for AM/PM).
    var dropAMPM: String { replacingOccurrences(of: " AM", with: "").replacingOccurrences(of: " PM", with: "") }
}

// MARK: - Editor (multi-day)

struct ClassEditor: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ClassSession
    @State private var selectedDays: Set<Int>
    @AppStorage("useClassPeriods") private var useClassPeriods = false
    private let isNew: Bool

    /// Weekday order for the day picker: Mon…Fri, then Sat, Sun.
    private let dayOrder = [2, 3, 4, 5, 6, 7, 1]
    private let dayLetter = ["", "Su", "M", "T", "W", "R", "F", "Sa"]

    init(session: ClassSession) {
        _draft = State(initialValue: session)
        _selectedDays = State(initialValue: Set(session.weekdays))
        isNew = AppState.current?.data.classes.contains(where: { $0.id == session.id }) != true
    }

    var body: some View {
        VStack(spacing: 0) {
            SubHeader(isNew ? "New Class" : "Class") {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        state.withUndo("Delete class") { state.data.classes.removeAll { $0.id == draft.id } }
                        dismiss()
                    }
                }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Course").font(.caption).foregroundStyle(.secondary)
                        CoursePicker(courseID: $draft.courseID)
                    }
                    TextField("Label (Lecture, Lab, Discussion…)", text: $draft.title).textFieldStyle(.roundedBorder)

                    Toggle(isOn: Binding(get: { draft.online ?? false }, set: { draft.online = $0 })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Online class")
                            Text("Zoom / Meet — add the link below").font(.caption2).foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Days").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            ForEach(dayOrder, id: \.self) { wd in
                                let on = selectedDays.contains(wd)
                                Button {
                                    if on { selectedDays.remove(wd) } else { selectedDays.insert(wd) }
                                } label: {
                                    Text(dayLetter[wd]).font(.caption.weight(.semibold))
                                        .frame(width: 30, height: 30)
                                        .background(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.sbSurface), in: Circle())
                                        .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                                }.buttonStyle(.plain)
                            }
                        }
                        Text(draft.isOnline ? "Pick the days it meets — or leave empty for async (no set time)."
                                            : "Pick every day this class meets — MWF is one class.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }

                    if useClassPeriods { periodPicker }
                    HStack(spacing: 16) {
                        timePicker("Start", $draft.startMinutes)
                        timePicker("End", $draft.endMinutes)
                    }
                    TextField("Room (e.g. LIT 0109)", text: $draft.room).textFieldStyle(.roundedBorder)
                    TextField("Meeting link (optional)", text: $draft.link).textFieldStyle(.roundedBorder)
                }.padding(14)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(selectedDays.isEmpty && !draft.isOnline)
            }.padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("").toolbar(.hidden, for: .windowToolbar)
    }

    private var periodPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Period").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Menu(ClassPeriods.period(start: draft.startMinutes).map { "Period \($0.label)" } ?? "Start…") {
                    ForEach(ClassPeriods.uf) { p in
                        Button("Period \(p.label) · \(ClassSession.hm(p.start))") {
                            draft.startMinutes = p.start
                            if draft.endMinutes <= p.start { draft.endMinutes = p.end }
                        }
                    }
                }.fixedSize()
                Text("to").font(.caption).foregroundStyle(.secondary)
                Menu(ClassPeriods.periodEnding(draft.endMinutes).map { "Period \($0.label)" } ?? "End…") {
                    ForEach(ClassPeriods.uf) { p in
                        Button("Period \(p.label) · \(ClassSession.hm(p.end))") { draft.endMinutes = p.end }
                    }
                }.fixedSize()
            }
            Text("Pick the period(s) — this fills the times below.").font(.caption2).foregroundStyle(.secondary)
        }
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
        guard !selectedDays.isEmpty || draft.isOnline else { return }   // async online may have no days
        if draft.endMinutes <= draft.startMinutes { draft.endMinutes = min(24 * 60, draft.startMinutes + 50) }
        let days = selectedDays.sorted()
        draft.days = days                    // empty for an async online class → off the grid
        draft.weekday = days.first ?? 2      // keep the legacy field in sync
        if let i = state.data.classes.firstIndex(where: { $0.id == draft.id }) {
            state.data.classes[i] = draft
        } else {
            state.data.classes.append(draft)
        }
        dismiss()
    }
}

// MARK: - Import review (.ics → classes)

struct ClassImportView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    struct Row: Identifiable { let id = UUID(); var c: ClassSession; var include: Bool; var courseID: UUID? }
    @State private var rows: [Row]

    init(drafts: [ClassSession]) {
        _rows = State(initialValue: drafts.map { Row(c: $0, include: true, courseID: $0.courseID) })
    }

    private var selectedCount: Int { rows.filter { $0.include }.count }

    var body: some View {
        VStack(spacing: 0) {
            SubHeader("Import Classes") { }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Text("\(rows.count) class\(rows.count == 1 ? "" : "es") found. Uncheck any you don't want and assign a course.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach($rows) { $row in importRow($row) }
                }.padding(14)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add \(selectedCount) class\(selectedCount == 1 ? "" : "es")") { add() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(selectedCount == 0)
            }.padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("").toolbar(.hidden, for: .windowToolbar)
    }

    private func importRow(_ row: Binding<Row>) -> some View {
        let c = row.wrappedValue.c
        let meta = "\(c.isAsync ? "async" : c.daysShort) · \(c.isAsync ? "no set time" : "\(c.startString)–\(c.endString)")"
            + (c.room.isEmpty ? "" : " · \(c.room)") + (c.isOnline ? " · online" : "")
        return HStack(spacing: DS.Space.m) {
            Toggle("", isOn: row.include).labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(c.title.isEmpty ? "Class" : c.title).fontWeight(.medium).lineLimit(1)
                Text(meta).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: DS.Space.s)
            CoursePicker(courseID: row.courseID)
        }
        .padding(10)
        .background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .opacity(row.wrappedValue.include ? 1 : 0.5)
    }

    private func add() {
        state.withUndo("Import classes") {
            for r in rows where r.include {
                var c = r.c
                c.id = UUID()
                c.courseID = r.courseID
                state.data.classes.append(c)
            }
        }
        dismiss()
    }
}
