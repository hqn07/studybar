import Foundation
import AppKit

/// Central, side-effecting actions usable from URL scheme, Services, notifications and App Intents.
@MainActor
enum AppActions {
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
        s.data.notes.append(Note(title: String(t.prefix(60)), body: t, courseID: courseID(named: course)))
        return true
    }

    @discardableResult
    static func addTask(_ text: String, course: String? = nil, dueInDays: Int? = nil) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let s = AppState.current, !t.isEmpty else { return false }
        var todo = TodoItem(text: t, courseID: courseID(named: course))
        if let d = dueInDays { todo.due = Calendar.current.date(byAdding: .day, value: d, to: .now) }
        s.data.todos.append(todo)
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
    static func assistant(_ prompt: String) {
        guard let s = AppState.current else { return }
        NSApp.activate(ignoringOtherApps: true)
        s.selectedModuleID = "assistant"
        s.globalSearch = ""
        guard AIConfig.isReady else { return }   // empty state prompts to configure
        Task { await s.aiChat.send(prompt, state: s) }
    }

    static func open(module id: String) {
        guard let s = AppState.current else { return }
        NSApp.activate(ignoringOtherApps: true)
        WindowOpener.open?("main")
        s.selectedModuleID = id
        s.globalSearch = ""
    }

    static func completeAssignment(id: UUID) {
        guard let s = AppState.current, let i = s.data.assignments.firstIndex(where: { $0.id == id }) else { return }
        s.data.assignments[i].status = .done
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
