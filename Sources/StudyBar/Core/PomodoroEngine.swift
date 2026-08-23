import Foundation
import Combine
import AppKit

/// Drives Pomodoro (15) and feeds the menu bar countdown (9/8).
@MainActor
final class PomodoroEngine: ObservableObject {
    enum Phase: String { case focus = "Focus", shortBreak = "Break", longBreak = "Long Break", idle = "Idle" }

    @Published var phase: Phase = .idle
    @Published var remaining: Int = 25 * 60      // seconds
    @Published var running = false
    @Published var completedFocus = 0            // pomodoros done this session
    @Published var label: String = ""
    @Published var courseID: UUID? = nil
    @Published var assignmentID: UUID? = nil

    // Durations (minutes) — surfaced in Settings later.
    var focusMinutes = 25
    var shortBreakMinutes = 5
    var longBreakMinutes = 15
    var cyclesBeforeLongBreak = 4
    var autoStartNext = true

    var onComplete: ((Int, String, UUID?, UUID?) -> Void)?

    private var timer: AnyCancellable?

    var mmss: String {
        let m = remaining / 60, s = remaining % 60
        return String(format: "%02d:%02d", m, s)
    }

    func startFocus(label: String = "", courseID: UUID? = nil, assignmentID: UUID? = nil) {
        self.label = label
        self.courseID = courseID
        self.assignmentID = assignmentID
        phase = .focus
        remaining = focusMinutes * 60
        run()
        FocusAutomation.focusBegan()
    }

    func toggle() {
        if running { pause() }
        else if phase == .idle { startFocus() }
        else { run() }
    }

    func run() {
        running = true
        timer?.cancel()
        timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    func pause() {
        running = false
        timer?.cancel()
        if phase == .focus { FocusAutomation.focusEnded() }
    }

    func reset() {
        pause()
        phase = .idle
        remaining = focusMinutes * 60
    }

    func skip() { advancePhase() }

    private func tick() {
        guard remaining > 0 else { advancePhase(); return }
        remaining -= 1
    }

    private func advancePhase() {
        timer?.cancel()
        switch phase {
        case .focus:
            completedFocus += 1
            onComplete?(focusMinutes * 60, label, courseID, assignmentID)
            FocusAutomation.focusEnded()
            notify(title: "Focus done", body: "Time for a break.")
            let long = completedFocus % cyclesBeforeLongBreak == 0
            phase = long ? .longBreak : .shortBreak
            remaining = (long ? longBreakMinutes : shortBreakMinutes) * 60
        case .shortBreak, .longBreak:
            notify(title: "Break over", body: "Back to focus.")
            phase = .focus
            remaining = focusMinutes * 60
            FocusAutomation.focusBegan()
        case .idle:
            phase = .focus
            remaining = focusMinutes * 60
        }
        if running && autoStartNext { run() } else { running = false }
    }

    private func notify(title: String, body: String) {
        NSSound.beep()
        Notifier.post(title: title, body: body)
    }
}
