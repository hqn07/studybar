import SwiftUI
import AppKit

func gstr(_ d: Double) -> String { String(format: "%g", d) }

// MARK: - Course grade / GPA helpers (shared by the hub)

/// Live current grade % for a course from its graded components, if any.
func courseCurrentPct(_ cid: UUID, _ data: AppData) -> Double? {
    let its = (data.gradeItems ?? []).filter { $0.courseID == cid && $0.graded }
    let w = its.reduce(0) { $0 + $1.weight }
    guard w > 0 else { return nil }
    return its.reduce(0) { $0 + $1.weight * $1.score / 100 } / w * 100
}
func gpaPoints(_ pct: Double) -> Double {
    switch pct {
    case 93...: 4.0; case 90..<93: 3.7; case 87..<90: 3.3; case 83..<87: 3.0
    case 80..<83: 2.7; case 77..<80: 2.3; case 73..<77: 2.0; case 70..<73: 1.7
    case 67..<70: 1.3; case 63..<67: 1.0; case 60..<63: 0.7; default: 0.0
    }
}
func letterForPct(_ pct: Double) -> String {
    switch pct {
    case 93...: "A"; case 90..<93: "A−"; case 87..<90: "B+"; case 83..<87: "B"; case 80..<83: "B−"
    case 77..<80: "C+"; case 73..<77: "C"; case 70..<73: "C−"; case 67..<70: "D+"; case 63..<67: "D"
    case 60..<63: "D−"; default: "F"
    }
}
/// Credit-weighted GPA over the given courses, using live % where available else the typed letter.
func termGPA(_ courses: [Course], _ data: AppData) -> Double? {
    var pts = 0.0, cred = 0.0
    for c in courses {
        let p: Double?
        if let pct = courseCurrentPct(c.id, data) { p = gpaPoints(pct) }
        else if let g = c.gradePoints { p = g } else { p = nil }
        if let p { pts += p * c.credits; cred += c.credits }
    }
    return cred > 0 ? pts / cred : nil
}

struct CoursesView: View {
    @EnvironmentObject var state: AppState
    @State private var editing: Course?
    @State private var detailID: UUID?
    @State private var expandedTerms: Set<String> = []
    @State private var archiving = false
    @State private var nextTerm = ""
    @State private var pastPrompt = false
    @State private var pastTerm = ""
    @State private var editingTerm = false

    private var currentTerm: String { state.data.termName }

    // Term timeline (merged in from the old Semester module).
    private var termStart: Date? { state.data.termStart }
    private var termEnd: Date? { state.data.termEnd }
    private var termProgress: Double {
        guard let s = termStart, let e = termEnd, e > s else { return 0 }
        return min(1, max(0, Date().timeIntervalSince(s) / e.timeIntervalSince(s)))
    }
    private var weeksLeft: Int? {
        guard let e = termEnd else { return nil }
        let days = Calendar.current.dateComponents([.day], from: .now, to: e).day ?? 0
        return max(0, Int(ceil(Double(days) / 7)))
    }
    private func isCurrent(_ c: Course) -> Bool { c.term.isEmpty || c.term == currentTerm }
    private var currentCourses: [Course] { state.data.courses.filter { isCurrent($0) } }
    private var pastGroups: [(term: String, courses: [Course])] {
        let past = state.data.courses.filter { !$0.term.isEmpty && $0.term != currentTerm }
        return Dictionary(grouping: past, by: \.term).keys.sorted { termKey($0) > termKey($1) }
            .map { ($0, Dictionary(grouping: past, by: \.term)[$0]!) }
    }
    /// Sort key: year * 10 + season rank (Fall newest within a year).
    private func termKey(_ t: String) -> Int {
        let year = Int(t.components(separatedBy: CharacterSet.decimalDigits.inverted).first { $0.count == 4 } ?? "0") ?? 0
        let low = t.lowercased()
        let season = low.contains("fall") ? 3 : low.contains("summer") ? 2 : low.contains("spring") ? 1 : 0
        return year * 10 + season
    }

    var body: some View {
        NavigationStack {
            ModulePane(title: "Courses") {
                Menu {
                    Button { editing = Course(name: "", term: currentTerm) } label: { Label("Add course", systemImage: "plus") }
                    Button { pastTerm = ""; pastPrompt = true } label: { Label("Add past course…", systemImage: "clock.arrow.circlepath") }
                    Divider()
                    Button { editingTerm = true } label: { Label("Set term dates…", systemImage: "calendar.badge.plus") }
                    if !currentCourses.isEmpty {
                        Button { nextTerm = ""; archiving = true } label: { Label("Start next term…", systemImage: "arrow.right.circle") }
                    }
                } label: { Image(systemName: "plus") }.menuStyle(.borderlessButton).fixedSize()
            } content: {
                if state.data.courses.isEmpty {
                    EmptyState(symbol: "graduationcap", title: "No courses",
                               subtitle: "Add your classes — assignments, notes and links attach to them.")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: DS.Space.l) {
                            heroHeader
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: DS.Space.m),
                                                GridItem(.flexible(), spacing: DS.Space.m)], spacing: DS.Space.m) {
                                ForEach(currentCourses) { c in
                                    CourseCard(course: c) { detailID = c.id }
                                }
                            }
                            if !pastGroups.isEmpty { pastSection }
                        }.padding(DS.Space.l)
                    }
                }
            }
            .navigationDestination(item: $editing) { CourseEditor(course: $0) }
            .navigationDestination(item: $detailID) { CourseDetailView(courseID: $0) }
            .navigationDestination(isPresented: $editingTerm) { TermEditor() }
        }
        .overlay { if archiving { archiveCard } }
        .overlay { if pastPrompt { pastCard } }
    }

    private var pastCard: some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea().onTapGesture { pastPrompt = false }
            VStack(spacing: DS.Space.l) {
                Text("Add past course").font(.headline)
                Text("Which term is it from?").font(.caption).foregroundStyle(.secondary)
                TextField("Term (e.g. Fall 2025)", text: $pastTerm).textFieldStyle(.roundedBorder).frame(width: 220)
                    .onSubmit(continuePast)
                HStack(spacing: DS.Space.m) {
                    Button("Cancel") { pastPrompt = false }.keyboardShortcut(.cancelAction)
                    Button("Continue") { continuePast() }.buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(pastTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20).frame(maxWidth: 300)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.modal))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.modal).stroke(.separator)).shadow(radius: 20)
        }
    }
    private func continuePast() {
        let t = pastTerm.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        pastPrompt = false
        editing = Course(name: "", term: t)
    }

    // MARK: hero

    private var heroHeader: some View {
        let gpa = termGPA(currentCourses, state.data)
        let overdue = state.data.assignments.filter { $0.status != .done && $0.isOverdue && isCurrentCourse($0.courseID) }.count
        let credits = currentCourses.reduce(0) { $0 + $1.credits }
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Text(currentTerm.isEmpty ? "This term" : currentTerm).font(.title3.weight(.semibold))
                Spacer()
            }
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(spacing: DS.Space.l) {
                    heroStat(gpa.map { String(format: "%.2f", $0) } ?? "—", "GPA")
                    heroSep
                    heroStat("\(currentCourses.count)", "courses")
                    heroSep
                    heroStat(gstr(credits), "credits")
                    Spacer()
                    if overdue > 0 { Chip("\(overdue) overdue", .status(.now)) }
                }
                termTimeline
            }
            .padding(DS.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        }
    }

    /// Term progress — folded in from the old Semester module. Shows a slim progress bar
    /// and weeks-left when the term dates are set, or a one-tap prompt to set them.
    @ViewBuilder private var termTimeline: some View {
        if let s = termStart, let e = termEnd, e > s {
            Divider()
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                HStack {
                    Text("\(s.formatted(date: .abbreviated, time: .omitted)) – \(e.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    if let w = weeksLeft {
                        Text(w == 0 ? "term over" : "\(w) week\(w == 1 ? "" : "s") left")
                            .font(.caption2.weight(.medium)).foregroundStyle(.tint)
                    }
                }
                ProgressView(value: termProgress)
            }
        } else {
            Divider()
            Button { editingTerm = true } label: {
                Label("Set term dates", systemImage: "calendar.badge.plus").font(.caption)
            }.buttonStyle(.borderless)
        }
    }
    private func isCurrentCourse(_ id: UUID?) -> Bool {
        guard let id, let c = state.data.courses.first(where: { $0.id == id }) else { return true }
        return isCurrent(c)
    }
    private func heroStat(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(v).font(.title2.weight(.semibold).monospacedDigit())
            Text(l).font(.caption2).foregroundStyle(.secondary)
        }
    }
    private var heroSep: some View { Rectangle().fill(.separator).frame(width: 0.5, height: 30) }

    // MARK: past terms

    private var pastSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionHeader(title: "Past terms")
            ForEach(pastGroups, id: \.term) { g in termDisclosure(g.term, g.courses) }
        }
    }
    private func termDisclosure(_ term: String, _ courses: [Course]) -> some View {
        let open = expandedTerms.contains(term)
        let gpa = termGPA(courses, state.data)
        let credits = courses.reduce(0) { $0 + $1.credits }
        return VStack(spacing: 0) {
            Button { if open { expandedTerms.remove(term) } else { expandedTerms.insert(term) } } label: {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2).foregroundStyle(.secondary).frame(width: 10)
                    Text(term).fontWeight(.medium)
                    Spacer()
                    Text("\(gpa.map { String(format: "GPA %.2f", $0) } ?? "") · \(gstr(credits)) cr")
                        .font(.caption).foregroundStyle(.secondary)
                }.contentShape(Rectangle()).padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.m)
            }.buttonStyle(.plain)
            if open {
                Divider().padding(.leading, DS.Space.l)
                ForEach(courses) { c in
                    Button { detailID = c.id } label: {
                        HStack(spacing: DS.Space.s) {
                            Circle().fill(c.color).frame(width: 8, height: 8)
                            Text(c.name.isEmpty ? "Untitled" : c.name).font(.callout).lineLimit(1)
                            if !c.code.isEmpty { Text(c.code).font(.caption2).foregroundStyle(.secondary) }
                            Spacer()
                            Text(c.grade.isEmpty ? "—" : c.grade).font(.callout.weight(.medium)).foregroundStyle(c.color)
                        }.contentShape(Rectangle()).padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.s)
                    }.buttonStyle(.plain)
                }
            }
        }
        .background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }

    // MARK: archive

    private var archiveCard: some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea().onTapGesture { archiving = false }
            VStack(spacing: DS.Space.l) {
                Text("Start next term").font(.headline)
                Text("Archives \(currentCourses.count) current course\(currentCourses.count == 1 ? "" : "s") under “\(currentTerm.isEmpty ? "This term" : currentTerm)” and starts a new one. Nothing is deleted.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                TextField("New term (e.g. Spring 2027)", text: $nextTerm).textFieldStyle(.roundedBorder).frame(width: 220)
                HStack(spacing: DS.Space.m) {
                    Button("Cancel") { archiving = false }.keyboardShortcut(.cancelAction)
                    Button("Start term") { startNextTerm() }.buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(nextTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20).frame(maxWidth: 300)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.modal))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.modal).stroke(.separator)).shadow(radius: 20)
        }
    }
    private func startNextTerm() {
        let new = nextTerm.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty else { return }
        let label = currentTerm.isEmpty ? "Past term" : currentTerm
        state.withUndo("Started \(new)") {
            for i in state.data.courses.indices where isCurrent(state.data.courses[i]) {
                state.data.courses[i].term = label       // stamp the outgoing term
            }
            state.data.termName = new
        }
        archiving = false
    }
}

/// Direction-A course card: color band, code, name, live grade ring, next-class + due footer.
struct CourseCard: View {
    @EnvironmentObject var state: AppState
    let course: Course
    let onOpen: () -> Void

    private var pct: Double? { courseCurrentPct(course.id, state.data) }
    private var open: [Assignment] { state.data.assignments.filter { $0.courseID == course.id && $0.status != .done } }
    private var overdue: Int { open.filter { $0.isOverdue }.count }
    private var dueSoon: Int { open.filter { ($0.daysUntilDue ?? 99) >= 0 && ($0.daysUntilDue ?? 99) <= 7 }.count }
    private var notesCount: Int { state.data.notes.filter { $0.courseID == course.id }.count }

    /// Next meeting this week for the course: today's upcoming one, else the soonest weekday.
    private var nextMeeting: String? {
        let cal = Calendar.current
        let today = cal.component(.weekday, from: .now)
        let mins = cal.component(.hour, from: .now) * 60 + cal.component(.minute, from: .now)
        let cs = state.data.classes.filter { $0.courseID == course.id }
        guard !cs.isEmpty else { return nil }
        // Expand each class into a per-weekday occurrence (MWF → three).
        let occ = cs.flatMap { c in c.weekdays.map { (wd: $0, c: c) } }
        if let now = occ.filter({ $0.wd == today && $0.c.endMinutes >= mins }).sorted(by: { $0.c.startMinutes < $1.c.startMinutes }).first {
            let d = now.c.startMinutes - mins
            return now.c.startMinutes <= mins ? "now" : (d < 60 ? "in \(d)m" : now.c.startString)
        }
        let up = occ.sorted { ($0.wd, $0.c.startMinutes) < ($1.wd, $1.c.startMinutes) }
        if let n = up.first(where: { $0.wd > today }) ?? up.first {
            return "\(weekdaySymbols[n.wd]) \(n.c.startString)"
        }
        return nil
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: DS.Space.s) {
                    VStack(alignment: .leading, spacing: 1) {
                        if !course.code.isEmpty { Text(course.code).font(.caption.weight(.medium)).foregroundStyle(course.color) }
                        Text(course.name.isEmpty ? "Untitled" : course.name).font(.callout.weight(.medium)).lineLimit(2)
                        Text([course.instructor, "\(gstr(course.credits)) cr"].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: DS.Space.xs)
                    gradeRing
                }
                HStack(spacing: DS.Space.s) {
                    if overdue > 0 { Chip("\(overdue) overdue", .status(.now)) }
                    else if let m = nextMeeting { Chip(m, .status(.neutral), systemImage: "clock") }
                    if overdue == 0 && dueSoon > 0 { Text("\(dueSoon) due").font(.caption2).foregroundStyle(.secondary) }
                    Spacer()
                    if notesCount > 0 {
                        Label("\(notesCount)", systemImage: "note.text").font(.caption2).foregroundStyle(.secondary)
                    }
                }.padding(.top, DS.Space.m)
            }
            .padding(DS.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(course.color).frame(width: 3).padding(.vertical, DS.Space.m)
            }
        }.buttonStyle(.plain)
    }

    private var gradeRing: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 4).frame(width: 40, height: 40)
            if let p = pct {
                Circle().trim(from: 0, to: min(1, p / 100)).stroke(course.color, style: .init(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90)).frame(width: 40, height: 40)
            }
            Text(pct.map { letterForPct($0) } ?? (course.grade.isEmpty ? "—" : course.grade))
                .font(.caption.weight(.semibold)).foregroundStyle(pct != nil ? course.color : .secondary)
        }
    }
}

struct CourseDetailView: View {
    @EnvironmentObject var state: AppState
    let courseID: UUID
    @State private var editing: Course?
    @State private var editingAssignment: Assignment?
    @AppStorage("gradeTarget") private var gradeTarget = 90.0
    @State private var syllabusDraft: SyllabusDraft?
    @State private var syllabusExtracting = false
    @State private var extractStart: Date?
    @State private var syllabusError: String?

    private var course: Course? { state.data.courses.first { $0.id == courseID } }
    private var assignments: [Assignment] {
        state.data.assignments.filter { $0.courseID == courseID && $0.status != .done }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }
    private var classes: [ClassSession] {
        state.data.classes.filter { $0.courseID == courseID }
            .sorted { ($0.weekdays.first ?? 0, $0.startMinutes) < ($1.weekdays.first ?? 0, $1.startMinutes) }
    }
    private var links: [QuickLink] { state.data.links.filter { $0.courseID == courseID } }
    private var notes: [Note] { state.data.notes.filter { $0.courseID == courseID } }
    private var reading: [ReadingItem] { state.data.reading.filter { $0.courseID == courseID } }
    private var timeEntries: [TimeEntry] { state.data.timeEntries.filter { $0.courseID == courseID } }
    private var weekMinutes: Int { timeEntries.filter { StudyStats.isThisWeek($0.date) }.reduce(0) { $0 + $1.seconds } / 60 }
    private var totalMinutes: Int { timeEntries.reduce(0) { $0 + $1.seconds } / 60 }
    private var courseGradeItems: [GradeItem] { state.gradeItems.filter { $0.courseID == courseID } }

    var body: some View {
        VStack(spacing: 0) {
            SubHeader(course?.name ?? "Course") {
                if let c = course { Button { editing = c } label: { Image(systemName: "pencil") }.buttonStyle(.borderless) }
            }
            Divider()
            if let c = course {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        headerCard(c)
                        effortCard(c)
                        gradeCard()
                        syllabusCard(c)
                        if !assignments.isEmpty {
                            section("OPEN ASSIGNMENTS (\(assignments.count))") {
                                ForEach(assignments) { a in assignmentRow(a) }
                            }
                        }
                        if !classes.isEmpty {
                            section("CLASSES") { ForEach(classes) { cl in classRow(cl) } }
                        }
                        if !links.isEmpty {
                            section("LINKS") { ForEach(links) { l in linkRow(l) } }
                        }
                        if !reading.isEmpty {
                            section("READING") { ForEach(reading) { r in readingRow(r) } }
                        }
                        if !notes.isEmpty {
                            section("NOTES (\(notes.count))") {
                                ForEach(notes.prefix(5)) { n in
                                    Text(n.title.isEmpty ? "Untitled" : n.title).font(.callout)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(9).background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                                }
                                Button("Open in Notes") { state.selectedModuleID = "notes" }.font(.caption).buttonStyle(.borderless)
                            }
                        }
                    }.padding(14)
                }
            } else {
                EmptyState(symbol: "graduationcap", title: "Course removed", subtitle: "")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("").toolbar(.hidden, for: .windowToolbar)
        .navigationDestination(item: $editing) { CourseEditor(course: $0) }
        .navigationDestination(item: $editingAssignment) { AssignmentEditor(assignment: $0) }
    }

    private func headerCard(_ c: Course) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 4).fill(c.color).frame(width: 6, height: 54)
            VStack(alignment: .leading, spacing: 3) {
                Text([c.code, c.instructor].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    if !c.room.isEmpty { Label(c.room, systemImage: "mappin.and.ellipse").font(.caption) }
                    Label("\(c.credits, specifier: "%g") cr", systemImage: "number").font(.caption)
                }.foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("None") { setGrade("") }
                Divider()
                ForEach(GradeScale.letters, id: \.self) { g in Button(g) { setGrade(g) } }
            } label: {
                VStack(spacing: 0) {
                    Text(c.grade.isEmpty ? "—" : c.grade).font(.title2.bold()).foregroundStyle(c.color)
                    Text("grade").font(.caption2).foregroundStyle(.secondary)
                }
            }.menuStyle(.borderlessButton).fixedSize()
        }
        .padding(12).background(c.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    private func assignmentRow(_ a: Assignment) -> some View {
        HStack(spacing: 8) {
            Button { toggleDone(a) } label: { Image(systemName: "circle").foregroundStyle(.secondary) }.buttonStyle(.plain)
            Button { editingAssignment = a } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(a.title.isEmpty ? "Untitled" : a.title).fontWeight(.medium)
                    if let d = a.due { Text(a.isOverdue ? "Overdue · \(d.dayMonth)" : "Due \(d.dayMonth)").font(.caption2).foregroundStyle(a.isOverdue ? .red : .secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(9).background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }
    private func classRow(_ cl: ClassSession) -> some View {
        HStack {
            Text(cl.daysShort).font(.caption.bold()).frame(width: 42, alignment: .leading)
            Text("\(cl.startString) – \(cl.endString)").font(.caption)
            if !cl.room.isEmpty { Text("· \(cl.room)").font(.caption2).foregroundStyle(.secondary) }
            Spacer()
        }.padding(9).background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }
    private func linkRow(_ l: QuickLink) -> some View {
        Button { openURL(l.url) } label: {
            HStack { Image(systemName: l.symbol.isEmpty ? "link" : l.symbol).foregroundStyle(.tint)
                Text(l.title.isEmpty ? l.url : l.title); Spacer(); Image(systemName: "arrow.up.right.square").font(.caption) }
                .padding(9).background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        }.buttonStyle(.plain)
    }
    private func readingRow(_ r: ReadingItem) -> some View {
        HStack(spacing: 8) {
            Text(r.title).fontWeight(.medium).lineLimit(1)
            Spacer()
            Text("\(Int(r.progress * 100))%").font(.caption2).foregroundStyle(.secondary)
        }.padding(9).background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }

    private func effortCard(_ c: Course) -> some View {
        HStack(spacing: 16) {
            statBlock("\(weekMinutes)m", "this week")
            statBlock(totalMinutes >= 60 ? "\(totalMinutes / 60)h \(totalMinutes % 60)m" : "\(totalMinutes)m", "total logged")
            Spacer()
            Button {
                state.pomodoro.startFocus(label: c.name, courseID: c.id)
                state.selectedModuleID = "timefocus"
            } label: { Label("Focus", systemImage: "timer") }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .help("Start a focus session logged to this course")
        }
        .padding(12)
        .background(.sbSurface, in: RoundedRectangle(cornerRadius: 12))
    }
    private func statBlock(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(v).font(.title3.weight(.semibold))
            Text(l).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Grade what-if (folded in from the retired Grade Calc module)

    private var gradedWeight: Double { courseGradeItems.filter(\.graded).reduce(0) { $0 + $1.weight } }
    private var ungradedWeight: Double { courseGradeItems.filter { !$0.graded }.reduce(0) { $0 + $1.weight } }
    private var totalWeight: Double { courseGradeItems.reduce(0) { $0 + $1.weight } }
    private var earnedPoints: Double { courseGradeItems.filter(\.graded).reduce(0) { $0 + $1.weight * $1.score / 100 } }
    private var currentPct: Double { gradedWeight > 0 ? earnedPoints / gradedWeight * 100 : 0 }
    /// Score needed on the remaining (ungraded) weight to reach the target overall.
    private var neededOnRest: Double? {
        guard ungradedWeight > 0 else { return nil }
        return (gradeTarget - earnedPoints) / ungradedWeight * 100
    }
    private var neededMessage: (text: String, color: Color)? {
        guard let need = neededOnRest else { return nil }
        if need <= 0 { return ("Already secured — even a 0% on the rest keeps you at target.", .green) }
        if need > 100 { return ("Out of reach on the remaining \(Int(ungradedWeight))% — the most you can finish with is \(String(format: "%.1f", earnedPoints + ungradedWeight))%.", .red) }
        return (String(format: "Need %.1f%% on the remaining %d%% to hit %d%%.", need, Int(ungradedWeight), Int(gradeTarget)), .primary)
    }

    @ViewBuilder private func gradeCard() -> some View {
        section("GRADE") {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                Text(gradedWeight > 0 ? String(format: "%.1f%%", currentPct) : "—")
                    .font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText()).animation(.snappy, value: currentPct)
                if gradedWeight > 0 { Text(letterForPct(currentPct)).font(.title3.bold()).foregroundStyle(.tint) }
                Spacer()
                Text(gradedWeight > 0 ? "\(Int(gradedWeight))% of grade in" : "no graded work yet")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if totalWeight > 0 && totalWeight != 100 {
                Label("Weights sum to \(Int(totalWeight))% — usually 100%.", systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange)
            }

            // What-if target
            HStack {
                Text("Target").font(.caption).foregroundStyle(.secondary)
                Slider(value: $gradeTarget, in: 50...100, step: 1)
                Text("\(Int(gradeTarget))%").font(.caption.monospacedDigit()).foregroundStyle(.tint).frame(width: 34)
            }
            if let m = neededMessage {
                Label(m.text, systemImage: "target").font(.caption).foregroundStyle(m.color)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !courseGradeItems.isEmpty {
                Text("Mark a component “not taken yet” to compute what you need on it.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            // Editable components
            ForEach(courseGradeItems) { g in gradeItemRow(g) }
            Button { state.gradeItems.append(GradeItem(courseID: courseID)) } label: {
                Label("Add component", systemImage: "plus").font(.caption)
            }.buttonStyle(.borderless)
        }
    }

    private func gradeItemRow(_ item: GradeItem) -> some View {
        let b = Binding<GradeItem>(
            get: { state.gradeItems.first { $0.id == item.id } ?? item },
            set: { nv in if let i = state.gradeItems.firstIndex(where: { $0.id == item.id }) { state.gradeItems[i] = nv } })
        return VStack(spacing: 6) {
            HStack(spacing: DS.Space.s) {
                TextField("Component (e.g. Midterm)", text: b.name).textFieldStyle(.plain).fontWeight(.medium)
                Button(role: .destructive) { state.withUndo("Deleted grade component") { state.gradeItems.removeAll { $0.id == item.id } } } label: {
                    Image(systemName: "trash")
                }.buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: DS.Space.m) {
                gradeField("Weight", b.weight)
                if item.graded { gradeField("Score", b.score) }
                Toggle("Taken", isOn: b.graded).toggleStyle(.button).controlSize(.small).font(.caption)
            }
        }
        .padding(DS.Space.m).background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }

    private func gradeField(_ label: String, _ value: Binding<Double>) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            TextField(label, value: value, format: .number).textFieldStyle(.roundedBorder)
                .frame(width: 52).multilineTextAlignment(.trailing)
            Text("%").font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Syllabus

    @ViewBuilder private func syllabusCard(_ c: Course) -> some View {
        section("SYLLABUS") {
            if let syl = c.syllabus {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "doc.text.fill").foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(syl.fileName.isEmpty ? "Syllabus" : syl.fileName).font(.callout.weight(.medium)).lineLimit(1)
                        Text("Added \(syl.importedAt.dayMonth)").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { SyllabusStore.open(syl) } label: { Image(systemName: "arrow.up.right.square") }
                        .buttonStyle(.borderless).help("Open the syllabus")
                    Menu {
                        Button { attachSyllabus(c) } label: { Label("Replace…", systemImage: "arrow.triangle.2.circlepath") }
                        Button(role: .destructive) { removeSyllabus(c) } label: { Label("Remove", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis") }.buttonStyle(.borderless).fixedSize()
                }
                .padding(9).background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))

                if syllabusExtracting {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        let secs = extractStart.map { max(0, Int(ctx.date.timeIntervalSince($0))) } ?? 0
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Reading the syllabus… \(secs)s. This takes 1–3 min on a local model — stay on this page.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else if let d = syllabusDraft {
                    draftReview(c, d)
                } else if let err = syllabusError {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(err).font(.caption).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    Button { syllabusError = nil; extractSyllabus(c, datesOnly: true) } label: { Label("Try dates only", systemImage: "arrow.clockwise").font(.caption) }
                        .buttonStyle(.bordered).controlSize(.small)
                } else if !syl.extracted {
                    HStack(spacing: DS.Space.s) {
                        Button { extractSyllabus(c) } label: { Label("Extract details", systemImage: "sparkles").font(.caption) }
                        Button { extractSyllabus(c, datesOnly: true) } label: { Label("Dates only (faster)", systemImage: "calendar.badge.clock").font(.caption) }
                    }.buttonStyle(.bordered).controlSize(.small).disabled(!AIConfig.isReady)
                    if !AIConfig.isReady {
                        Text("Set up an engine in Settings ▸ Intelligence to pull out grading, dates and policies.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                if !syl.keyDates.isEmpty { keyDatesView(c, syl.keyDates) }
                if !syl.officeHours.isEmpty { fieldRow("Office hours", syl.officeHours) }
                if !syl.textbooks.isEmpty { fieldRow("Textbooks", syl.textbooks.joined(separator: "\n")) }
                if !syl.policies.isEmpty { fieldRow("Policies", syl.policies) }
            } else {
                Button { attachSyllabus(c) } label: { Label("Attach syllabus", systemImage: "paperclip").font(.caption) }
                    .buttonStyle(.bordered).controlSize(.small)
                Text("Keep the syllabus here — StudyBar can pull out the grading breakdown, key dates and policies.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func fieldRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            Text(value).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9).background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }

    private func keyDatesView(_ c: Course, _ dates: [SyllabusDate]) -> some View {
        let dated = dates.filter { $0.date != nil }
        return VStack(alignment: .leading, spacing: 4) {
            Text("KEY DATES").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            ForEach(dates) { d in
                HStack {
                    Text(d.label).font(.caption)
                    Spacer()
                    Text(d.date?.dayMonth ?? "—").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if !dated.isEmpty {
                Button { addDatesToAssignments(c, dated) } label: {
                    Label("Add \(dated.count) dated item\(dated.count == 1 ? "" : "s") to Assignments", systemImage: "calendar.badge.plus").font(.caption2)
                }.buttonStyle(.borderless)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9).background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }

    /// Inline propose→accept of the AI-extracted syllabus details.
    private func draftReview(_ c: Course, _ d: SyllabusDraft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PROPOSED FROM SYLLABUS").font(.system(size: 9, weight: .bold)).foregroundStyle(.tint)
            if !d.grading.isEmpty {
                Text("Grading → \(d.grading.count) component\(d.grading.count == 1 ? "" : "s"): "
                     + d.grading.map { "\($0.name) \(Int($0.weight))%" }.joined(separator: ", "))
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            if !d.keyDates.isEmpty { Text("Key dates → \(d.keyDates.count)").font(.caption) }
            if !d.textbooks.isEmpty { Text("Textbooks → \(d.textbooks.count)").font(.caption) }
            if !d.officeHours.isEmpty { Text("Office hours").font(.caption) }
            if !d.policies.isEmpty { Text("Policies").font(.caption) }
            HStack(spacing: DS.Space.m) {
                Button("Apply") { acceptDraft(c, d) }.buttonStyle(.borderedProminent).controlSize(.small)
                Button("Discard") { syllabusDraft = nil }.buttonStyle(.bordered).controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9).background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }

    private func attachSyllabus(_ c: Course) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .plainText, .text, .rtf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, let item = SyllabusStore.attach(url, courseID: c.id) else { return }
        updateCourse { $0.syllabus = item }
        syllabusDraft = nil
    }
    private func removeSyllabus(_ c: Course) {
        if let s = c.syllabus { SyllabusStore.remove(s) }
        updateCourse { $0.syllabus = nil }
        syllabusDraft = nil
    }
    private func extractSyllabus(_ c: Course, datesOnly: Bool = false) {
        guard let syl = c.syllabus, AIConfig.isReady else { return }
        let text = SyllabusStore.text(syl)
        guard text.count >= 40 else {
            syllabusError = "Couldn't read text from this syllabus — it may be a scanned image (OCR isn't supported yet). Try a text-based PDF."
            return
        }
        syllabusError = nil; syllabusExtracting = true; extractStart = Date()
        let provider = AIService.makeProvider()
        Task { @MainActor in
            let draft = await SyllabusExtract.run(text, provider: provider, datesOnly: datesOnly)
            syllabusExtracting = false; extractStart = nil
            if let draft {
                syllabusDraft = draft
            } else {
                syllabusError = "The AI didn't return usable details (it may have timed out or replied with unusable text). Make sure Ollama is running with \(AIConfig.ollamaModel), then try again — Dates only is faster. See Settings ▸ Diagnostics for details."
            }
        }
    }
    private func acceptDraft(_ c: Course, _ d: SyllabusDraft) {
        state.withUndo("Applied syllabus") {
            for g in d.grading {
                state.gradeItems.append(GradeItem(courseID: c.id, name: g.name, weight: g.weight, score: 0, graded: false))
            }
            if let i = state.data.courses.firstIndex(where: { $0.id == c.id }) {
                state.data.courses[i].syllabus?.policies = d.policies
                state.data.courses[i].syllabus?.officeHours = d.officeHours
                state.data.courses[i].syllabus?.textbooks = d.textbooks
                state.data.courses[i].syllabus?.keyDates = d.keyDates
                state.data.courses[i].syllabus?.extracted = true
            }
        }
        syllabusDraft = nil
    }
    private func addDatesToAssignments(_ c: Course, _ dates: [SyllabusDate]) {
        state.withUndo("Added syllabus dates") {
            for d in dates where d.date != nil {
                state.data.assignments.append(Assignment(title: d.label, courseID: c.id, due: d.date))
            }
        }
    }
    private func updateCourse(_ f: (inout Course) -> Void) {
        guard let i = state.data.courses.firstIndex(where: { $0.id == courseID }) else { return }
        f(&state.data.courses[i])
    }

    @ViewBuilder private func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption2.bold()).foregroundStyle(.secondary)
            c()
        }
    }
    private func setGrade(_ g: String) {
        guard let i = state.data.courses.firstIndex(where: { $0.id == courseID }) else { return }
        state.data.courses[i].grade = g
    }
    private func toggleDone(_ a: Assignment) {
        guard let i = state.data.assignments.firstIndex(where: { $0.id == a.id }) else { return }
        state.data.assignments[i].status = .done
    }
    private func openURL(_ s: String) {
        let u = s.contains("://") ? s : "https://\(s)"
        if let url = URL(string: u) { NSWorkspace.shared.open(url) }
    }
}

struct CourseEditor: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Course
    init(course: Course) { _draft = State(initialValue: course) }

    var body: some View {
        VStack(spacing: 0) {
            SubHeader("Course") {
                Button("Delete", role: .destructive) { delete() }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                TextField("Name", text: $draft.name).textFieldStyle(.roundedBorder)
                HStack {
                    TextField("Code", text: $draft.code).textFieldStyle(.roundedBorder)
                    TextField("Room", text: $draft.room).textFieldStyle(.roundedBorder)
                }
                TextField("Instructor", text: $draft.instructor).textFieldStyle(.roundedBorder)
                TextField("Term (e.g. Fall 2026) — leave blank for the current term", text: $draft.term)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Text("Credits").font(.caption).foregroundStyle(.secondary)
                    Stepper(value: $draft.credits, in: 0...12, step: 0.5) {
                        Text("\(draft.credits, specifier: "%g")")
                    }.fixedSize()
                    Spacer()
                    Text("Grade").font(.caption).foregroundStyle(.secondary)
                    Menu {
                        Button("None") { draft.grade = "" }
                        Divider()
                        ForEach(GradeScale.letters, id: \.self) { g in Button(g) { draft.grade = g } }
                    } label: { Text(draft.grade.isEmpty ? "—" : draft.grade).frame(minWidth: 30) }.fixedSize()
                }
                Text("Color").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 7), spacing: 8) {
                    ForEach(Palette.swatches, id: \.self) { hex in
                        Button { draft.colorHex = hex } label: {
                            Circle().fill(Color(hex: hex) ?? .gray)
                                .frame(width: 24, height: 24)
                                .overlay(Circle().stroke(.primary, lineWidth: draft.colorHex == hex ? 2 : 0))
                        }.buttonStyle(.plain)
                    }
                }
            }.padding(14)
            Divider()
            HStack { Spacer(); Button("Cancel") { dismiss() }
                Button("Save") { save() }.keyboardShortcut(.defaultAction) }.padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("")
        .toolbar(.hidden, for: .windowToolbar)
    }

    private func save() {
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty {
            state.data.courses.removeAll { $0.id == draft.id }
        } else if let i = state.data.courses.firstIndex(where: { $0.id == draft.id }) {
            state.data.courses[i] = draft
        } else {
            state.data.courses.append(draft)
        }
        dismiss()
    }
    private func delete() {
        state.withUndo("Deleted course") {
            state.data.courses.removeAll { $0.id == draft.id }
            // Detach references
            for i in state.data.assignments.indices where state.data.assignments[i].courseID == draft.id {
                state.data.assignments[i].courseID = nil
            }
            for i in state.data.notes.indices where state.data.notes[i].courseID == draft.id {
                state.data.notes[i].courseID = nil
            }
        }
        dismiss()
    }
}

struct TermEditor: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var start = Date()
    @State private var end = Date()

    var body: some View {
        VStack(spacing: 0) {
            SubHeader("Term Dates")
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                TextField("Term name (e.g. Fall 2026)", text: $name).textFieldStyle(.roundedBorder)
                DatePicker("Start", selection: $start, displayedComponents: .date)
                DatePicker("End", selection: $end, displayedComponents: .date)
            }.padding(16)
            Divider()
            HStack { Spacer(); Button("Cancel") { dismiss() }
                Button("Save") {
                    state.data.termName = name; state.data.termStart = start; state.data.termEnd = end; dismiss()
                }.keyboardShortcut(.defaultAction) }.padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("").toolbar(.hidden, for: .windowToolbar)
        .onAppear {
            name = state.data.termName
            start = state.data.termStart ?? Date()
            end = state.data.termEnd ?? Calendar.current.date(byAdding: .month, value: 4, to: Date())!
        }
    }
}
