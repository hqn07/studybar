import SwiftUI

/// Dynamic menu bar label: icon, due-soon badge (8), or live pomodoro countdown (9).
struct MenuBarLabel: View {
    @EnvironmentObject var state: AppState
    let mode: MenuBarContent

    var body: some View {
        switch mode {
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
            if state.pomodoro.running {
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
}
