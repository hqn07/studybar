import SwiftUI

/// Dynamic menu bar label: icon, due-soon badge (8), or live pomodoro countdown (9).
struct MenuBarLabel: View {
    @EnvironmentObject var state: AppState
    let mode: MenuBarContent

    var body: some View {
        switch mode {
        case .smart:
            if state.voice.status == .recording {
                recordingLabel
            } else if state.pomodoro.running {
                Label(state.pomodoro.mmss, systemImage: "timer").labelStyle(.titleAndIcon).monospacedDigit()
            } else if let next = state.nextClassToday, next.minutesUntil <= 60 {
                Label(next.minutesUntil == 0 ? "now" : mins(next.minutesUntil), systemImage: "clock").labelStyle(.titleAndIcon)
            } else if state.dueSoonCount > 0 {
                Label("\(state.dueSoonCount)", systemImage: "graduationcap.fill").labelStyle(.titleAndIcon)
            } else if let next = state.nextClassToday {
                Label(mins(next.minutesUntil), systemImage: "clock").labelStyle(.titleAndIcon)
            } else {
                Image(systemName: "graduationcap.fill")
            }
        case .icon:
            Image(systemName: "graduationcap.fill")
        case .badge:
            let n = state.dueSoonCount
            if n > 0 {
                Label("\(n)", systemImage: "graduationcap.fill")
                    .labelStyle(.titleAndIcon)
            } else {
                Image(systemName: "graduationcap.fill")
            }
        case .timer:
            if state.voice.status == .recording {
                recordingLabel
            } else if state.pomodoro.running {
                Label(state.pomodoro.mmss, systemImage: "timer")
                    .labelStyle(.titleAndIcon)
                    .monospacedDigit()
            } else {
                Image(systemName: "graduationcap.fill")
            }
        case .nextClass:
            if let next = state.nextClassToday {
                let mins = next.minutesUntil
                let txt = mins == 0 ? "now" : (mins < 60 ? "\(mins)m" : "\(mins/60)h\(mins%60)m")
                Label(txt, systemImage: "clock")
                    .labelStyle(.titleAndIcon)
            } else {
                Image(systemName: "graduationcap.fill")
            }
        }
    }

    private func mins(_ m: Int) -> String { m < 60 ? "\(m)m" : "\(m / 60)h\(m % 60)m" }

    /// Live recording clock in the menu bar — takes priority over the pomodoro timer since a
    /// recording in progress is the most time-sensitive thing to keep visible.
    private var recordingLabel: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Label(recMMSS, systemImage: "record.circle")
                .labelStyle(.titleAndIcon).monospacedDigit().foregroundStyle(.red)
        }
    }
    private var recMMSS: String {
        let s = max(0, Int(Date().timeIntervalSince(state.voice.startedAt ?? Date())))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
