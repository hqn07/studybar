import SwiftUI
import EventKit
import UniformTypeIdentifiers

// MARK: - Unified agenda item

struct AgendaItem: Identifiable {
    enum Kind { case calendar, feed, assignment, klass }
    let id: String
    let start: Date
    let end: Date?
    let allDay: Bool
    let title: String
    let subtitle: String
    let color: Color
    let kind: Kind
    let link: String?
    var jump: String? = nil          // module id to open on tap
    var assignmentID: UUID? = nil    // set for items already tracked as assignments
    /// key for de-duplicating the same event coming from two sources
    var dedupKey: String { "\(title.lowercased())|\(Int(start.timeIntervalSince1970 / 60))" }
}

// MARK: - Merged Calendar + Feeds module

struct CalendarView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var cal = CalendarService()
    @AppStorage("calRangeDays") private var rangeDays = 14
    @AppStorage("calViewMode") private var viewMode = "list"    // list | week
    @AppStorage("calShowEvents") private var showEvents = true
    @AppStorage("calShowAssignments") private var showAssignments = true
    @AppStorage("calShowClasses") private var showClasses = true
    @AppStorage("calShowFeeds") private var showFeeds = true
    @State private var feedEvents: [UUID: [ICSEvent]] = [:]
    @State private var loadingFeeds = false
    @State private var showSources = false
    @State private var showNewEvent = false

    private let refreshTimer = Timer.publish(every: 3600, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ModulePane(title: "Calendar") {
                HStack(spacing: 8) {
                    Button { viewMode = viewMode == "list" ? "week" : "list" } label: {
                        Image(systemName: viewMode == "list" ? "calendar.day.timeline.left" : "list.bullet")
                    }.help(viewMode == "list" ? "Week view" : "List view")
                    Menu {
                        ForEach([7, 14, 30], id: \.self) { d in
                            Button("Next \(d) days") { rangeDays = d; reload() }
                        }
                    } label: { Image(systemName: "calendar.badge.clock") }
                        .help("Range: next \(rangeDays) days")
                    Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                    Button { showNewEvent = true } label: { Image(systemName: "calendar.badge.plus") }
                        .help("New calendar event")
                    Button { showSources = true } label: { Image(systemName: "slider.horizontal.3") }
                        .help("Sources & filters")
                }
            } content: {
                VStack(spacing: 0) {
                    filterChips
                    Divider()
                    if !cal.authorized && state.data.icsFeeds.isEmpty && !hasLocalSources {
                        connectPrompt
                    } else if grouped.isEmpty {
                        EmptyState(symbol: "calendar", title: "Nothing scheduled",
                                   subtitle: "No events in the next \(rangeDays) days. Add a feed or turn on more sources with the sliders button.")
                    } else if viewMode == "week" {
                        weekView
                    } else {
                        agenda
                    }
                }
            }
            .navigationDestination(isPresented: $showSources) {
                SourcesView(cal: cal, rangeDays: rangeDays,
                            showAssignments: $showAssignments, showClasses: $showClasses, showFeeds: $showFeeds,
                            reloadFeeds: { await loadFeeds() })
            }
            .navigationDestination(isPresented: $showNewEvent) {
                NewEventView(cal: cal, rangeDays: rangeDays)
            }
            .onAppear { if cal.authorized { cal.load(days: rangeDays) } }
            .task { await loadFeeds() }
            .onReceive(refreshTimer) { _ in reload() }
        }
    }

    // MARK: Filter chips

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("Calendar", "calendar", $showEvents)
                chip("Feeds", "dot.radiowaves.up.forward", $showFeeds)
                chip("Assignments", "checklist", $showAssignments)
                chip("Classes", "graduationcap", $showClasses)
            }.padding(.horizontal, 10).padding(.vertical, 6)
        }
    }

    private func chip(_ label: String, _ icon: String, _ on: Binding<Bool>) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption2)
                Text(label).font(.caption)
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(on.wrappedValue ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.background.secondary), in: Capsule())
            .foregroundStyle(on.wrappedValue ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .overlay(Capsule().stroke(.separator, lineWidth: on.wrappedValue ? 0 : 0.5))
        }.buttonStyle(.plain)
    }

    private var hasLocalSources: Bool {
        (showAssignments && !state.data.assignments.isEmpty) || (showClasses && !state.data.classes.isEmpty)
    }

    // MARK: Agenda list

    private var agenda: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if loadingFeeds { ProgressView().controlSize(.small).padding(.horizontal, 12) }
                ForEach(grouped, id: \.0) { day, items in
                    let allDay = items.filter { $0.allDay }
                    let timed = items.filter { !$0.allDay }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(dayHeader(day)).font(.caption.bold())
                            .foregroundStyle(Calendar.current.isDateInToday(day) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            .padding(.horizontal, 12)
                        if !allDay.isEmpty { allDayRow(allDay) }
                        ForEach(timed) { item in row(item) }
                    }
                }
            }.padding(.vertical, 10)
        }
    }

    // MARK: Week view (7 day-columns)

    private var weekView: some View {
        let today = Calendar.current.startOfDay(for: .now)
        return ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(0..<7, id: \.self) { offset in
                    let day = Calendar.current.date(byAdding: .day, value: offset, to: today)!
                    let items = allItems.filter { Calendar.current.isDate($0.start, inSameDayAs: day) }
                    weekColumn(day, items)
                }
            }.padding(10)
        }
    }

    private func weekColumn(_ day: Date, _ items: [AgendaItem]) -> some View {
        let isToday = Calendar.current.isDateInToday(day)
        return VStack(alignment: .leading, spacing: 5) {
            VStack(alignment: .leading, spacing: 0) {
                Text(day.formatted(.dateTime.weekday(.abbreviated))).font(.caption2.bold())
                    .foregroundStyle(isToday ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text(day.formatted(.dateTime.month(.abbreviated).day())).font(.caption2).foregroundStyle(.secondary)
            }.padding(.horizontal, 6)
            if items.isEmpty {
                Text("—").font(.caption2).foregroundStyle(.tertiary).padding(.horizontal, 6)
            } else {
                ForEach(items) { item in
                    Button { primary(item) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).font(.caption2.weight(.medium)).lineLimit(2)
                            Text(item.allDay ? "all day" : item.start.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .background(item.color.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).fill(item.color).frame(width: 3), alignment: .leading)
                    }.buttonStyle(.plain).help(tip(item))
                }
            }
        }
        .frame(width: 132, alignment: .leading)
        .padding(8)
        .background(isToday ? AnyShapeStyle(.tint.opacity(0.08)) : AnyShapeStyle(.background.secondary),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    private func allDayRow(_ items: [AgendaItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items) { item in
                    HStack(spacing: 4) {
                        Circle().fill(item.color).frame(width: 6, height: 6)
                        Text(item.title).font(.caption2).lineLimit(1)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(item.color.opacity(0.14), in: Capsule())
                    .help(tip(item))
                }
            }.padding(.horizontal, 12)
        }
    }

    private func row(_ item: AgendaItem) -> some View {
        Button { primary(item) } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3).fill(item.color).frame(width: 4, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).fontWeight(.medium).lineLimit(1)
                    HStack(spacing: 6) {
                        Image(systemName: icon(item.kind)).font(.caption2).foregroundStyle(.secondary)
                        Text(timeText(item)).font(.caption).foregroundStyle(.secondary)
                        if !item.subtitle.isEmpty {
                            Text("· \(item.subtitle)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                Spacer()
                if item.kind == .calendar || item.kind == .feed {
                    Button { addAssignment(item) } label: { Image(systemName: "text.badge.plus") }
                        .buttonStyle(.borderless).font(.caption).help("Add to Assignments")
                }
                if let link = item.link, !link.isEmpty {
                    Button { open(link) } label: { Image(systemName: "arrow.up.right.square") }
                        .buttonStyle(.borderless).font(.caption)
                }
                if item.jump != nil {
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(10).contentShape(Rectangle())
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        }
        .buttonStyle(.plain)
        .help(tip(item))
        .padding(.horizontal, 10)
    }

    private func primary(_ item: AgendaItem) {
        if let j = item.jump { state.selectedModuleID = j }
        else if let link = item.link, !link.isEmpty { open(link) }
    }

    private func addAssignment(_ item: AgendaItem) {
        let exists = state.data.assignments.contains { $0.title == item.title && $0.due == item.start }
        guard !exists else { return }
        state.data.assignments.append(
            Assignment(title: item.title, due: item.start, link: item.link ?? "", notes: item.subtitle))
    }

    // MARK: Build merged items

    private var allItems: [AgendaItem] {
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: rangeDays, to: Calendar.current.startOfDay(for: now)) ?? now
        var out: [AgendaItem] = []

        // Mac Calendar events
        if showEvents {
            for ev in cal.events {
                out.append(AgendaItem(
                    id: "cal-\(ev.eventIdentifier ?? UUID().uuidString)-\(ev.startDate.timeIntervalSince1970)",
                    start: ev.startDate, end: ev.endDate, allDay: ev.isAllDay,
                    title: ev.title ?? "Event",
                    subtitle: ev.calendar.title,
                    color: ev.calendar.cgColor.map { Color(cgColor: $0) } ?? .accentColor,
                    kind: .calendar, link: nil))
            }
        }
        // iCal feeds
        if showFeeds {
            for feed in state.data.icsFeeds {
                for e in (feedEvents[feed.id] ?? []) {
                    guard let s = e.start, s >= now.addingTimeInterval(-3600), s <= end else { continue }
                    out.append(AgendaItem(
                        id: "feed-\(feed.id)-\(e.id)", start: s, end: e.end, allDay: false,
                        title: e.title, subtitle: feed.name.isEmpty ? "Feed" : feed.name,
                        color: state.course(feed.courseID)?.color ?? .purple,
                        kind: .feed, link: e.url.isEmpty ? nil : e.url))
                }
            }
        }
        // Assignments
        if showAssignments {
            for a in state.data.assignments where a.status != .done {
                guard let due = a.due, due >= now.addingTimeInterval(-86400), due <= end else { continue }
                out.append(AgendaItem(
                    id: "asg-\(a.id)", start: due, end: nil, allDay: false,
                    title: a.title.isEmpty ? "Assignment" : a.title,
                    subtitle: state.course(a.courseID)?.name ?? "Due",
                    color: state.course(a.courseID)?.color ?? .orange,
                    kind: .assignment, link: a.link.isEmpty ? nil : a.link,
                    jump: "assignments", assignmentID: a.id))
            }
        }
        // Class schedule occurrences
        if showClasses {
            for offset in 0...rangeDays {
                guard let day = Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: now)) else { continue }
                let wd = Calendar.current.component(.weekday, from: day)
                for c in state.data.classes where c.weekday == wd {
                    guard let start = Calendar.current.date(bySettingHour: c.startMinutes/60, minute: c.startMinutes%60, second: 0, of: day) else { continue }
                    if start < now.addingTimeInterval(-3600) { continue }
                    out.append(AgendaItem(
                        id: "class-\(c.id)-\(offset)", start: start,
                        end: Calendar.current.date(bySettingHour: c.endMinutes/60, minute: c.endMinutes%60, second: 0, of: day),
                        allDay: false,
                        title: state.course(c.courseID)?.name ?? (c.title.isEmpty ? "Class" : c.title),
                        subtitle: c.room, color: state.course(c.courseID)?.color ?? .blue,
                        kind: .klass, link: c.link.isEmpty ? nil : c.link, jump: "schedule"))
                }
            }
        }
        // De-dup the same event arriving from two sources; prefer calendar > class > assignment > feed.
        func priority(_ k: AgendaItem.Kind) -> Int {
            switch k { case .calendar: return 0; case .klass: return 1; case .assignment: return 2; case .feed: return 3 }
        }
        var seen = Set<String>()
        var deduped: [AgendaItem] = []
        for item in out.sorted(by: { priority($0.kind) < priority($1.kind) }) {
            if seen.insert(item.dedupKey).inserted { deduped.append(item) }
        }
        return deduped.sorted { $0.start < $1.start }
    }

    private var grouped: [(Date, [AgendaItem])] {
        let dict = Dictionary(grouping: allItems) { Calendar.current.startOfDay(for: $0.start) }
        return dict.keys.sorted().map { ($0, dict[$0]!) }
    }

    // MARK: Prompt / helpers

    private var connectPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar").font(.system(size: 40)).foregroundStyle(.tint)
            Text("Your unified agenda").font(.headline)
            Text("Combine macOS Calendar, subscribed feeds (Canvas), assignment due dates and class times into one timeline.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Connect Calendar") { cal.requestAndLoad(days: rangeDays) }.buttonStyle(.borderedProminent)
            Button("Add a feed / choose sources") { showSources = true }.buttonStyle(.borderless).font(.caption)
            if cal.denied {
                Text("Calendar denied — enable in System Settings ▸ Privacy ▸ Calendars.")
                    .font(.caption2).foregroundStyle(.red)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }

    private func reload() { if cal.authorized { cal.load(days: rangeDays) }; Task { await loadFeeds() } }
    private func loadFeeds() async {
        guard !state.data.icsFeeds.isEmpty else { return }
        loadingFeeds = true
        for feed in state.data.icsFeeds {
            if let evs = await cal.fetchFeed(feed.url) { feedEvents[feed.id] = evs }
        }
        // Materialize assignment-type feed events into real Assignments (deduped).
        _ = await CanvasFeedImport.run(state: state)
        loadingFeeds = false
    }

    private func dayHeader(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return "TODAY · " + d.formatted(.dateTime.weekday(.wide).month().day()) }
        if Calendar.current.isDateInTomorrow(d) { return "TOMORROW · " + d.formatted(.dateTime.month().day()) }
        return d.formatted(.dateTime.weekday(.wide).month().day()).uppercased()
    }
    private func timeText(_ item: AgendaItem) -> String {
        if item.kind == .assignment { return "Due " + item.start.formatted(date: .omitted, time: .shortened) }
        if item.allDay { return "All day" }
        let s = item.start.formatted(date: .omitted, time: .shortened)
        if let e = item.end { return "\(s) – \(e.formatted(date: .omitted, time: .shortened))" }
        return s
    }
    private func icon(_ k: AgendaItem.Kind) -> String {
        switch k { case .calendar: return "calendar"; case .feed: return "dot.radiowaves.up.forward"
        case .assignment: return "checklist"; case .klass: return "graduationcap" }
    }
    /// Where an item came from — shown on hover so duplicates from different sources
    /// are distinguishable (e.g. a macOS Calendar subscription vs a StudyBar feed import).
    private func sourceLabel(_ item: AgendaItem) -> String {
        switch item.kind {
        case .calendar:   return item.subtitle.isEmpty ? "macOS Calendar" : "macOS Calendar · \(item.subtitle)"
        case .feed:       return item.subtitle.isEmpty ? "Subscribed feed" : "Feed · \(item.subtitle)"
        case .assignment: return "StudyBar assignment"
        case .klass:      return "Class schedule"
        }
    }
    /// Multi-line hover tooltip: title · source · time · link.
    private func tip(_ item: AgendaItem) -> String {
        var lines = [item.title, "Source: \(sourceLabel(item))", timeText(item)]
        if let link = item.link, !link.isEmpty { lines.append(link) }
        return lines.joined(separator: "\n")
    }
    private func open(_ s: String) {
        let u = s.contains("://") ? s : "https://\(s)"
        if let url = URL(string: u) { NSWorkspace.shared.open(url) }
    }
}

// MARK: - Create a macOS Calendar event (EventKit write)

struct NewEventView: View {
    @ObservedObject var cal: CalendarService
    let rangeDays: Int
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var day = Date()
    @State private var start = NewEventView.defaultStart()
    @State private var end = NewEventView.defaultStart().addingTimeInterval(3600)
    @State private var allDay = false
    @State private var notes = ""
    @State private var calID = ""
    @State private var error: String?

    private var writable: [EKCalendar] { cal.writableCalendars }

    var body: some View {
        VStack(spacing: 0) {
            SubHeader("New Event")
            Divider()
            if !cal.authorized {
                VStack(spacing: 14) {
                    EmptyState(symbol: "calendar.badge.exclamationmark", title: "Calendar access needed",
                               subtitle: "Grant access to add events to your macOS Calendar.")
                    Button("Grant Calendar access") { cal.requestAndLoad(days: rangeDays) }
                        .buttonStyle(.borderedProminent)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        field("Title") {
                            TextField("Event title", text: $title).textFieldStyle(.roundedBorder)
                        }
                        field("Day") {
                            DatePicker("", selection: $day, displayedComponents: [.date]).labelsHidden()
                        }
                        Toggle("All-day", isOn: $allDay).font(.callout)
                        if !allDay {
                            HStack(spacing: 12) {
                                field("Start") { DatePicker("", selection: $start, displayedComponents: [.hourAndMinute]).labelsHidden() }
                                field("End") { DatePicker("", selection: $end, displayedComponents: [.hourAndMinute]).labelsHidden() }
                            }
                        }
                        field("Calendar") {
                            Picker("", selection: $calID) {
                                ForEach(writable, id: \.calendarIdentifier) { c in
                                    Text(c.title).tag(c.calendarIdentifier)
                                }
                            }.labelsHidden()
                        }
                        field("Notes") {
                            TextField("Optional", text: $notes, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...3)
                        }
                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }.padding(14)
                }
                Divider()
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                    Button("Create") { create() }
                        .buttonStyle(.borderedProminent)
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }.padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("").toolbar(.hidden, for: .windowToolbar)
        .onAppear { if calID.isEmpty { calID = cal.defaultCalendar?.calendarIdentifier ?? writable.first?.calendarIdentifier ?? "" } }
    }

    @ViewBuilder private func field<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(.caption2.bold()).foregroundStyle(.secondary)
            content()
        }
    }

    private func create() {
        let calendar = writable.first { $0.calendarIdentifier == calID }
        let (s, e) = resolvedTimes()
        let ok = cal.createEvent(title: title.trimmingCharacters(in: .whitespaces),
                                 start: s, end: e, allDay: allDay,
                                 calendar: calendar, notes: notes, days: rangeDays)
        if ok { dismiss() } else { error = "Couldn't save the event. Check Calendar permissions." }
    }

    /// Combine the chosen day with the start/end times.
    private func resolvedTimes() -> (Date, Date) {
        let calr = Calendar.current
        let dayStart = calr.startOfDay(for: day)
        if allDay { return (dayStart, dayStart) }
        func combine(_ time: Date) -> Date {
            let t = calr.dateComponents([.hour, .minute], from: time)
            return calr.date(bySettingHour: t.hour ?? 9, minute: t.minute ?? 0, second: 0, of: day) ?? day
        }
        var s = combine(start), e = combine(end)
        if e <= s { e = s.addingTimeInterval(3600) }
        return (s, e)
    }

    private static func defaultStart() -> Date {
        let calr = Calendar.current
        let next = calr.date(bySettingHour: (calr.component(.hour, from: .now) + 1), minute: 0, second: 0, of: .now)
        return next ?? .now
    }
}
