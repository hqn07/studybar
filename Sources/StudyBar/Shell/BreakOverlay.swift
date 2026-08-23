import SwiftUI

/// Full-cover break screen shown while a Pomodoro break is running.
struct BreakOverlay: View {
    @EnvironmentObject var state: AppState
    private var p: PomodoroEngine { state.pomodoro }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.green.opacity(0.35), Color.teal.opacity(0.25)],
                           startPoint: .top, endPoint: .bottom)
                .background(.regularMaterial)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "cup.and.saucer.fill").font(.system(size: 40)).foregroundStyle(.green)
                Text(p.phase == .longBreak ? "Long Break" : "Break").font(.title.bold())
                Text(p.mmss).font(.system(size: 56, weight: .bold, design: .rounded)).monospacedDigit()
                Text("Step away. Stretch, water, rest your eyes.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button { p.skip() } label: { Label("Skip break", systemImage: "forward.fill") }
                        .buttonStyle(.borderedProminent)
                    Button { p.reset() } label: { Label("End", systemImage: "stop.fill") }
                        .buttonStyle(.bordered)
                }
            }
            .padding(30)
        }
    }
}
