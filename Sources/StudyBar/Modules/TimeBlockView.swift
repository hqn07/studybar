import SwiftUI

/// Time Blocking — plan work onto a day timeline.
///
/// A vertical day timeline: your classes render as faint context bands, your planned
/// `TimeBlock`s as solid cards positioned by time (side-by-side when they overlap).
/// Add a block with +, or pull an open assignment / to-do straight onto the day from
/// the Unscheduled menu. Window-first (`wide`); stays inline (NavigationStack +
/// pushed editor) so it never trips the popover's no-modal rule.
struct TimeBlockView: View {
    @EnvironmentObject var state: AppState
    @State private var day = Calendar.current.startOfDay(for: .now)
    @State private var editing: TimeBlock?

    // Timeline metrics.
    private let hourHeight: CGFloat = 56
    private let gutter: CGFloat = 52
    private var pxPerMin: CGFloat { hourHeight / 60 }
    private let minBlockHeight: CGFloat = 26

    private var cal: Calendar { Calendar.current }
    private var isToday: Bool { cal.isDateInToday(day) }
    private var weekday: Int { cal.component(.weekday, from: day) }

    private var blocks: [TimeBlock] { state.timeBlocks(on: day) }
    private var classes: [ClassSession] {
        state.data.classes.filter { $0.weekday == weekday }.sorted { $0.startMinutes < $1.startMinutes }
    }

    /// Hour window: a comfortable 7am–10pm, widened to fit any earlier/later event.
    private var range: (lo: Int, hi: Int) {
        let mins = classes.flatMap { [$0.startMinutes, $0.endMinutes] }
                 + blocks.flatMap { [$0.startMinutes, $0.endMinutes] }
        let lo = min(7 * 60, mins.min() ?? 9 * 60)
        let hi = max(22 * 60, mins.max() ?? 18 * 60)
        return (max(0, (lo / 60) * 60), min(24 * 60, ((hi + 59) / 60) * 60))
    }
    private var plannedMinutes: Int { blocks.reduce(0) { $0 + $1.durationMinutes } }

    var body: some View {
        NavigationStack {
            ModulePane(title: "Time Blocking") {
                HStack(spacing: 6) {
                    unscheduledMenu
                    Button { addBlock() } label: { Image(systemName: "plus") }
                        .help("Add a block")
                }
            } content: {
                VStack(spacing: 0) {
                    dayBar
                    Divider()
                    timeline
                }
            }
            .navigationDestination(item: $editing) { blk in
                TimeBlockEditor(block: blk)
            }
        }
    }

    // MARK: Day navigation + summary

    private var dayBar: some View {
        HStack(spacing: DS.Space.m) {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
            VStack(alignment: .leading, spacing: 1) {
                Text(dayTitle).font(.callout.weight(.semibold))
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
            Spacer()
            if !isToday {
                Button("Today") { withAnimation { day = cal.startOfDay(for: .now) } }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, DS.Space.m)
    }

    private var dayTitle: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        return f.string(from: day) + (isToday ? " · Today" : "")
    }
    private var summary: String {
        if blocks.isEmpty {
            return classes.isEmpty ? "Nothing planned — add a block or pull in work"
                                   : "\(classes.count) class\(classes.count == 1 ? "" : "es") · no blocks yet"
        }
        let h = plannedMinutes / 60, m = plannedMinutes % 60
        let dur = h > 0 ? (m > 0 ? "\(h)h \(m)m" : "\(h)h") : "\(m)m"
        return "\(blocks.count) block\(blocks.count == 1 ? "" : "s") · \(dur) planned"
    }

    // MARK: Timeline

    private var timeline: some View {
        let (lo, hi) = range
        let totalHeight = CGFloat(hi - lo) * pxPerMin
        return ScrollView {
            GeometryReader { geo in
                let contentWidth = max(0, geo.size.width - gutter - 12)
                ZStack(alignment: .topLeading) {
                    hourGrid(lo: lo, hi: hi, width: geo.size.width)
                    ForEach(classes) { c in classBand(c, lo: lo, width: contentWidth) }
                    ForEach(TimeBlock.layout(blocks), id: \.id) { p in
                        if let b = blocks.first(where: { $0.id == p.id }) {
                            blockCard(b, placed: p, lo: lo, width: contentWidth)
                        }
                    }
                    if isToday { nowLine(lo: lo, hi: hi, width: geo.size.width) }
                }
                .frame(width: geo.size.width, height: totalHeight, alignment: .topLeading)
            }
            .frame(height: totalHeight)
        }
    }

    private func y(_ minutes: Int, lo: Int) -> CGFloat { CGFloat(minutes - lo) * pxPerMin }

    private func hourGrid(lo: Int, hi: Int, width: CGFloat) -> some View {
        ForEach(Array(stride(from: lo, through: hi, by: 60)), id: \.self) { m in
            HStack(alignment: .top, spacing: 0) {
                Text(ClassSession.hm(m).replacingOccurrences(of: ":00", with: ""))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: gutter - 8, alignment: .trailing)
                    .offset(y: -6)
                Rectangle().fill(.separator.opacity(0.5)).frame(height: 0.5).padding(.leading, 8)
            }
            .offset(y: y(m, lo: lo))
        }
    }

    private func classBand(_ c: ClassSession, lo: Int, width: CGFloat) -> some View {
        let color = state.course(c.courseID)?.color ?? .secondary
        let h = max(minBlockHeight, CGFloat(c.endMinutes - c.startMinutes) * pxPerMin)
        return VStack(alignment: .leading, spacing: 1) {
            Text(state.course(c.courseID)?.name ?? (c.title.isEmpty ? "Class" : c.title))
                .font(.caption2.weight(.semibold)).lineLimit(1)
            if h > 34 { Text(c.startString).font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .frame(width: width, height: h, alignment: .topLeading)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: DS.Radius.control))
        .overlay(alignment: .leading) { Rectangle().fill(color.opacity(0.4)).frame(width: 2) }
        .foregroundStyle(.secondary)
        .offset(x: gutter, y: y(c.startMinutes, lo: lo))
    }

    private func blockCard(_ b: TimeBlock, placed p: TimeBlock.Placed, lo: Int, width: CGFloat) -> some View {
        let laneWidth = (width - CGFloat(p.lanes - 1) * 4) / CGFloat(p.lanes)
        let x = gutter + CGFloat(p.lane) * (laneWidth + 4)
        let h = max(minBlockHeight, CGFloat(b.durationMinutes) * pxPerMin)
        let color = state.course(b.courseID)?.color ?? .accentColor
        return Button { editing = b } label: {
            HStack(alignment: .top, spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(b.title.isEmpty ? "Block" : b.title)
                        .font(.caption.weight(.medium)).lineLimit(h > 40 ? 2 : 1)
                        .strikethrough(b.done, color: .secondary)
                        .foregroundStyle(b.done ? .secondary : .primary)
                    if h > 34 {
                        Text("\(b.startString) – \(b.endString)")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if b.done { Image(systemName: "checkmark.circle.fill").font(.caption2).foregroundStyle(Color.dsDone) }
            }
            .padding(.horizontal, 5).padding(.vertical, 3)
            .frame(width: laneWidth, height: h, alignment: .topLeading)
            .background(color.opacity(b.done ? 0.06 : 0.16), in: RoundedRectangle(cornerRadius: DS.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(color.opacity(0.35), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(b.done ? "Mark not done" : "Mark done") { toggleDone(b) }
            Divider()
            Button("Delete", role: .destructive) { state.deleteTimeBlock(b.id) }
        }
        .offset(x: x, y: y(b.startMinutes, lo: lo))
    }

    private func nowLine(lo: Int, hi: Int, width: CGFloat) -> some View {
        let c = cal.dateComponents([.hour, .minute], from: .now)
        let now = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return Group {
            if now >= lo && now <= hi {
                HStack(spacing: 0) {
                    Circle().fill(.red).frame(width: 6, height: 6)
                    Rectangle().fill(.red).frame(height: 1)
                }
                .padding(.leading, gutter - 3)
                .offset(y: y(now, lo: lo))
            }
        }
    }

    // MARK: Unscheduled work → drop onto the day

    private var unscheduledMenu: some View {
        Menu {
            let assigns = openAssignments
            let todos = openTodos
            if assigns.isEmpty && todos.isEmpty {
                Text("Nothing open to schedule")
            }
            if !assigns.isEmpty {
                Section("Assignments") {
                    ForEach(assigns) { a in
                        Button { scheduleAssignment(a) } label: {
                            Label(a.title.isEmpty ? "Untitled" : a.title, systemImage: "checklist")
                        }
                    }
                }
            }
            if !todos.isEmpty {
                Section("To-Do") {
                    ForEach(todos) { t in
                        Button { scheduleTodo(t) } label: {
                            Label(t.text.isEmpty ? "Task" : t.text, systemImage: "checkmark.circle")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "tray.and.arrow.down")
        }
        .menuIndicator(.hidden)
        .help("Plan an open assignment or to-do onto this day")
    }

    private var openAssignments: [Assignment] {
        state.data.assignments.filter { $0.status != .done }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
            .prefix(12).map { $0 }
    }
    private var openTodos: [TodoItem] {
        state.data.todos.filter { !$0.done }
            .sorted { $0.priority > $1.priority }
            .prefix(12).map { $0 }
    }

    // MARK: Actions

    private func shift(_ days: Int) {
        withAnimation { day = cal.date(byAdding: .day, value: days, to: day) ?? day }
    }

    /// A sensible default start: next hour if today (min 9am), else 9am, bumped past any
    /// block already covering that slot, capped so it stays on the timeline.
    private func defaultStart() -> Int {
        var start: Int
        if isToday {
            let c = cal.dateComponents([.hour, .minute], from: .now)
            let now = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            start = max(9 * 60, ((now / 60) + 1) * 60)
        } else {
            start = 9 * 60
        }
        // Bump past overlaps.
        for b in blocks.sorted(by: { $0.startMinutes < $1.startMinutes })
        where start < b.endMinutes && start + 60 > b.startMinutes {
            start = b.endMinutes
        }
        return min(start, 22 * 60)
    }

    private func addBlock() {
        let s = defaultStart()
        editing = TimeBlock(day: day, startMinutes: s, endMinutes: min(s + 60, 24 * 60))
    }

    private func scheduleAssignment(_ a: Assignment) {
        let s = defaultStart()
        state.upsertTimeBlock(TimeBlock(title: a.title.isEmpty ? "Assignment" : a.title,
                                        day: day, startMinutes: s, endMinutes: min(s + 60, 24 * 60),
                                        courseID: a.courseID, assignmentID: a.id))
    }
    private func scheduleTodo(_ t: TodoItem) {
        let s = defaultStart()
        state.upsertTimeBlock(TimeBlock(title: t.text.isEmpty ? "Task" : t.text,
                                        day: day, startMinutes: s, endMinutes: min(s + 60, 24 * 60),
                                        courseID: t.courseID, todoID: t.id))
    }
    private func toggleDone(_ b: TimeBlock) {
        var x = b; x.done.toggle(); state.upsertTimeBlock(x)
    }
}

// MARK: - Editor

struct TimeBlockEditor: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var draft: TimeBlock
    private let isNew: Bool

    init(block: TimeBlock) {
        _draft = State(initialValue: block)
        isNew = AppState.current?.timeBlocks.contains(where: { $0.id == block.id }) != true
    }

    var body: some View {
        VStack(spacing: 0) {
            SubHeader(isNew ? "New Block" : "Block") {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        state.deleteTimeBlock(draft.id); dismiss()
                    }
                }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("What are you working on?", text: $draft.title)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Text("Course").font(.caption).foregroundStyle(.secondary)
                        CoursePicker(courseID: $draft.courseID)
                        Spacer()
                        AssignmentPicker(assignmentID: $draft.assignmentID)
                    }
                    HStack {
                        timePicker("Start", $draft.startMinutes)
                        timePicker("End", $draft.endMinutes)
                    }
                    Toggle("Done", isOn: $draft.done)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Notes").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $draft.notes)
                            .font(.callout).frame(minHeight: 70)
                            .padding(4)
                            .background(.background.secondary, in: RoundedRectangle(cornerRadius: DS.Radius.control))
                    }
                }.padding(14)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }.padding(12)
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
        // Keep end after start (min 15 min).
        if draft.endMinutes <= draft.startMinutes { draft.endMinutes = min(24 * 60, draft.startMinutes + 15) }
        state.upsertTimeBlock(draft)
        dismiss()
    }
}
