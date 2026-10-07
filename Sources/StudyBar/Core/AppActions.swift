import Foundation
import AppKit

/// Central, side-effecting actions usable from URL scheme, Services, notifications and App Intents.
@MainActor
enum AppActions {
    /// Record from anywhere — the global shortcut and the menu bar: start, pause, resume. A new
    /// take over unsaved work isn't started here; Voice Note opens and asks first.
    static func toggleRecording() {
        guard let state = AppState.current else { return }
        let voice = state.voice
        switch voice.status {
        case .recording: voice.pause()
        case .paused: voice.resume()
        case .preparing, .transcribing: break
        default:
            if voice.hasUnsaved { state.recordRequested = true; state.selectedModuleID = "voice"; WindowOpener.routeToWindow?("voice") }
            else {
                // Voice may never have been opened: expect the words of the class in session now.
                CourseVocabulary.prepare(voice, course: state.course(state.courseID(at: .now) ?? state.workingCourseID), data: state.data)
                voice.start()
            }
        }
    }

    static func courseID(named name: String?) -> UUID? {
        guard let name, !name.isEmpty, let s = AppState.current else { return nil }
        return s.data.courses.first {
            $0.name.localizedCaseInsensitiveContains(name) || $0.code.localizedCaseInsensitiveContains(name)
        }?.id
    }

    @discardableResult
    static func addNote(_ text: String, course: String? = nil) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let s = AppState.current, !t.isEmpty else { return false }
        // Text arriving here is often pasted from a model or a web page, so it carries
        // `\(…\)` / `\[…\]`. Canonicalize to `$…$` so the editor renders it too, not just
        // the reading view.
        let body = MathSupport.normalized(t)
        s.data.notes.append(Note(title: String(body.prefix(60)), body: body, courseID: courseID(named: course)))
        return true
    }

    @discardableResult
    static func addTask(_ text: String, course: String? = nil, dueInDays: Int? = nil) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let s = AppState.current, !t.isEmpty else { return false }
        var a = Assignment(task: t, courseID: courseID(named: course))
        if let d = dueInDays { a.due = Calendar.current.date(byAdding: .day, value: d, to: .now) }
        s.data.assignments.append(a)
        return true
    }

    static func startFocus(minutes: Int? = nil, label: String? = nil) {
        guard let s = AppState.current else { return }
        if let m = minutes, m > 0 { s.pomodoro.focusMinutes = m }
        s.pomodoro.startFocus(label: label ?? "")
    }

    static func togglePomodoro() {
        guard let p = AppState.current?.pomodoro else { return }
        if p.phase == .idle { p.startFocus() } else { p.toggle() }
    }

    /// Route a plain-English prompt to the Assistant module (used by ✨ entry points and ⌘K).
    /// Open the assistant as a summoned floating panel (no longer a sidebar module) and,
    /// if configured, send it a starting prompt. Cross-object work lives here; inline edits
    /// stay on the object (the ✨ menus).
    static func assistant(_ prompt: String) {
        AssistantPanel.shared.show(prompt: prompt)
    }

    static func open(module id: String) {
        guard let s = AppState.current else { return }
        NSApp.activate(ignoringOtherApps: true)
        WindowOpener.open?("main")
        // Legacy ids from before Pomodoro/Stopwatch/Focus/Sessions merged into one module.
        let legacy: Set<String> = ["pomodoro", "stopwatch", "focus", "sessions"]
        s.selectedModuleID = legacy.contains(id) ? "timefocus" : id
        s.globalSearch = ""
    }

    static func completeAssignment(id: UUID) {
        guard let s = AppState.current, let i = s.data.assignments.firstIndex(where: { $0.id == id }) else { return }
        s.data.assignments[i].setDone(true)
        Notifier.cancel(id: id.uuidString)
    }

    static func snoozeAssignment(id: UUID, days: Int) {
        guard let s = AppState.current, let i = s.data.assignments.firstIndex(where: { $0.id == id }) else { return }
        let base = s.data.assignments[i].due ?? .now
        let newDue = Calendar.current.date(byAdding: .day, value: days, to: base) ?? base
        s.data.assignments[i].due = newDue
        Notifier.cancel(id: id.uuidString)
        Notifier.schedule(id: id.uuidString, title: "Due soon: \(s.data.assignments[i].title)",
                          body: "Due \(newDue.dayMonth).",
                          at: Calendar.current.date(byAdding: .day, value: -1, to: newDue) ?? newDue,
                          assignmentID: id)
    }
}
