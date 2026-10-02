import AppKit

/// Canvas LMS REST API sync (personal access token). Read-only pull into StudyBar.
@MainActor
enum CanvasService {
    static let tokenAccount = "canvasToken"
    static var host: String {
        get { UserDefaults.standard.string(forKey: "canvasHost") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "canvasHost") }
    }
    /// Cache-only, like `AIConfig.hasKey`: this is read from Settings and the Canvas banners
    /// while they lay out, and a cold Keychain read there froze the UI for seconds.
    static var hasToken: Bool { Keychain.has(account: tokenAccount) }
    /// Whether sync brings each course's PDFs, slides and documents into Study. On unless turned off.
    static var bringsFiles: Bool { UserDefaults.standard.object(forKey: "canvasFiles") as? Bool ?? true }
    /// A first sync of a full term would otherwise download every file at once; the rest come next time.
    static let filesPerSync = 25
    /// API requests, and file downloads (longer: a deck can be large). A self-test swaps in a fake Canvas.
    static var session = URLSession.sb
    static var downloads = URLSession.shared

    // MARK: Canvas JSON

    private struct CCourse: Codable { let id: Int; let name: String?; let course_code: String?; let enrollments: [CEnrollment]? }
    private struct CEnrollment: Codable { let computed_current_grade: String? }
    private struct CAssignment: Codable {
        let id: Int; let name: String?; let due_at: String?; let points_possible: Double?
        let html_url: String?; let submission: CSubmission?
    }
    private struct CSubmission: Codable { let workflow_state: String? }
    struct CFile: Codable {
        let id: Int; let display_name: String?; let filename: String?; let size: Int?; let url: String?
        let locked_for_user: Bool?; let hidden_for_user: Bool?
    }
    private struct CModule: Codable { let items: [CItem]? }
    private struct CItem: Codable { let type: String?; let content_id: Int? }
    struct CAnnouncement: Codable { let id: Int; let title: String?; let message: String?; let posted_at: String?; let html_url: String?; let context_code: String? }

    // MARK: Sync

    static func sync(state: AppState) async -> String {
        let cleanHost = host.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !cleanHost.isEmpty else { return "Enter your Canvas URL first." }
        guard let token = Keychain.get(account: tokenAccount), !token.isEmpty else { return "Save your access token first." }
        return await sync(state: state, base: "https://\(cleanHost)/api/v1", token: token)
    }

    static func sync(state: AppState, base: String, token: String) async -> String {
        guard let courses: [CCourse] = await get("\(base)/courses?enrollment_state=active&include[]=total_scores&per_page=100", token) else {
            return "Couldn't reach Canvas. Check the URL and token."
        }
        if courses.isEmpty { return "No active courses found." }

        var newCourses = 0, newAsg = 0, updatedAsg = 0, newFiles = 0, moreFiles = false
        let df = ISO8601DateFormatter()

        for c in courses {
            let name = c.name ?? "Course"
            let courseUUID: UUID
            if let i = state.data.courses.firstIndex(where: { $0.canvasID == c.id }) {
                state.data.courses[i].name = name
                if state.data.courses[i].code.isEmpty { state.data.courses[i].code = c.course_code ?? "" }
                if let g = c.enrollments?.first?.computed_current_grade, !g.isEmpty { state.data.courses[i].grade = g }
                courseUUID = state.data.courses[i].id
            } else {
                var course = Course(name: name, code: c.course_code ?? "")
                course.canvasID = c.id
                course.colorHex = Palette.swatches[state.data.courses.count % Palette.swatches.count]
                if let g = c.enrollments?.first?.computed_current_grade { course.grade = g }
                state.data.courses.append(course)
                courseUUID = course.id
                newCourses += 1
            }

            guard let assignments: [CAssignment] = await get("\(base)/courses/\(c.id)/assignments?include[]=submission&per_page=100&order_by=due_at", token) else { continue }
            for a in assignments {
                guard let dueStr = a.due_at, let due = df.date(from: dueStr) else { continue }
                if due < Date().addingTimeInterval(-14 * 86400) { continue }
                let submitted = ["submitted", "graded"].contains(a.submission?.workflow_state ?? "")
                if let i = state.data.assignments.firstIndex(where: { $0.canvasID == a.id }) {
                    state.data.assignments[i].due = due
                    state.data.assignments[i].points = a.points_possible
                    state.data.assignments[i].submitted = submitted
                    if state.data.assignments[i].link.isEmpty { state.data.assignments[i].link = a.html_url ?? "" }
                    updatedAsg += 1
                } else {
                    var asg = Assignment(title: a.name ?? "Assignment", courseID: courseUUID, due: due)
                    asg.link = a.html_url ?? ""
                    asg.canvasID = a.id
                    asg.submitted = submitted
                    asg.points = a.points_possible
                    state.data.assignments.append(asg)
                    newAsg += 1
                }
            }

            // The course's slides, readings and handouts, as Study sources.
            guard bringsFiles else { continue }
            let have = Set((state.data.studyFiles ?? []).compactMap(\.canvasID))
            let wanted = studyable(await files(c.id, base, token, skipping: have)).filter { !have.contains($0.id) }
            for f in wanted {
                guard newFiles < filesPerSync else { moreFiles = true; break }
                if let sf = await bringIn(f, course: courseUUID, token: token) {
                    state.data.studyFiles = (state.data.studyFiles ?? []) + [sf]
                    newFiles += 1
                }
            }
        }

        // Announcements from the last month, one request for every course.
        var newAnn = 0
        let since = df.string(from: Date().addingTimeInterval(-30 * 86_400))
        let codes = courses.map { "context_codes[]=course_\($0.id)" }.joined(separator: "&")
        if let anns: [CAnnouncement] = await get("\(base)/announcements?\(codes)&start_date=\(since)&per_page=50", token) {
            for (canvasID, list) in Dictionary(grouping: anns, by: { Int($0.context_code?.replacingOccurrences(of: "course_", with: "") ?? "") ?? 0 }) {
                guard let i = state.data.courses.firstIndex(where: { $0.canvasID == canvasID }) else { continue }
                let old = state.data.courses[i].announcements ?? []
                newAnn += list.filter { a in !old.contains { $0.id == a.id } }.count
                state.data.courses[i].announcements = merged(old, list.map(announcement))
            }
        }

        var msg = "Synced \(newCourses) new course\(newCourses == 1 ? "" : "s"), \(newAsg) new assignment\(newAsg == 1 ? "" : "s")"
        if updatedAsg > 0 { msg += ", \(updatedAsg) updated" }
        if newFiles > 0 { msg += ", \(newFiles) course file\(newFiles == 1 ? "" : "s") added to Study" + (moreFiles ? " (more next sync)" : "") }
        if newAnn > 0 { msg += ", \(newAnn) new announcement\(newAnn == 1 ? "" : "s")" }
        return msg + "."
    }

    // MARK: Files

    static let studyTypes: Set<String> = ["pdf", "pptx", "docx", "doc", "rtf", "txt", "md"]

    /// What Study can read: documents and slides under 30 MB the student may open.
    static func studyable(_ files: [CFile]) -> [CFile] {
        files.filter { f in
            let name = f.filename ?? f.display_name ?? ""
            return studyTypes.contains((name as NSString).pathExtension.lowercased()) && (f.size ?? 0) <= 30_000_000
                && f.locked_for_user != true && f.hidden_for_user != true && f.url?.isEmpty == false
        }
    }

    /// The Files page — or, where a course hides it, the files its Modules hand out.
    private static func files(_ course: Int, _ base: String, _ token: String, skipping have: Set<Int>) async -> [CFile] {
        if let all: [CFile] = await get("\(base)/courses/\(course)/files?per_page=100&sort=updated_at&order=desc", token) { return all }
        guard let modules: [CModule] = await get("\(base)/courses/\(course)/modules?include[]=items&per_page=50", token) else { return [] }
        var out: [CFile] = []
        for id in modules.flatMap({ $0.items ?? [] }).filter({ $0.type == "File" }).compactMap(\.content_id) where !have.contains(id) {
            if let f: CFile = await get("\(base)/courses/\(course)/files/\(id)", token) { out.append(f) }
            if out.count >= filesPerSync { break }
        }
        return out
    }

    /// Downloaded, read in, and kept with the course's study files.
    private static func bringIn(_ f: CFile, course: UUID, token: String) async -> StudyFile? {
        guard let u = f.url.flatMap(URL.init(string:)) else { return nil }
        // The download link carries its own verifier, and the storage it redirects to refuses a
        // second credential — so the token goes only on a retry.
        var data: Data?
        if let (d, r) = try? await downloads.data(from: u), (r as? HTTPURLResponse)?.statusCode == 200 { data = d } else {
            var req = URLRequest(url: u)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let (d, r) = try? await downloads.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200 { data = d }
        }
        guard let data else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-canvas-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let name = (f.display_name ?? f.filename ?? "Course file").replacingOccurrences(of: "/", with: "-")
        let tmp = dir.appendingPathComponent(name)
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil,
              (try? data.write(to: tmp)) != nil else { return nil }
        guard var file = await Task.detached(operation: { StudyMaterial.attach(tmp, courseID: course) }).value else { return nil }
        file.canvasID = f.id
        return file
    }

    // MARK: Announcements

    static func announcement(_ a: CAnnouncement) -> CanvasAnnouncement {
        CanvasAnnouncement(id: a.id, title: a.title ?? "Announcement", message: plain(a.message ?? ""),
                           postedAt: a.posted_at.flatMap { ISO8601DateFormatter().date(from: $0) }, url: a.html_url ?? "")
    }

    /// The newest ten, a re-synced one replacing its old copy.
    static func merged(_ old: [CanvasAnnouncement], _ new: [CanvasAnnouncement]) -> [CanvasAnnouncement] {
        var byID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for a in new { byID[a.id] = a }
        return Array(byID.values.sorted { ($0.postedAt ?? .distantPast) > ($1.postedAt ?? .distantPast) }.prefix(10))
    }

    /// An announcement's HTML as text: paragraphs kept, tags and entities gone.
    static func plain(_ html: String) -> String {
        var s = html.replacingOccurrences(of: #"(?i)<br\s*/?>|</p>|</div>|</li>|</h\d>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (a, b) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&rsquo;", "’"),
                       ("&lsquo;", "‘"), ("&ldquo;", "“"), ("&rdquo;", "”"), ("&ndash;", "–"), ("&mdash;", "—"), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        return s.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func get<T: Decodable>(_ url: String, _ token: String) async -> T? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Headless self-test (StudyBar --canvas-selftest, on a throwaway store only)

/// A whole sync against a fake Canvas: two courses — one whose Files page is hidden, so its
/// files come through Modules — a picture and a locked file to skip, a download that needs the
/// token, and an announcement in HTML. Then a second sync, which must add nothing twice.
enum CanvasSelfTest {
    final class Fake: URLProtocol {
        nonisolated(unsafe) static var files: [String: Data] = [:]
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}
        override func startLoading() {
            let u = request.url!, authed = request.value(forHTTPHeaderField: "Authorization") == "Bearer t0k"
            let soon = ISO8601DateFormatter().string(from: Date().addingTimeInterval(5 * 86_400))
            let (code, body): (Int, String) = switch (u.host() ?? "", u.path) {
            case ("canvas.test", "/api/v1/courses"):
                (200, #"[{"id":101,"name":"Physics II","course_code":"PHY2049","enrollments":[{"computed_current_grade":"A-"}]},{"id":102,"name":"History","course_code":"HIS1010"}]"#)
            case ("canvas.test", "/api/v1/courses/101/assignments"):
                (200, #"[{"id":1,"name":"Problem Set 5","due_at":"\#(soon)","points_possible":10,"html_url":"https://canvas.test/a/1","submission":{"workflow_state":"unsubmitted"}}]"#)
            case ("canvas.test", "/api/v1/courses/102/assignments"): (200, "[]")
            case ("canvas.test", "/api/v1/courses/101/files"):
                (200, #"[{"id":11,"display_name":"Lecture 3.pdf","filename":"Lecture_3.pdf","size":5000,"url":"https://files.test/11?verifier=v"},"#
                    + #"{"id":12,"display_name":"photo.jpg","filename":"photo.jpg","size":10,"url":"https://files.test/12"},"#
                    + #"{"id":13,"display_name":"Locked.pdf","filename":"Locked.pdf","size":10,"url":"https://files.test/13","locked_for_user":true}]"#)
            case ("canvas.test", "/api/v1/courses/102/files"): (403, #"{"message":"unauthorized"}"#)
            case ("canvas.test", "/api/v1/courses/102/modules"): (200, #"[{"items":[{"type":"Page","content_id":5},{"type":"File","content_id":21}]}]"#)
            case ("canvas.test", "/api/v1/courses/102/files/21"):
                (200, #"{"id":21,"display_name":"Reading.txt","filename":"reading.txt","size":100,"url":"https://files.test/21"}"#)
            case ("canvas.test", "/api/v1/announcements"):
                (200, #"[{"id":900,"title":"Exam moved","message":"<p>The midterm is now on <b>Friday</b>.</p><p>Bring a calculator &amp; ID.</p>","#
                    + #""posted_at":"2026-09-30T14:00:00Z","html_url":"https://canvas.test/ann/900","context_code":"course_101"}]"#)
            case ("files.test", "/21") where !authed: (401, "")          // this one wants the token
            case ("files.test", let p): Self.files[p].map { (200, String(decoding: $0, as: UTF8.self)) } ?? (404, "")
            default: (404, "")
            }
            let data = u.host() == "files.test" ? Self.files[u.path] ?? Data() : Data(body.utf8)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: u, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            if code == 200 { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    @MainActor
    static func run(state: AppState) async -> Int32 {
        guard ProcessInfo.processInfo.environment["STUDYBAR_DATA_DIR"] != nil else { print("Run on a throwaway store (STUDYBAR_DATA_DIR)."); return 1 }
        var fail = 0
        func check(_ n: String, _ ok: Bool, _ d: String = "") { print("  \(ok ? "ok  " : "FAIL") \(n) \(d)"); if !ok { fail += 1 } }

        // A slide PDF with a text layer, and a plain-text reading.
        let pdf = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        if let consumer = CGDataConsumer(data: pdf as CFMutableData), let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) {
            ctx.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            ("Gauss's law: the flux through a closed surface is the enclosed charge over epsilon zero." as NSString)
                .draw(in: box.insetBy(dx: 20, dy: 20), withAttributes: [.font: NSFont.systemFont(ofSize: 18)])
            NSGraphicsContext.restoreGraphicsState(); ctx.endPDFPage(); ctx.closePDF()
        }
        Fake.files = ["/11": pdf as Data, "/21": Data("The causes of the French Revolution: debt, bread prices and the Estates-General.".utf8)]
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Fake.self]
        let fake = URLSession(configuration: config)
        let (oldSession, oldDownloads, before) = (CanvasService.session, CanvasService.downloads, state.data)
        CanvasService.session = fake; CanvasService.downloads = fake
        defer {
            for f in (state.data.studyFiles ?? []) where f.canvasID != nil { StudyMaterial.remove(f) }
            state.data = before; CanvasService.session = oldSession; CanvasService.downloads = oldDownloads
        }

        let first = await CanvasService.sync(state: state, base: "https://canvas.test/api/v1", token: "t0k")
        let files = (state.data.studyFiles ?? []).filter { $0.canvasID != nil }
        let phy = state.data.courses.first { $0.canvasID == 101 }, his = state.data.courses.first { $0.canvasID == 102 }
        check("sync reports what came in", first.contains("2 new courses") && first.contains("1 new assignment")
              && first.contains("2 course files added to Study") && first.contains("1 new announcement"), first)
        check("course files: the slides, and the file Modules hand out; no picture, nothing locked",
              Set(files.compactMap(\.canvasID)) == [11, 21] && files.allSatisfy { $0.units > 0 }, "\(files.map { ($0.name, $0.canvasID ?? 0, $0.units) })")
        check("course files go to their course", files.first { $0.canvasID == 11 }?.courseID == phy?.id && files.first { $0.canvasID == 21 }?.courseID == his?.id)
        check("a course file's text is readable in Study",
              StudyMaterial.passages(.file(files.first { $0.canvasID == 11 }?.id ?? UUID()), in: state.data).first?.text.contains("enclosed charge") == true)
        check("announcement as plain text, on its course", phy?.announcements?.first?.message == "The midterm is now on Friday.\nBring a calculator & ID."
              && phy?.announcements?.first?.postedAt != nil && his?.announcements == nil, phy?.announcements?.first?.message ?? "none")
        check("grade comes along", phy?.grade == "A-")

        let second = await CanvasService.sync(state: state, base: "https://canvas.test/api/v1", token: "t0k")
        check("a second sync adds nothing twice", !second.contains("course file") && !second.contains("announcement")
              && (state.data.studyFiles ?? []).filter { $0.canvasID != nil }.count == 2 && state.data.courses.first { $0.canvasID == 101 }?.announcements?.count == 1, second)

        print(fail == 0 ? "CANVAS SELFTEST: ALL PASS" : "CANVAS SELFTEST: \(fail) FAILED")
        return fail == 0 ? 0 : 1
    }
}
