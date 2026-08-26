import SwiftUI

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

    private var currentTerm: String { state.data.termName }
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
                    if !currentCourses.isEmpty {
                        Divider()
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
            HStack(spacing: DS.Space.l) {
                heroStat(gpa.map { String(format: "%.2f", $0) } ?? "—", "GPA")
                heroSep
                heroStat("\(currentCourses.count)", "courses")
                heroSep
                heroStat(gstr(credits), "credits")
                Spacer()
                if overdue > 0 { Chip("\(overdue) overdue", .status(.now)) }
            }
            .padding(DS.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: DS.Radius.card))
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
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: DS.Radius.card))
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
        if let now = cs.filter({ $0.weekday == today && $0.endMinutes >= mins }).sorted(by: { $0.startMinutes < $1.startMinutes }).first {
            let d = now.startMinutes - mins
            return now.startMinutes <= mins ? "now" : (d < 60 ? "in \(d)m" : now.startString)
        }
        let up = cs.sorted { ($0.weekday, $0.startMinutes) < ($1.weekday, $1.startMinutes) }
        if let n = up.first(where: { $0.weekday > today }) ?? up.first {
            return "\(weekdaySymbols[n.weekday]) \(n.startString)"
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
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: DS.Radius.card))
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

    private var course: Course? { state.data.courses.first { $0.id == courseID } }
    private var assignments: [Assignment] {
        state.data.assignments.filter { $0.courseID == courseID && $0.status != .done }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }
    private var classes: [ClassSession] {
        state.data.classes.filter { $0.courseID == courseID }.sorted { $0.weekday < $1.weekday || ($0.weekday == $1.weekday && $0.startMinutes < $1.startMinutes) }
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
                        if !courseGradeItems.isEmpty { gradeCard() }
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
                                        .padding(9).background(.background.secondary, in: RoundedRectangle(cornerRadius: DS.Radius.card))
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
        .padding(9).background(.background.secondary, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }
    private func classRow(_ cl: ClassSession) -> some View {
        HStack {
            Text(weekdaySymbols[cl.weekday]).font(.caption.bold()).frame(width: 34, alignment: .leading)
            Text("\(cl.startString) – \(cl.endString)").font(.caption)
            if !cl.room.isEmpty { Text("· \(cl.room)").font(.caption2).foregroundStyle(.secondary) }
            Spacer()
        }.padding(9).background(.background.secondary, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }
    private func linkRow(_ l: QuickLink) -> some View {
        Button { openURL(l.url) } label: {
            HStack { Image(systemName: l.symbol.isEmpty ? "link" : l.symbol).foregroundStyle(.tint)
                Text(l.title.isEmpty ? l.url : l.title); Spacer(); Image(systemName: "arrow.up.right.square").font(.caption) }
                .padding(9).background(.background.secondary, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        }.buttonStyle(.plain)
    }
    private func readingRow(_ r: ReadingItem) -> some View {
        HStack(spacing: 8) {
            Text(r.title).fontWeight(.medium).lineLimit(1)
            Spacer()
            Text("\(Int(r.progress * 100))%").font(.caption2).foregroundStyle(.secondary)
        }.padding(9).background(.background.secondary, in: RoundedRectangle(cornerRadius: DS.Radius.card))
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
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
    private func statBlock(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(v).font(.title3.weight(.semibold))
            Text(l).font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func gradeCard() -> some View {
        let graded = courseGradeItems.filter { $0.graded }
        let gw = graded.reduce(0.0) { $0 + $1.weight }
        section("GRADE") {
            if gw > 0 {
                let earned = graded.reduce(0.0) { $0 + $1.weight * $1.score / 100 }
                Text(String(format: "%.1f%% earned on %d%% graded", earned / gw * 100, Int(gw)))
                    .font(.callout.weight(.semibold))
            }
            ForEach(courseGradeItems) { g in
                HStack {
                    Text(g.name.isEmpty ? "Component" : g.name).font(.callout)
                    Spacer()
                    Text("\(Int(g.weight))%").font(.caption).foregroundStyle(.secondary)
                    Text(g.graded ? "\(Int(g.score))%" : "—").font(.caption.weight(.medium))
                        .frame(width: 44, alignment: .trailing)
                }
                .padding(9).background(.background.secondary, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            }
            Button("Open Grade Calc") { state.selectedModuleID = "gradecalc" }
                .font(.caption).buttonStyle(.borderless)
        }
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
        state.data.courses.removeAll { $0.id == draft.id }
        // Detach references
        for i in state.data.assignments.indices where state.data.assignments[i].courseID == draft.id {
            state.data.assignments[i].courseID = nil
        }
        for i in state.data.notes.indices where state.data.notes[i].courseID == draft.id {
            state.data.notes[i].courseID = nil
        }
        dismiss()
    }
}
