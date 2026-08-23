import SwiftUI

struct PomodoroView: View {
    @EnvironmentObject var state: AppState
    @State private var label = ""
    @State private var courseID: UUID? = nil
    @State private var assignmentID: UUID? = nil
    @State private var showSettings = false
    @State private var confirmReset = false

    // Persisted, adjustable durations.
    @AppStorage("pomoFocus") private var focusMin = 25
    @AppStorage("pomoShort") private var shortMin = 5
    @AppStorage("pomoLong") private var longMin = 15
    @AppStorage("pomoCycles") private var cycles = 4
    @AppStorage("pomoAutostart") private var autostart = true
    @AppStorage("dailyGoal") private var dailyGoal = 8
    @AppStorage("focusStrict") private var strict = false
    @AppStorage("breakScreen") private var breakScreen = true

    private var p: PomodoroEngine { state.pomodoro }

    private var todaySeconds: Int {
        state.data.timeEntries.filter { Calendar.current.isDateInToday($0.date) }.reduce(0) { $0 + $1.seconds }
    }

    var body: some View {
        ModulePane(title: "Pomodoro") {
            HStack(spacing: 8) {
                Text(p.phase.rawValue).font(.caption).foregroundStyle(.secondary)
                Button { showSettings.toggle() } label: { Image(systemName: "gearshape") }
                    .help("Timer settings")
            }
        } content: {
            VStack(spacing: 16) {
                if showSettings { settingsPanel }

                ZStack {
                    Circle().stroke(.quaternary, lineWidth: 10)
                    Circle().trim(from: 0, to: progress)
                        .stroke(phaseColor, style: .init(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.3), value: p.remaining)
                    VStack(spacing: 2) {
                        Text(p.mmss).font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                        Text(p.phase == .idle ? "Ready" : p.phase.rawValue)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 160, height: 160)

                cycleDots

                VStack(spacing: 6) {
                    TextField("What are you working on?", text: $label)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                    HStack(spacing: 10) {
                        CoursePicker(courseID: $courseID)
                        Divider().frame(height: 14)
                        AssignmentPicker(assignmentID: $assignmentID)
                    }
                }

                HStack(spacing: 14) {
                    VStack(spacing: 3) {
                        Button { resetPressed() } label: {
                            Image(systemName: "stop.fill").frame(width: 24)
                        }.controlSize(.large).disabled(p.phase == .idle).help("End session (back to Ready)")
                        Text("End").font(.caption2).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 3) {
                        Button { toggle() } label: {
                            Image(systemName: p.running ? "pause.fill" : "play.fill").frame(width: 30)
                        }.controlSize(.large).buttonStyle(.borderedProminent)
                        Text(p.running ? "Pause" : (p.phase == .idle ? "Start" : "Resume"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 3) {
                        Button { p.skip() } label: {
                            Image(systemName: "forward.fill").frame(width: 24)
                        }.controlSize(.large).disabled(p.phase == .idle).help("Skip to next phase (focus ⇄ break)")
                        Text("Skip").font(.caption2).foregroundStyle(.secondary)
                    }
                }

                goalBar

                HStack(spacing: 24) {
                    stat("\(p.completedFocus)", "session")
                    stat(timeStr(todaySeconds), "today")
                }
                Spacer()
            }
            .frame(maxWidth: .infinity).padding(16)
        }
        .onAppear(perform: applyConfig)
        .overlay {
            if confirmReset {
                ConfirmCard(title: "End this focus session?", message: "Strict mode is on.",
                            confirmLabel: "End session",
                            onConfirm: { p.reset(); confirmReset = false },
                            onCancel: { confirmReset = false })
            }
        }
    }

    private var goalBar: some View {
        let done = StudyStats.pomodorosToday(state.data)
        return VStack(spacing: 3) {
            HStack {
                Text("Daily goal").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("\(done)/\(dailyGoal)").font(.caption2.bold())
                    .foregroundStyle(done >= dailyGoal ? .green : .secondary)
                if done >= dailyGoal { Image(systemName: "checkmark.seal.fill").font(.caption2).foregroundStyle(.green) }
            }
            ProgressView(value: Double(min(done, dailyGoal)), total: Double(max(1, dailyGoal)))
        }.frame(maxWidth: 240)
    }

    private func resetPressed() {
        if strict && p.running && p.phase == .focus { confirmReset = true } else { p.reset() }
    }

    private var settingsPanel: some View {
        VStack(spacing: 8) {
            durationStepper("Focus", $focusMin, 5...90, 5)
            durationStepper("Short break", $shortMin, 1...30, 1)
            durationStepper("Long break", $longMin, 5...45, 5)
            Stepper("Long break every \(cycles) pomodoros", value: $cycles, in: 2...8)
                .font(.caption)
            Stepper("Daily goal: \(dailyGoal) pomodoros", value: $dailyGoal, in: 1...20).font(.caption)
            Toggle("Auto-start next phase", isOn: $autostart).font(.caption)
            Toggle("Strict mode (confirm before ending)", isOn: $strict).font(.caption)
            Toggle("Full-screen break screen", isOn: $breakScreen).font(.caption)
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .onChange(of: focusMin) { _, _ in applyConfig() }
        .onChange(of: shortMin) { _, _ in applyConfig() }
        .onChange(of: longMin) { _, _ in applyConfig() }
        .onChange(of: cycles) { _, _ in applyConfig() }
        .onChange(of: autostart) { _, _ in applyConfig() }
    }

    private func durationStepper(_ label: String, _ v: Binding<Int>, _ range: ClosedRange<Int>, _ step: Int) -> some View {
        Stepper("\(label): \(v.wrappedValue) min", value: v, in: range, step: step).font(.caption)
    }

    private var cycleDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<max(1, cycles), id: \.self) { i in
                Circle()
                    .fill(i < (p.completedFocus % cycles) ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: 7, height: 7)
            }
        }
    }

    private func applyConfig() {
        // Only mutate lengths when idle so a running timer isn't disrupted.
        p.shortBreakMinutes = shortMin
        p.longBreakMinutes = longMin
        p.cyclesBeforeLongBreak = cycles
        p.autoStartNext = autostart
        if p.phase == .idle {
            p.focusMinutes = focusMin
            if !p.running { p.remaining = focusMin * 60 }
        }
    }

    private func toggle() {
        if p.phase == .idle { p.focusMinutes = focusMin; p.startFocus(label: label, courseID: courseID, assignmentID: assignmentID) }
        else { p.toggle() }
    }

    private var progress: CGFloat {
        let total: Int
        switch p.phase {
        case .focus, .idle: total = p.focusMinutes * 60
        case .shortBreak: total = p.shortBreakMinutes * 60
        case .longBreak: total = p.longBreakMinutes * 60
        }
        guard total > 0 else { return 0 }
        return 1 - CGFloat(p.remaining) / CGFloat(total)
    }

    private var phaseColor: Color {
        switch p.phase { case .focus, .idle: return .accentColor; default: return .green }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.title3.bold().monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func timeStr(_ s: Int) -> String {
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}
