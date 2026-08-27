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

    // Live drag state (transient; committed to the store on release).
    private enum DragKind { case move, resize }
    @State private var dragID: UUID?
    @State private var dragKind: DragKind = .move
    @State private var dragOffset: CGFloat = 0     // px moved this gesture
    @State private var dropHint: Int?              // start-minute under a tray drag

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
                Button { addBlock() } label: { Image(systemName: "plus") }
                    .help("Add a block")
            } content: {
                VStack(spacing: 0) {
                    dayBar
                    unscheduledTray
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
                    if let m = dropHint { dropIndicator(m, lo: lo, width: geo.size.width) }
                    if isToday { nowLine(lo: lo, hi: hi, width: geo.size.width) }
                }
                .frame(width: geo.size.width, height: totalHeight, alignment: .topLeading)
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { items, location in
                    dropHint = nil
                    guard let payload = items.first else { return false }
                    return scheduleFromPayload(payload, at: minutes(fromY: location.y, lo: lo))
                } isTargeted: { over in
                    if !over { dropHint = nil }
                }
            }
            .frame(height: totalHeight)
        }
    }

    private func y(_ minutes: Int, lo: Int) -> CGFloat { CGFloat(minutes - lo) * pxPerMin }
    /// Inverse of `y`: a drop/drag y-coordinate → a snapped start minute on the timeline.
    private func minutes(fromY yPos: CGFloat, lo: Int) -> Int {
        snap15(lo + Int((yPos / pxPerMin).rounded()))
    }
    private func snap15(_ m: Int) -> Int { max(0, min(24 * 60, Int((Double(m) / 15).rounded()) * 15)) }

    private func dropIndicator(_ m: Int, lo: Int, width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text(ClassSession.hm(m)).font(.caption2.bold()).foregroundStyle(.tint)
                .frame(width: gutter - 6, alignment: .trailing)
            Rectangle().fill(.tint).frame(height: 2)
        }
        .offset(y: y(m, lo: lo))
    }

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
        let dragging = dragID == b.id
        // Live preview while dragging: move shifts y, resize grows height.
        let moveDY = (dragging && dragKind == .move) ? dragOffset : 0
        let resizeDH = (dragging && dragKind == .resize) ? dragOffset : 0
        let h = max(minBlockHeight, CGFloat(b.durationMinutes) * pxPerMin + resizeDH)
        let color = state.course(b.courseID)?.color ?? .accentColor
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(b.title.isEmpty ? "Block" : b.title)
                        .font(.caption.weight(.medium)).lineLimit(h > 40 ? 2 : 1)
                        .strikethrough(b.done, color: .secondary)
                        .foregroundStyle(b.done ? .secondary : .primary)
                    if h > 34 {
                        Text(dragging ? livePreviewTime(b) : "\(b.startString) – \(b.endString)")
                            .font(.caption2).foregroundStyle(dragging ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if b.done { Image(systemName: "checkmark.circle.fill").font(.caption2).foregroundStyle(Color.dsDone) }
            }
            .padding(.horizontal, 5).padding(.vertical, 3)
            Spacer(minLength: 0)
        }
        .frame(width: laneWidth, height: h, alignment: .topLeading)
        .background(color.opacity(b.done ? 0.06 : 0.16), in: RoundedRectangle(cornerRadius: DS.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control)
            .strokeBorder(color.opacity(dragging ? 0.9 : 0.35), lineWidth: dragging ? 1.5 : 0.5))
        .overlay(alignment: .bottom) { resizeHandle(b) }
        .contentShape(Rectangle())
        .onTapGesture { editing = b }
        .gesture(moveGesture(b))
        .contextMenu {
            Button(b.done ? "Mark not done" : "Mark done") { toggleDone(b) }
            Divider()
            Button("Delete", role: .destructive) { state.deleteTimeBlock(b.id) }
        }
        .zIndex(dragging ? 10 : 0)
        .offset(x: x, y: y(b.startMinutes, lo: lo) + moveDY)
    }

    /// The 6-pt grabber at a block's bottom edge; drag it to change the end time.
    private func resizeHandle(_ b: TimeBlock) -> some View {
        Capsule().fill(.secondary.opacity(0.5))
            .frame(width: 26, height: 3).padding(.bottom, 2)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle().inset(by: -8))
            .gesture(resizeGesture(b))
    }

    private func moveGesture(_ b: TimeBlock) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { g in dragID = b.id; dragKind = .move; dragOffset = g.translation.height }
            .onEnded { g in
                let dur = b.endMinutes - b.startMinutes
                let newStart = clampStart(snap15(b.startMinutes + Int((g.translation.height / pxPerMin).rounded())), dur: dur)
                var x = b; x.startMinutes = newStart; x.endMinutes = newStart + dur
                if x.startMinutes != b.startMinutes { state.upsertTimeBlock(x) }
                resetDrag()
            }
    }
    private func resizeGesture(_ b: TimeBlock) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { g in dragID = b.id; dragKind = .resize; dragOffset = g.translation.height }
            .onEnded { g in
                let newEnd = max(b.startMinutes + 15,
                                 min(24 * 60, snap15(b.endMinutes + Int((g.translation.height / pxPerMin).rounded()))))
                var x = b; x.endMinutes = newEnd
                if x.endMinutes != b.endMinutes { state.upsertTimeBlock(x) }
                resetDrag()
            }
    }
    private func clampStart(_ start: Int, dur: Int) -> Int { max(0, min(start, 24 * 60 - dur)) }
    private func resetDrag() { dragID = nil; dragOffset = 0 }

    /// The time range a block would land at given the current live drag.
    private func livePreviewTime(_ b: TimeBlock) -> String {
        let deltaMin = Int((dragOffset / pxPerMin).rounded())
        if dragKind == .move {
            let dur = b.endMinutes - b.startMinutes
            let s = clampStart(snap15(b.startMinutes + deltaMin), dur: dur)
            return "\(ClassSession.hm(s)) – \(ClassSession.hm(s + dur))"
        } else {
            let e = max(b.startMinutes + 15, min(24 * 60, snap15(b.endMinutes + deltaMin)))
            return "\(b.startString) – \(ClassSession.hm(e))"
        }
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

    // MARK: Unscheduled work → drag (or tap) onto the day

    /// A slim strip of open assignments / to-dos. Drag a chip onto the timeline to drop
    /// it at a precise time, or tap it to schedule at the next free hour. Hidden when
    /// there's nothing open to plan.
    @ViewBuilder private var unscheduledTray: some View {
        let assigns = openAssignments, todos = openTodos
        if !(assigns.isEmpty && todos.isEmpty) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Space.s) {
                    Text("PLAN").font(.caption2.weight(.bold)).tracking(0.6).foregroundStyle(.secondary)
                    ForEach(assigns) { a in
                        trayChip(a.title.isEmpty ? "Untitled" : a.title, symbol: "checklist",
                                 color: state.course(a.courseID)?.color)
                            .onTapGesture { scheduleAssignment(a, at: defaultStart()) }
                            .draggable("a:\(a.id.uuidString)")
                    }
                    ForEach(todos) { t in
                        trayChip(t.text.isEmpty ? "Task" : t.text, symbol: "checkmark.circle",
                                 color: state.course(t.courseID)?.color)
                            .onTapGesture { scheduleTodo(t, at: defaultStart()) }
                            .draggable("t:\(t.id.uuidString)")
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, DS.Space.s)
            }
            .background(.background.secondary.opacity(0.4))
        }
    }

    private func trayChip(_ text: String, symbol: String, color: Color?) -> some View {
        HStack(spacing: 4) {
            if let color { Circle().fill(color).frame(width: 6, height: 6) }
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            Text(text).lineLimit(1)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .frame(maxWidth: 150)
        .background(.background, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .help("Drag onto the timeline, or tap to schedule")
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

    private func scheduleAssignment(_ a: Assignment, at s: Int) {
        state.upsertTimeBlock(TimeBlock(title: a.title.isEmpty ? "Assignment" : a.title,
                                        day: day, startMinutes: s, endMinutes: min(s + 60, 24 * 60),
                                        courseID: a.courseID, assignmentID: a.id))
    }
    private func scheduleTodo(_ t: TodoItem, at s: Int) {
        state.upsertTimeBlock(TimeBlock(title: t.text.isEmpty ? "Task" : t.text,
                                        day: day, startMinutes: s, endMinutes: min(s + 60, 24 * 60),
                                        courseID: t.courseID, todoID: t.id))
    }

    /// Handle a chip dropped on the timeline: create a block at the drop time from the
    /// dragged assignment/todo payload ("a:<uuid>" / "t:<uuid>").
    private func scheduleFromPayload(_ payload: String, at start: Int) -> Bool {
        let s = min(start, 24 * 60 - 15)
        if payload.hasPrefix("a:"), let id = UUID(uuidString: String(payload.dropFirst(2))),
           let a = state.data.assignments.first(where: { $0.id == id }) {
            scheduleAssignment(a, at: s); return true
        }
        if payload.hasPrefix("t:"), let id = UUID(uuidString: String(payload.dropFirst(2))),
           let t = state.data.todos.first(where: { $0.id == id }) {
            scheduleTodo(t, at: s); return true
        }
        return false
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
