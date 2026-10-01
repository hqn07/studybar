import Foundation
import UserNotifications

/// A course's file saved to Downloads — "PHY2049 Lecture 7.pdf" — offered for that course's Study
/// sources by a notification with one button. Only files that arrive while StudyBar runs are
/// offered, and only once the student turns it on: reading Downloads makes macOS ask, once.
@MainActor
enum DownloadWatch {
    static let category = "DOWNLOAD_FILE"
    /// Settings ▸ Integrations; off until the student turns it on.
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "watchDownloads") }
    /// Downloads, or a scratch folder in the self-test.
    static var folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    /// How an offer is made: a notification, or captured in the self-test.
    static var offer: (URL, Course) -> Void = notify

    private static var source: DispatchSourceFileSystemObject?
    private static var known: Set<String> = []
    private static let types = Set(StudyMaterial.fileTypes).subtracting(["png", "jpg", "jpeg", "heic", "tiff"])

    /// Watching exactly when the setting says to.
    static func sync() {
        if enabled, source == nil { start() } else if !enabled { stop() }
    }

    static func start() {
        stop()
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        known = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])   // what's there isn't new
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        s.setEventHandler { MainActor.assumeIsolated { scan() } }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }

    static func stop() { source?.cancel(); source = nil }

    /// A new name in the folder is a finished download: browsers write to a temporary name
    /// (.crdownload, .part, .download) and rename it when it's done.
    static func scan() {
        let names = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        let new = names.subtracting(known)
        known = names
        guard let courses = AppState.current?.data.courses else { return }
        for name in new.sorted() where types.contains((name as NSString).pathExtension.lowercased()) {
            if let c = course(for: name, in: courses) { offer(folder.appendingPathComponent(name), c) }
        }
    }

    /// The course whose code is in the file's name as a word of its own — "PHY2049", "phy 2049",
    /// "PHY-2049" — so "PHY2049 Lecture 7" isn't read as the PHY2049L lab. The longest code wins.
    static func course(for name: String, in courses: [Course]) -> Course? {
        courses.filter { c in
            let parts = c.code.matches(of: /[A-Za-z]+|[0-9]+/).map { NSRegularExpression.escapedPattern(for: String($0.output)) }
            guard parts.joined().count >= 5 else { return false }
            let pattern = "(?<![A-Za-z0-9])" + parts.joined(separator: "[\\s_.\\-]*") + "(?![A-Za-z0-9])"
            return name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        .max { $0.code.count < $1.code.count }
    }

    private static func notify(_ url: URL, _ course: Course) {
        let code = course.code.isEmpty ? course.name : course.code
        let content = UNMutableNotificationContent()
        content.title = "Add to \(code)?"
        content.body = "“\(url.lastPathComponent)” was just downloaded. Add it to \(code)'s Study sources?"
        content.categoryIdentifier = category
        content.userInfo = ["downloadFile": url.path, "course": course.id.uuidString]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// The notification's answer: the file read into the course's sources, and Study opened on it.
    static func add(_ path: String, course: UUID) {
        let url = URL(fileURLWithPath: path)
        Task {
            let file = await Task.detached { StudyMaterial.attach(url, courseID: course) }.value
            guard let file, let state = AppState.current else {
                Notifier.post(title: "Couldn't add \(url.lastPathComponent)", body: "StudyBar found no text in it to study from.")
                return
            }
            state.data.studyFiles = (state.data.studyFiles ?? []) + [file]
            UserDefaults.standard.set(course.uuidString, forKey: "studyCourse")
            AppActions.open(module: "study")
        }
    }
}
