import Foundation

/// Canvas LMS REST API sync (personal access token). Read-only pull into StudyBar.
@MainActor
enum CanvasService {
    static let tokenAccount = "canvasToken"
    static var host: String {
        get { UserDefaults.standard.string(forKey: "canvasHost") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "canvasHost") }
    }
    static var hasToken: Bool { Keychain.get(account: tokenAccount) != nil }

    // MARK: Canvas JSON

    private struct CCourse: Codable { let id: Int; let name: String?; let course_code: String?; let enrollments: [CEnrollment]? }
    private struct CEnrollment: Codable { let computed_current_grade: String? }
    private struct CAssignment: Codable {
        let id: Int; let name: String?; let due_at: String?; let points_possible: Double?
        let html_url: String?; let submission: CSubmission?
    }
    private struct CSubmission: Codable { let workflow_state: String? }

    // MARK: Sync

    static func sync(state: AppState) async -> String {
        let cleanHost = host.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !cleanHost.isEmpty else { return "Enter your Canvas URL first." }
        guard let token = Keychain.get(account: tokenAccount), !token.isEmpty else { return "Save your access token first." }
        let base = "https://\(cleanHost)/api/v1"

        guard let courses: [CCourse] = await get("\(base)/courses?enrollment_state=active&include[]=total_scores&per_page=100", token) else {
            return "Couldn't reach Canvas. Check the URL and token."
        }
        if courses.isEmpty { return "No active courses found." }

        var newCourses = 0, newAsg = 0, updatedAsg = 0
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
        }
        var msg = "Synced \(newCourses) new course\(newCourses == 1 ? "" : "s"), \(newAsg) new assignment\(newAsg == 1 ? "" : "s")"
        if updatedAsg > 0 { msg += ", \(updatedAsg) updated" }
        return msg + "."
    }

    private static func get<T: Decodable>(_ url: String, _ token: String) async -> T? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.sb.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
