import SwiftUI
import AppKit

/// Renders every module through the real window shell — three widths, dark and light — plus
/// each module on an empty store and the menu-bar popover, so a release can be looked over
/// screen by screen. Two layout bugs reached the user before anything rendered every module at
/// every width; this is that look, kept.
///
/// Run only through `scripts/module-audit.sh`: it renders from a copy of the build with its own
/// bundle id and a throwaway data folder. Rendering the window writes preferences (module use,
/// onboarding), and the Debug build otherwise shares the installed app's.
enum ModuleAudit {
    static let widths: [CGFloat] = [720, 1280, 1680]
    static let height: CGFloat = 820

    @MainActor
    static func run(state: AppState, out: String) -> Int32 {
        guard ProcessInfo.processInfo.environment["STUDYBAR_DATA_DIR"] != nil,
              Bundle.main.bundleIdentifier == "com.studybar.StudyBar.test" else {
            print("Run this through scripts/module-audit.sh — it needs a test copy (bundle id com.studybar.StudyBar.test) and STUDYBAR_DATA_DIR.")
            return 1
        }
        let dir = URL(fileURLWithPath: out)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // A known starting point: past runs (or a live test) may have left settings in this domain.
        let d = UserDefaults.standard
        d.set(true, forKey: "onboarded")
        d.set(false, forKey: "breakScreen")
        d.set(false, forKey: "sidebarCollapsed")
        d.set("system", forKey: "appearance")
        d.set("system", forKey: SurfaceTheme.storageKey)
        state.modulePrefs.order = .category
        state.modulePrefs.categoryOrder = ModuleCategory.allCases.map(\.rawValue)
        state.modulePrefs.hidden = []
        state.modulePrefs.favorites = []
        // Always the seed: a fresh store already holds the starter "Getting Started" course, and
        // the data folder is a throwaway the script made for this run.
        state.data = AppData()
        seed(state)

        var shots: [(module: String, file: String)] = []
        func shoot(_ view: some View, _ module: String, _ file: String, _ size: CGSize, _ look: NSAppearance.Name) {
            save(view.environmentObject(state), to: dir.appendingPathComponent(file), size: size, appearance: look, settle: 0.8)
            shots.append((module, file))
        }
        let looks: [(NSAppearance.Name, String)] = [(.darkAqua, "dark"), (.aqua, "light")]

        for m in ModuleRegistry.all {
            for (look, name) in looks {
                for w in widths {
                    shoot(RootView(surface: .window, win: WindowModel(moduleID: m.id)), m.id,
                          "\(m.id)-\(Int(w))-\(name).png", CGSize(width: w, height: height), look)
                }
            }
        }
        for (look, name) in looks {
            shoot(RootView(surface: .popover), "popover", "popover-380-\(name).png", CGSize(width: 380, height: 560), look)
        }
        // An empty store — a new student's first look at every screen.
        state.data = AppData()
        for m in ModuleRegistry.all {
            shoot(RootView(surface: .window, win: WindowModel(moduleID: m.id)), m.id,
                  "\(m.id)-empty-1280-dark.png", CGSize(width: 1280, height: height), .darkAqua)
        }

        writeIndex(shots, to: dir.appendingPathComponent("index.html"))
        print("Module audit: \(shots.count) renders in \(dir.path)")
        return 0
    }

    /// Draw a view offscreen at a fixed size and write it as a PNG.
    @MainActor
    static func save(_ view: some View, to url: URL, size: CGSize, appearance: NSAppearance.Name, settle: TimeInterval = 0.6) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = CGRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: appearance)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: appearance)
        win.contentView = host
        win.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        win.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        win.orderOut(nil)
    }

    private static func writeIndex(_ shots: [(module: String, file: String)], to url: URL) {
        var html = "<!doctype html><meta charset=utf-8><title>Module audit</title><style>body{font:13px -apple-system,sans-serif;background:#1b1b1f;color:#eee;margin:16px}h2{margin:28px 0 8px}div{display:flex;flex-wrap:wrap;gap:12px;align-items:flex-start}figure{margin:0}img{max-width:560px;border:1px solid #444}figcaption{color:#aaa;margin-top:4px}</style>"
        var order: [String] = []
        for s in shots where !order.contains(s.module) { order.append(s.module) }
        for m in order {
            html += "<h2>\(m)</h2><div>"
            for s in shots where s.module == m {
                html += "<figure><a href=\"\(s.file)\"><img src=\"\(s.file)\" loading=lazy></a><figcaption>\(s.file)</figcaption></figure>"
            }
            html += "</div>"
        }
        try? html.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Realistic data

    /// A term's worth of data, dated around today: the volumes and long names a real student
    /// has, because short test data hid a layout bug the user then hit twice.
    @MainActor
    static func seed(_ state: AppState) {
        let now = Date()
        let cal = Calendar.current
        func day(_ n: Int, hour: Int = 23, minute: Int = 59) -> Date {
            let base = cal.date(byAdding: .day, value: n, to: cal.startOfDay(for: now)) ?? now
            return cal.date(bySettingHour: hour, minute: minute, second: 0, of: base) ?? base
        }

        func course(_ code: String, _ name: String, _ color: String, grade: String = "", credits: Double = 3) -> Course {
            var c = Course(name: name, code: code)
            c.colorHex = color; c.grade = grade; c.credits = credits; c.term = "Fall 2026"
            return c
        }
        let phy = course("PHY2049", "Physics II (Calculus-Based)", "#A78BFA", grade: "B+", credits: 4)
        let cwr = course("CWR3201", "Water Resources Engineering", "#34C3E0")
        let mac = course("MAC2313", "Calculus III", "#F472B6", grade: "A-", credits: 4)
        let cgn = course("CGN2002", "Introduction to Civil Engineering and the Built Environment", "#84CC16")
        let enc = course("ENC1102", "Writing About Research", "#FACC15")
        let sta = course("STA3032", "Engineering Statistics", "#FB7185")   // nothing in it on purpose
        state.data.courses = [phy, cwr, mac, cgn, enc, sta]
        state.data.termName = "Fall 2026"
        state.data.termStart = day(-42, hour: 0, minute: 0)
        state.data.termEnd = day(63, hour: 0, minute: 0)

        func klass(_ c: Course, _ title: String, _ days: [Int], _ start: Int, _ end: Int, _ room: String) -> ClassSession {
            ClassSession(courseID: c.id, title: title, weekday: days[0], days: days, startMinutes: start, endMinutes: end, room: room)
        }
        state.data.classes = [
            klass(phy, "Lecture", [2, 4, 6], 12 * 60 + 50, 13 * 60 + 40, "NPB 1001"),
            klass(cwr, "Lab", [3, 5], 14 * 60, 15 * 60 + 50, "WEIL 270"),
            klass(mac, "Lecture", [3, 5], 9 * 60 + 35, 10 * 60 + 50, "LIT 101"),
            klass(cgn, "Lecture", [2, 4, 6], 10 * 60 + 40, 11 * 60 + 30, "WEIL 408"),
            klass(enc, "Seminar", [2, 4], 15 * 60, 16 * 60 + 15, "TUR 2303"),
        ]

        var work: [Assignment] = []
        func add(_ title: String, _ c: Course, _ due: Date, done: Date? = nil, archived: Bool = false) {
            var a = Assignment(title: title, courseID: c.id, due: due)
            if let done { a.setDone(true, at: done) }
            if archived { a.archived = true }
            work.append(a)
        }
        // Due today, then the rest of the week.
        add("Problem set 6 — Gauss's law", phy, day(0))
        add("Pre-lab questions — weirs", cwr, day(0))
        add("Discussion post 7", enc, day(0))
        add("Reading quiz 5", enc, day(1))
        add("Annotated bibliography", enc, day(2))
        add("Concept check 4", cgn, day(2))
        add("Homework 8 — surface integrals", mac, day(3))
        add("Lab report 4 — open channel flow", cwr, day(4))
        add("Homework 7 — triple integrals", mac, day(5))
        add("Reflection essay — the built environment", cgn, day(6))
        add("Quiz 3 — capacitors", phy, day(6))
        add("Problem set 7", phy, day(7))
        // Overdue.
        add("Lab notebook check", cwr, day(-2))
        add("Peer review of a classmate's draft", enc, day(-1))
        // Later in the term.
        let later: [(String, Course)] = [
            ("Problem set 8", phy), ("Problem set 9", phy), ("Midterm 2", phy), ("Lab report 5 — pipe networks", cwr),
            ("Lab report 6 — pumps", cwr), ("Design memo", cwr), ("Homework 9 — vector fields", mac), ("Homework 10 — Green's theorem", mac),
            ("Exam 2", mac), ("Site visit write-up", cgn), ("Infrastructure case study", cgn), ("Final project proposal", cgn),
            ("Research question draft", enc), ("Source evaluation", enc), ("Research paper — first draft", enc), ("Problem set 10", phy),
            ("Homework 11 — Stokes' theorem", mac), ("Lab report 7 — hydrology", cwr), ("Reflection essay 2", cgn), ("Portfolio cover letter", enc),
        ]
        for (i, (t, c)) in later.enumerated() { add(t, c, day(9 + i * 2)) }
        // Finished this week, and the put-aside tail of an import.
        for (i, (t, c)) in [("Problem set 5", phy), ("Homework 6 — double integrals", mac), ("Lab report 3", cwr),
                            ("Discussion post 6", enc), ("Concept check 3", cgn), ("Quiz 2 — potential", phy)].enumerated() {
            add(t, c, day(-i), done: day(-min(i, 3), hour: 16, minute: 0))
        }
        for (i, (t, c)) in [("Attendance — week 1", phy), ("Syllabus quiz", cwr), ("Intro survey", enc),
                            ("Library tour sign-off", enc), ("Attendance — week 2", cgn)].enumerated() {
            add(t, c, day(-30 - i), archived: true)
        }
        state.data.assignments = work

        func note(_ title: String, _ c: Course, _ body: String, daysAgo: Int) -> Note {
            var n = Note(title: title, body: body, courseID: c.id)
            n.createdAt = day(-daysAgo, hour: 11, minute: 0); n.updatedAt = n.createdAt
            return n
        }
        let lecture = """
        # Week 7 — Magnetic force
        > **In short:** a magnetic field pushes on a moving charge sideways, never along its path, so it bends the path without speeding the charge up.

        When a charge moves through a magnetic field it feels a force at right angles to both its velocity and the field. That sideways push is why charged particles curve in a field, and why a wire carrying current is pushed when it sits between magnets.

        $$\\vec F = q\\,\\vec v \\times \\vec B$$
        In words: the force is the charge times the cross product of its velocity and the field.

        > **Key idea:** moving straight along the field, the force is zero; moving square-on to it, the force is largest.

        > **Watch out:** the right-hand rule gives the direction for a positive charge — flip it for an electron.
        """
        state.data.notes = [
            note("Week 7 — Magnetic force", phy, lecture, daysAgo: 0),
            note("Open channel flow", cwr, "## Manning's equation\nFlow depends on slope, roughness and the shape of the channel.", daysAgo: 2),
            note("Triple integrals in cylindrical coordinates", mac, "## Setting up\nUse r, θ, z when the region is round.", daysAgo: 2),
            note("Week 6 — Current and resistance", phy, "## Ohm's law\n$V = IR$ for an ohmic conductor.", daysAgo: 7),
            note("Research question workshop", enc, "A good research question is narrow enough to answer and open enough to argue.", daysAgo: 8),
            note("The built environment — reading notes", cgn, "Roads, water and power as one system.", daysAgo: 9),
            note("Weirs and flumes", cwr, "Measuring flow by forcing it through a known shape.", daysAgo: 9),
            note("Double integrals review", mac, "Order of integration and swapping limits.", daysAgo: 10),
            note("Week 5 — Capacitors", phy, "## Capacitance\n$C = Q/V$, measured in farads.", daysAgo: 14),
            note("Annotated bibliography — sources", enc, "Five sources, two primary.", daysAgo: 15),
            note("Hydrologic cycle", cwr, "Precipitation, infiltration, runoff, evaporation.", daysAgo: 20),
            note("Vectors and the dot product", mac, "Projection of one vector onto another.", daysAgo: 28),
        ]

        let decks = [Deck(name: "PHY2049", courseID: phy.id), Deck(name: "MAC2313", courseID: mac.id)]
        state.data.decks = decks
        state.data.flashcards = decks.flatMap { deck in
            (0..<30).map { i -> Flashcard in
                var f = Flashcard(deckID: deck.id, front: "\(deck.name) question \(i + 1)", back: "Answer \(i + 1)")
                f.reviews = 4; f.lapses = i % 10 == 0 ? 1 : 0
                f.lastReview = day(-3, hour: 20, minute: 0)
                f.due = i < 12 ? day(-1, hour: 9, minute: 0) : day(4 + i % 5, hour: 9, minute: 0)   // 24 due across both decks
                return f
            }
        }

        state.data.timeEntries = [
            TimeEntry(courseID: phy.id, label: "Problem set 5", seconds: 3_000, date: day(-2, hour: 19, minute: 0)),
            TimeEntry(courseID: mac.id, label: "Homework 6", seconds: 2_400, date: day(-1, hour: 18, minute: 0)),
            TimeEntry(courseID: cwr.id, label: "Lab report 4", seconds: 4_800, date: day(0, hour: 9, minute: 0)),
        ]

        func book(_ title: String, _ author: String, _ c: Course, page: Int, of total: Int) -> ReadingItem {
            var r = ReadingItem(); r.title = title; r.author = author; r.courseID = c.id
            r.currentPage = page; r.totalPages = total; r.startedAt = day(-20, hour: 9, minute: 0)
            return r
        }
        state.data.reading = [
            book("Physics for Scientists and Engineers", "Serway & Jewett", phy, page: 744, of: 1_484),
            book("Water Resources Engineering", "Mays", cwr, page: 212, of: 890),
            book("They Say / I Say", "Graff & Birkenstein", enc, page: 96, of: 352),
        ]

        state.data.links = [
            QuickLink(title: "Canvas", url: "https://canvas.example.edu", courseID: nil),
            QuickLink(title: "PHY2049 lecture videos", url: "https://example.edu/phy2049/videos", courseID: phy.id),
            QuickLink(title: "WebAssign", url: "https://www.webassign.net", courseID: phy.id),
            QuickLink(title: "CWR3201 lab manual", url: "https://example.edu/cwr3201/manual.pdf", courseID: cwr.id),
            QuickLink(title: "Paul's Online Math Notes", url: "https://tutorial.math.lamar.edu", courseID: mac.id),
            QuickLink(title: "Writing center", url: "https://example.edu/writing", courseID: enc.id),
            QuickLink(title: "Library databases", url: "https://example.edu/library", courseID: enc.id),
            QuickLink(title: "ASCE infrastructure report card", url: "https://infrastructurereportcard.org", courseID: cgn.id),
        ]
    }
}
