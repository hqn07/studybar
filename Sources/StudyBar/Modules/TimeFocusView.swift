import SwiftUI
import AppKit
import Combine

/// (D1) Unified **Time & Focus** module — Pomodoro, Stopwatch, Focus and session
/// History in one place, with an always-available ambient-noise bar.
///
/// The three timers share one clock hero — `TickDial` (bold task headline, big
/// rounded-mono digits, phase line, a row of depleting segment ticks) — so the
/// module reads as one system.
struct TimeFocusView: View {
    @EnvironmentObject var state: AppState
    @AppStorage("timeFocusTab") private var tabRaw = TimeTab.timer.rawValue
    @AppStorage("dailyGoal") private var dailyGoal = 8
    @StateObject private var stopwatch = StopwatchModel()   // hoisted so tab switches don't reset it
    @State private var showComplete = false
    @State private var completeDone = 0

    private var tab: TimeTab { TimeTab(rawValue: tabRaw) ?? .timer }
    private var p: PomodoroEngine { state.pomodoro }
    private var phaseTint: Color {
        switch p.phase { case .shortBreak, .longBreak: return .dsDone; default: return .accentColor }
    }

    var body: some View {
        ModulePane(title: "Time & Focus") {
            AmbientButton()
        } content: {
            VStack(spacing: 0) {
                Picker("", selection: $tabRaw) {
                    ForEach(TimeTab.allCases) { t in
                        Label(t.title, systemImage: t.symbol).tag(t.rawValue)
                    }
                }
                .pickerStyle(.segmented).labelStyle(.iconOnly)
                .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.s + 1)
                Divider()

                liveBanner

                Group {
                    switch tab {
                    case .timer:     PomodoroSection()
                    case .stopwatch: StopwatchSection(model: stopwatch)
                    case .focus:     FocusSection()
                    case .history:   SessionsSection()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()
                AmbientBar()
            }
        }
        .onChange(of: p.completedFocus) { old, new in
            guard new > old else { return }
            completeDone = StudyStats.pomodorosToday(state.data)
            withAnimation(.spring(response: 0.4)) { showComplete = true }
            Task {
                try? await Task.sleep(nanoseconds: 2_600_000_000)
                withAnimation { showComplete = false }
            }
        }
        .overlay(alignment: .bottom) { if showComplete { completeToast } }
    }

    /// Slim running-session strip shown on tabs that don't already display the live timer.
    @ViewBuilder private var liveBanner: some View {
        let busy = p.running || p.phase != .idle
        let showsTimer = tab == .timer || (tab == .focus && p.phase == .focus)
        if busy && !showsTimer {
            HStack(spacing: DS.Space.m) {
                Image(systemName: p.phase == .focus ? "timer" : "cup.and.saucer.fill")
                    .font(.caption).foregroundStyle(phaseTint).frame(width: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(p.label.isEmpty ? p.phase.rawValue : p.label)
                        .font(.caption.weight(.medium)).lineLimit(1)
                    if !p.label.isEmpty {
                        Text(p.phase.rawValue).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: DS.Space.s)
                Text(p.mmss).font(.callout.monospacedDigit().weight(.medium))
                Button { p.toggle() } label: { Image(systemName: p.running ? "pause.fill" : "play.fill") }
                    .buttonStyle(.borderless).help(p.running ? "Pause" : "Resume")
                Button { p.reset() } label: { Image(systemName: "stop.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("End")
            }
            .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.s)
            .background(phaseTint.opacity(0.10))
            .contentShape(Rectangle())
            .onTapGesture { tabRaw = TimeTab.timer.rawValue }
            Divider()
        }
    }

    private var completeToast: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: "checkmark.seal.fill").font(.title3).foregroundStyle(Color.dsDone)
            VStack(alignment: .leading, spacing: 1) {
                Text("Focus session complete").font(.callout.weight(.semibold))
                Text("+1 pomodoro · \(completeDone)/\(dailyGoal) today")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: DS.Space.s)
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(Color.dsDone.opacity(0.35)))
        .shadow(radius: 12)
        .padding(DS.Space.l).padding(.bottom, 44)   // clear the ambient bar
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

enum TimeTab: String, CaseIterable, Identifiable {
    case timer, stopwatch, focus, history
    var id: String { rawValue }
    var title: String {
        switch self { case .timer: "Timer"; case .stopwatch: "Stopwatch"; case .focus: "Focus"; case .history: "History" }
    }
    var symbol: String {
        switch self { case .timer: "timer"; case .stopwatch: "stopwatch"; case .focus: "moon.stars"; case .history: "clock.arrow.circlepath" }
    }
}

// MARK: - Shared clock hero: TickDial

/// Bold task headline (optional) · big rounded-mono digits · phase line · a row of
/// segment ticks. `progress` (0…1) is how much of the row stays lit — pass the
/// fraction *remaining* for a depleting countdown, or the fill fraction for a count-up.
struct TickDial: View {
    var title: String = ""
    let time: String
    var subtitle: String = ""
    var progress: Double
    var tint: Color = .accentColor
    var digitSize: CGFloat = 44
    var ticks: Int = 24

    var body: some View {
        VStack(spacing: DS.Space.s) {
            if !title.isEmpty {
                Text(title).font(.headline).multilineTextAlignment(.center).lineLimit(2)
            }
            Text(time)
                .font(.system(size: digitSize, weight: .bold, design: .rounded))
                .monospacedDigit().foregroundStyle(.primary)
            if !subtitle.isEmpty {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            TickRow(progress: progress, tint: tint, count: ticks).frame(height: 26)
        }
    }
}

/// A row of segment ticks; the leftmost `progress` share is lit and full-height.
private struct TickRow: View {
    var progress: Double
    var tint: Color
    var count: Int = 24

    var body: some View {
        let lit = Int((Double(count) * max(0, min(1, progress))).rounded())
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(0..<count, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(i < lit ? AnyShapeStyle(tint) : AnyShapeStyle(.quaternary))
                        .frame(maxWidth: .infinity)
                        .frame(height: i < lit ? geo.size.height : geo.size.height * 0.55)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .animation(.easeOut(duration: 0.3), value: lit)
        }
    }
}

/// Round icon control shared by the timers. `main` = filled accent hero button.
private func circleButton(_ icon: String, main: Bool = false, tint: Color = .accentColor,
                          disabled: Bool = false, help: String,
                          action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: icon)
            .font(.system(size: main ? 17 : 14, weight: .semibold))
            .frame(width: main ? 46 : 38, height: main ? 46 : 38)
            .background(main ? AnyShapeStyle(tint) : AnyShapeStyle(.background.secondary), in: Circle())
            .overlay { if !main { Circle().strokeBorder(.separator, lineWidth: 0.5) } }
            .foregroundStyle(main ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
    }
    .buttonStyle(.plain)
    .disabled(disabled)
    .opacity(disabled ? 0.4 : 1)
    .help(help)
}

// MARK: - Ambient noise (shared across tabs; owns FocusSounds)

private struct AmbientBar: View {
    @AppStorage("focusSound") private var soundRaw = FocusSounds.Kind.none.rawValue
    @AppStorage("focusVolume") private var volume = 0.5

    private var kind: FocusSounds.Kind { FocusSounds.Kind(rawValue: soundRaw) ?? .none }

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: kind == .none ? "speaker.slash" : "speaker.wave.2.fill")
                .font(.caption).foregroundStyle(kind == .none ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .frame(width: 16)
            Picker("", selection: $soundRaw) {
                ForEach(FocusSounds.Kind.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .onChange(of: soundRaw) { _, _ in apply() }
            if kind != .none {
                Slider(value: $volume, in: 0...1)
                    .frame(width: 70)
                    .onChange(of: volume) { _, v in FocusSounds.shared.setVolume(Float(v)) }
            }
        }
        .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.s)
    }

    private func apply() {
        if kind == .none { FocusSounds.shared.stop() }
        else { FocusSounds.shared.volume = Float(volume); FocusSounds.shared.play(kind) }
    }
}

private struct AmbientButton: View {
    @AppStorage("focusSound") private var soundRaw = FocusSounds.Kind.none.rawValue
    @AppStorage("focusVolume") private var volume = 0.5
    @AppStorage("focusLastSound") private var lastRaw = FocusSounds.Kind.white.rawValue

    private var kind: FocusSounds.Kind { FocusSounds.Kind(rawValue: soundRaw) ?? .none }

    var body: some View {
        Button {
            if kind == .none {
                soundRaw = FocusSounds.Kind(rawValue: lastRaw).map { $0 == .none ? .white : $0 }?.rawValue ?? FocusSounds.Kind.white.rawValue
                FocusSounds.shared.volume = Float(volume)
                FocusSounds.shared.play(FocusSounds.Kind(rawValue: soundRaw) ?? .white)
            } else {
                lastRaw = soundRaw
                soundRaw = FocusSounds.Kind.none.rawValue
                FocusSounds.shared.stop()
            }
        } label: {
            Image(systemName: kind == .none ? "speaker.slash" : "speaker.wave.2.fill")
        }
        .help(kind == .none ? "Play ambient noise" : "Mute ambient noise")
        .foregroundStyle(kind == .none ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
    }
}

// MARK: - Pomodoro

private struct PomodoroSection: View {
    @EnvironmentObject var state: AppState
    @State private var label = ""
    @State private var courseID: UUID? = nil
    @State private var assignmentID: UUID? = nil
    @State private var showSettings = false
    @State private var confirmReset = false

    @AppStorage("pomoFocus") private var focusMin = 25
    @AppStorage("pomoShort") private var shortMin = 5
    @AppStorage("pomoLong") private var longMin = 15
    @AppStorage("pomoCycles") private var cycles = 4
    @AppStorage("pomoAutostart") private var autostart = true
    @AppStorage("dailyGoal") private var dailyGoal = 8
    @AppStorage("focusStrict") private var strict = false

    private var p: PomodoroEngine { state.pomodoro }
    private var idle: Bool { p.phase == .idle }
    private var todaySeconds: Int {
        state.data.timeEntries.filter { Calendar.current.isDateInToday($0.date) }.reduce(0) { $0 + $1.seconds }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Space.l) {
                HStack {
                    Spacer()
                    Button { showSettings.toggle() } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.borderless).help("Timer settings")
                }
                if showSettings { settingsPanel }

                TickDial(title: idle ? "" : p.label, time: p.mmss, subtitle: phaseSub,
                         progress: fractionRemaining, tint: phaseTint, digitSize: 44)
                    .padding(.horizontal, DS.Space.s)

                if idle {
                    VStack(spacing: DS.Space.s) {
                        TextField("What are you working on?", text: $label)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                        HStack(spacing: DS.Space.m) {
                            CoursePicker(courseID: $courseID)
                            Divider().frame(height: 14)
                            AssignmentPicker(assignmentID: $assignmentID)
                        }
                    }
                }

                HStack(spacing: DS.Space.l) {
                    circleButton("stop.fill", disabled: idle, help: "End") { resetPressed() }
                    circleButton(p.running ? "pause.fill" : "play.fill", main: true, tint: phaseTint,
                                 help: p.running ? "Pause" : (idle ? "Start" : "Resume")) { toggle() }
                    circleButton("forward.fill", disabled: idle, help: "Skip") { p.skip() }
                }

                goalBar

                HStack(spacing: DS.Space.xl + DS.Space.m) {
                    stat("\(p.completedFocus)", "sessions")
                    stat(timeStr(todaySeconds), "today")
                }
            }
            .frame(maxWidth: .infinity).padding(DS.Space.l)
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

    private var phaseSub: String {
        switch p.phase {
        case .idle: return "Ready"
        case .focus: return "focus · \((p.completedFocus % max(1, cycles)) + 1) of \(cycles)"
        case .shortBreak: return "short break"
        case .longBreak: return "long break"
        }
    }
    private var phaseTint: Color {
        switch p.phase { case .shortBreak, .longBreak: return .dsDone; default: return .accentColor }
    }
    private var fractionRemaining: Double {
        let total: Int
        switch p.phase {
        case .focus, .idle: total = p.focusMinutes * 60
        case .shortBreak: total = p.shortBreakMinutes * 60
        case .longBreak: total = p.longBreakMinutes * 60
        }
        guard total > 0 else { return 0 }
        return Double(p.remaining) / Double(total)
    }

    private var goalBar: some View {
        let done = StudyStats.pomodorosToday(state.data)
        let hit = done >= dailyGoal
        return VStack(spacing: 3) {
            HStack {
                Text("Daily goal").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("\(done)/\(dailyGoal)").font(.caption2.bold())
                    .foregroundStyle(hit ? AnyShapeStyle(Color.dsDone) : AnyShapeStyle(.secondary))
                if hit { Image(systemName: "checkmark.seal.fill").font(.caption2).foregroundStyle(Color.dsDone) }
            }
            ProgressView(value: Double(min(done, dailyGoal)), total: Double(max(1, dailyGoal)))
                .tint(hit ? Color.dsDone : .accentColor)
        }.frame(maxWidth: 240)
    }

    private func resetPressed() {
        if strict && p.running && p.phase == .focus { confirmReset = true } else { p.reset() }
    }

    private var settingsPanel: some View {
        VStack(spacing: DS.Space.m) {
            Stepper("Focus: \(focusMin) min", value: $focusMin, in: 5...90, step: 5).font(.caption)
            Stepper("Short break: \(shortMin) min", value: $shortMin, in: 1...30, step: 1).font(.caption)
            Stepper("Long break: \(longMin) min", value: $longMin, in: 5...45, step: 5).font(.caption)
            Stepper("Long break every \(cycles) pomodoros", value: $cycles, in: 2...8).font(.caption)
            Stepper("Daily goal: \(dailyGoal) pomodoros", value: $dailyGoal, in: 1...20).font(.caption)
            Toggle("Auto-start next phase", isOn: $autostart).font(.caption)
            Toggle("Strict mode (confirm before ending)", isOn: $strict).font(.caption)
        }
        .padding(DS.Space.l)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .onChange(of: focusMin) { _, _ in applyConfig() }
        .onChange(of: shortMin) { _, _ in applyConfig() }
        .onChange(of: longMin) { _, _ in applyConfig() }
        .onChange(of: cycles) { _, _ in applyConfig() }
        .onChange(of: autostart) { _, _ in applyConfig() }
    }

    private func applyConfig() {
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
        if idle { p.focusMinutes = focusMin; p.startFocus(label: label, courseID: courseID, assignmentID: assignmentID) }
        else { p.toggle() }
    }
    private func stat(_ v: String, _ l: String) -> some View {
        VStack(spacing: 1) {
            Text(v).font(.title3.bold().monospacedDigit())
            Text(l).font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func timeStr(_ s: Int) -> String { let h = s/3600, m = (s%3600)/60; return h > 0 ? "\(h)h \(m)m" : "\(m)m" }
}

// MARK: - Stopwatch (state hoisted to survive tab switches)

final class StopwatchModel: ObservableObject {
    @Published var elapsed: TimeInterval = 0
    @Published var running = false
    @Published var laps: [TimeInterval] = []
    @Published var label = ""
    @Published var courseID: UUID?
    @Published var assignmentID: UUID?
    private var timer: AnyCancellable?

    func toggle() {
        running.toggle()
        if running {
            timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.elapsed += 0.1 }
        } else { timer?.cancel() }
    }
    func lap() { laps.append(elapsed) }
    func reset() { timer?.cancel(); running = false; elapsed = 0; laps = []; label = "" }
}

private struct StopwatchSection: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var model: StopwatchModel

    private struct Preset: Hashable { let label: String; let courseID: UUID?; let assignmentID: UUID? }
    private var recentPresets: [Preset] {
        var seen = Set<String>(); var out: [Preset] = []
        for e in state.data.timeEntries.filter({ $0.kind == "stopwatch" && !$0.label.isEmpty }).sorted(by: { $0.date > $1.date }) {
            if seen.insert(e.label.lowercased()).inserted {
                out.append(Preset(label: e.label, courseID: e.courseID, assignmentID: e.assignmentID))
            }
            if out.count >= 6 { break }
        }
        return out
    }

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Space.l) {
                TickDial(title: model.label, time: format(model.elapsed), subtitle: model.running ? "recording" : "",
                         progress: model.elapsed.truncatingRemainder(dividingBy: 60) / 60, tint: .accentColor, digitSize: 42)
                    .padding(.top, DS.Space.m)

                TextField("Label (e.g. Chem problem set)", text: $model.label)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                HStack(spacing: DS.Space.m) {
                    CoursePicker(courseID: $model.courseID)
                    Divider().frame(height: 14)
                    AssignmentPicker(assignmentID: $model.assignmentID)
                }

                if !recentPresets.isEmpty && model.elapsed < 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: DS.Space.s) {
                            ForEach(recentPresets, id: \.self) { preset in
                                Button {
                                    model.label = preset.label; model.courseID = preset.courseID; model.assignmentID = preset.assignmentID
                                } label: {
                                    Chip(preset.label, .tag, systemImage: "arrow.counterclockwise")
                                }.buttonStyle(.plain)
                            }
                        }.padding(.horizontal, DS.Space.l)
                    }
                }

                HStack(spacing: DS.Space.l) {
                    Button { model.lap() } label: { Text("Lap").frame(width: 42) }
                        .controlSize(.large).disabled(!model.running)
                    circleButton(model.running ? "pause.fill" : "play.fill", main: true,
                                 help: model.running ? "Pause" : "Start") { model.toggle() }
                    Button { saveAndReset() } label: { Text("Save").frame(width: 42) }
                        .controlSize(.large).disabled(model.elapsed < 1)
                }

                if !model.laps.isEmpty {
                    VStack(spacing: 3) {
                        ForEach(Array(model.laps.enumerated().reversed()), id: \.offset) { i, t in
                            HStack {
                                Text("Lap \(i + 1)").foregroundStyle(.secondary)
                                Spacer()
                                Text(format(t)).monospacedDigit()
                            }.font(.caption)
                            .padding(.horizontal, DS.Space.l).padding(.vertical, 2)
                        }
                    }.frame(maxHeight: 120)
                }
            }
            .frame(maxWidth: .infinity).padding(DS.Space.l)
        }
    }

    private func saveAndReset() {
        if model.elapsed >= 1 {
            let cid = model.courseID ?? state.data.assignments.first { $0.id == model.assignmentID }?.courseID
            state.data.timeEntries.append(
                TimeEntry(courseID: cid, assignmentID: model.assignmentID, label: model.label,
                          seconds: Int(model.elapsed), kind: "stopwatch"))
        }
        model.reset()
    }
    private func format(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        let cs = Int((t - Double(total)) * 10)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d.%d", m, s, cs)
    }
}

// MARK: - Focus (timer + hide-others; ambient noise handled by the bar)

private struct FocusSection: View {
    @EnvironmentObject var state: AppState
    @AppStorage("focusMinutes") private var minutes = 50
    @AppStorage("focusHideOthers") private var hideOthers = true
    @AppStorage("focusStrict") private var strict = false
    @State private var task = ""
    @State private var courseID: UUID? = nil
    @State private var assignmentID: UUID? = nil
    @State private var confirmEnd = false
    @State private var customLength = false

    private let presets = [25, 50, 90]
    private var p: PomodoroEngine { state.pomodoro }
    private var active: Bool { p.running && p.phase == .focus }

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Space.l) {
                if active {
                    Spacer(minLength: DS.Space.l)
                    TickDial(title: p.label.isEmpty ? "Focus" : p.label, time: p.mmss, subtitle: "focus",
                             progress: Double(p.remaining) / Double(max(1, minutes * 60)), tint: .accentColor, digitSize: 54)
                    Text("Stay on task. You've got this.").font(.callout).foregroundStyle(.secondary)
                    Button(role: .destructive) { endPressed() } label: {
                        Label("End focus", systemImage: "stop.fill")
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                } else {
                    VStack(spacing: DS.Space.xs) {
                        Image(systemName: "moon.stars.fill").font(.system(size: 30)).foregroundStyle(.tint)
                        Text("Focus Session").font(.title3.bold())
                    }.padding(.top, DS.Space.s)

                    TextField("What are you focusing on?", text: $task)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    HStack(spacing: DS.Space.m) {
                        CoursePicker(courseID: $courseID)
                        Divider().frame(height: 14)
                        AssignmentPicker(assignmentID: $assignmentID)
                    }

                    VStack(spacing: DS.Space.s) {
                        HStack(spacing: DS.Space.s) {
                            ForEach(presets, id: \.self) { m in
                                Button { minutes = m; customLength = false } label: {
                                    Chip("\(m)m", .filter, selected: !customLength && minutes == m)
                                }.buttonStyle(.plain)
                            }
                            Button { customLength = true } label: {
                                Chip("Custom", .filter, selected: customLength)
                            }.buttonStyle(.plain)
                        }
                        if customLength {
                            Stepper("\(minutes) min", value: $minutes, in: 5...180, step: 5)
                                .font(.caption).fixedSize()
                        }
                    }

                    VStack(spacing: 0) {
                        optionRow("Hide other apps on start", isOn: $hideOthers)
                        Divider()
                        optionRow("Strict mode", caption: "Confirm before ending", isOn: $strict)
                    }.frame(maxWidth: 280).dsCard(padding: 0)

                    Button { start() } label: {
                        Label("Start focusing", systemImage: "play.fill").frame(maxWidth: 200)
                    }.buttonStyle(.borderedProminent).controlSize(.large).padding(.top, DS.Space.xs)

                    Text("Tip: pair with a macOS Focus to silence notifications.")
                        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .padding(.horizontal, DS.Space.xl)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity).padding(DS.Space.l)
        }
        .onAppear { customLength = !presets.contains(minutes) }
        .overlay {
            if confirmEnd {
                ConfirmCard(title: "End focus early?", message: "Strict mode is on — you asked to see this.",
                            confirmLabel: "End focus",
                            onConfirm: { confirmEnd = false; p.reset() },
                            onCancel: { confirmEnd = false })
            }
        }
    }

    private func optionRow(_ title: String, caption: String? = nil, isOn: Binding<Bool>) -> some View {
        HStack(spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout)
                if let caption { Text(caption).font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer()
            Toggle("", isOn: isOn).labelsHidden()
        }
        .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)
    }

    private func endPressed() { if strict { confirmEnd = true } else { p.reset() } }
    private func start() {
        p.focusMinutes = minutes
        p.startFocus(label: task, courseID: courseID, assignmentID: assignmentID)
        if hideOthers { NSApp.hideOtherApplications(nil) }
    }
}

// MARK: - Session history

private struct SessionsSection: View {
    @EnvironmentObject var state: AppState
    @State private var renaming: TimeEntry?
    @State private var newLabel = ""

    private var grouped: [(Date, [TimeEntry])] {
        let dict = Dictionary(grouping: state.data.timeEntries) { Calendar.current.startOfDay(for: $0.date) }
        return dict.keys.sorted(by: >).map { ($0, dict[$0]!.sorted { $0.date > $1.date }) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if state.data.timeEntries.isEmpty {
                EmptyState(symbol: "clock.arrow.circlepath", title: "No sessions yet",
                           subtitle: "Completed Pomodoro, Focus and Stopwatch sessions are logged here.")
            } else {
                HStack {
                    Spacer()
                    Text(timeStr(StudyStats.secondsThisWeek(state.data)) + " this week")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, DS.Space.l).padding(.top, DS.Space.m)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Space.l) {
                        ForEach(grouped, id: \.0) { day, items in
                            VStack(alignment: .leading, spacing: DS.Space.s) {
                                HStack {
                                    SectionHeader(title: dayHeader(day))
                                    Spacer()
                                    Text(timeStr(items.reduce(0) { $0 + $1.seconds })).font(.caption).foregroundStyle(.secondary)
                                }.padding(.horizontal, DS.Space.l)
                                ForEach(items) { row($0) }
                            }
                        }
                    }.padding(.vertical, DS.Space.m)
                }
            }
        }
        .overlay {
            if renaming != nil {
                ZStack {
                    Color.black.opacity(0.28).ignoresSafeArea().onTapGesture { renaming = nil }
                    VStack(spacing: DS.Space.l) {
                        Text("Rename session").font(.headline)
                        TextField("Label", text: $newLabel).textFieldStyle(.roundedBorder)
                            .frame(width: 220).onSubmit { commitRename() }
                        HStack(spacing: DS.Space.m) {
                            Button("Cancel") { renaming = nil }.keyboardShortcut(.cancelAction)
                            Button("Save") { commitRename() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding(20).frame(maxWidth: 280)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.modal))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.modal).stroke(.separator)).shadow(radius: 20)
                }
            }
        }
    }

    private func row(_ e: TimeEntry) -> some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: kindIcon(e.kind)).frame(width: 18).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.label.isEmpty ? kindName(e.kind) : e.label).fontWeight(.medium).lineLimit(1)
                HStack(spacing: DS.Space.s) {
                    CourseChip(course: state.course(e.courseID))
                    if let a = state.data.assignments.first(where: { $0.id == e.assignmentID }) {
                        Text("· \(a.title)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(e.date.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Text(timeStr(e.seconds)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Menu {
                Button("Rename") { renaming = e; newLabel = e.label }
                Button("Delete", role: .destructive) { state.data.timeEntries.removeAll { $0.id == e.id } }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
        }
        .padding(DS.Space.m).background(.background.secondary, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .padding(.horizontal, DS.Space.l)
    }

    private func commitRename() {
        guard let e = renaming, let i = state.data.timeEntries.firstIndex(where: { $0.id == e.id }) else { return }
        state.data.timeEntries[i].label = newLabel
        renaming = nil
    }
    private func dayHeader(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return "Today" }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.wide).month().day())
    }
    private func kindIcon(_ k: String) -> String {
        switch k { case "stopwatch": return "stopwatch"; case "focus": return "moon.stars"; default: return "timer" }
    }
    private func kindName(_ k: String) -> String {
        switch k { case "stopwatch": return "Stopwatch"; case "focus": return "Focus"; default: return "Pomodoro" }
    }
    private func timeStr(_ s: Int) -> String {
        let h = s / 3600, m = (s % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(s)s"
    }
}
