import SwiftUI
import AppKit
import Combine

/// (D1) Unified **Time & Focus** module — Pomodoro, Stopwatch, Focus and session
/// History in one place, with an always-available ambient-noise bar so you can
/// start a timer *and* play background noise without switching modules.
///
/// Replaces the four separate modules (pomodoro/stopwatch/focus/sessions).
struct TimeFocusView: View {
    @EnvironmentObject var state: AppState
    @AppStorage("timeFocusTab") private var tabRaw = TimeTab.timer.rawValue
    // Stopwatch lives on the parent so switching tabs doesn't reset a running clock.
    @StateObject private var stopwatch = StopwatchModel()

    private var tab: TimeTab { TimeTab(rawValue: tabRaw) ?? .timer }

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
                .padding(.horizontal, 10).padding(.vertical, 7)
                Divider()

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

// MARK: - Ambient noise (shared across tabs; owns FocusSounds)

/// Compact ambient-sound bar pinned to the bottom of the module. Independent of
/// the Pomodoro/Focus lifecycle so noise keeps playing while you switch tabs.
private struct AmbientBar: View {
    @AppStorage("focusSound") private var soundRaw = FocusSounds.Kind.none.rawValue
    @AppStorage("focusVolume") private var volume = 0.5

    private var kind: FocusSounds.Kind { FocusSounds.Kind(rawValue: soundRaw) ?? .none }

    var body: some View {
        HStack(spacing: 8) {
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
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func apply() {
        if kind == .none { FocusSounds.shared.stop() }
        else { FocusSounds.shared.volume = Float(volume); FocusSounds.shared.play(kind) }
    }
}

/// Header speaker toggle — quick mute/unmute of the ambient bar's current sound.
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
    private var todaySeconds: Int {
        state.data.timeEntries.filter { Calendar.current.isDateInToday($0.date) }.reduce(0) { $0 + $1.seconds }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    Text(p.phase == .idle ? "Ready" : p.phase.rawValue).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { showSettings.toggle() } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.borderless).help("Timer settings")
                }
                if showSettings { settingsPanel }

                ZStack {
                    Circle().stroke(.quaternary, lineWidth: 10)
                    Circle().trim(from: 0, to: progress)
                        .stroke(phaseColor, style: .init(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.3), value: p.remaining)
                    VStack(spacing: 2) {
                        Text(p.mmss).font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                        Text(p.phase == .idle ? "Ready" : p.phase.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 150, height: 150)

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
                    labeledButton("End", "stop.fill", 24, prominent: false, disabled: p.phase == .idle) { resetPressed() }
                    labeledButton(p.running ? "Pause" : (p.phase == .idle ? "Start" : "Resume"),
                                  p.running ? "pause.fill" : "play.fill", 30, prominent: true, disabled: false) { toggle() }
                    labeledButton("Skip", "forward.fill", 24, prominent: false, disabled: p.phase == .idle) { p.skip() }
                }

                goalBar

                HStack(spacing: 24) {
                    stat("\(p.completedFocus)", "session")
                    stat(timeStr(todaySeconds), "today")
                }
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

    private func labeledButton(_ title: String, _ icon: String, _ w: CGFloat, prominent: Bool, disabled: Bool, action: @escaping () -> Void) -> some View {
        VStack(spacing: 3) {
            Button(action: action) { Image(systemName: icon).frame(width: w) }
                .controlSize(.large).disabled(disabled)
                .modifier(ProminentIf(on: prominent))
            Text(title).font(.caption2).foregroundStyle(.secondary)
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
            Stepper("Focus: \(focusMin) min", value: $focusMin, in: 5...90, step: 5).font(.caption)
            Stepper("Short break: \(shortMin) min", value: $shortMin, in: 1...30, step: 1).font(.caption)
            Stepper("Long break: \(longMin) min", value: $longMin, in: 5...45, step: 5).font(.caption)
            Stepper("Long break every \(cycles) pomodoros", value: $cycles, in: 2...8).font(.caption)
            Stepper("Daily goal: \(dailyGoal) pomodoros", value: $dailyGoal, in: 1...20).font(.caption)
            Toggle("Auto-start next phase", isOn: $autostart).font(.caption)
            Toggle("Strict mode (confirm before ending)", isOn: $strict).font(.caption)
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .onChange(of: focusMin) { _, _ in applyConfig() }
        .onChange(of: shortMin) { _, _ in applyConfig() }
        .onChange(of: longMin) { _, _ in applyConfig() }
        .onChange(of: cycles) { _, _ in applyConfig() }
        .onChange(of: autostart) { _, _ in applyConfig() }
    }

    private var cycleDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<max(1, cycles), id: \.self) { i in
                Circle().fill(i < (p.completedFocus % cycles) ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: 7, height: 7)
            }
        }
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
    private var phaseColor: Color { switch p.phase { case .focus, .idle: .accentColor; default: .green } }
    private func stat(_ v: String, _ l: String) -> some View {
        VStack(spacing: 1) {
            Text(v).font(.title3.bold().monospacedDigit())
            Text(l).font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func timeStr(_ s: Int) -> String { let h = s/3600, m = (s%3600)/60; return h > 0 ? "\(h)h \(m)m" : "\(m)m" }
}

private struct ProminentIf: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
    }
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
        VStack(spacing: 16) {
            Text(format(model.elapsed))
                .font(.system(size: 46, weight: .bold, design: .rounded)).monospacedDigit()
                .padding(.top, 20)
            TextField("Label (e.g. Chem problem set)", text: $model.label)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
            HStack(spacing: 10) {
                CoursePicker(courseID: $model.courseID)
                Divider().frame(height: 14)
                AssignmentPicker(assignmentID: $model.assignmentID)
            }
            if !recentPresets.isEmpty && model.elapsed < 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(recentPresets, id: \.self) { preset in
                            Button {
                                model.label = preset.label; model.courseID = preset.courseID; model.assignmentID = preset.assignmentID
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.counterclockwise").font(.caption2)
                                    Text(preset.label).font(.caption).lineLimit(1)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(.background.secondary, in: Capsule())
                            }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 14)
                }
            }
            HStack(spacing: 14) {
                Button { model.lap() } label: { Text("Lap").frame(width: 44) }
                    .controlSize(.large).disabled(!model.running)
                Button { model.toggle() } label: {
                    Image(systemName: model.running ? "pause.fill" : "play.fill").frame(width: 30)
                }.controlSize(.large).buttonStyle(.borderedProminent)
                Button { saveAndReset() } label: { Text("Save").frame(width: 44) }
                    .controlSize(.large).disabled(model.elapsed < 1)
            }
            if !model.laps.isEmpty {
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(Array(model.laps.enumerated().reversed()), id: \.offset) { i, t in
                            HStack {
                                Text("Lap \(i + 1)").foregroundStyle(.secondary)
                                Spacer()
                                Text(format(t)).monospacedDigit()
                            }.font(.caption).padding(.horizontal, 12).padding(.vertical, 2)
                        }
                    }
                }.frame(maxHeight: 120)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
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

    private var p: PomodoroEngine { state.pomodoro }
    private var active: Bool { p.running && p.phase == .focus }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if active {
                    Spacer(minLength: 20)
                    Text(p.mmss).font(.system(size: 60, weight: .bold, design: .rounded)).monospacedDigit()
                    if !p.label.isEmpty { Text(p.label).font(.title3).foregroundStyle(.secondary) }
                    Text("Stay on task. You've got this.").font(.callout).foregroundStyle(.secondary)
                    Button(role: .destructive) { endPressed() } label: {
                        Label("End focus", systemImage: "stop.fill")
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                } else {
                    Image(systemName: "moon.stars.fill").font(.system(size: 38)).foregroundStyle(.tint).padding(.top, 8)
                    Text("Focus Session").font(.title2.bold())
                    TextField("What are you focusing on?", text: $task)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    HStack(spacing: 10) {
                        CoursePicker(courseID: $courseID)
                        Divider().frame(height: 14)
                        AssignmentPicker(assignmentID: $assignmentID)
                    }
                    HStack(spacing: 8) {
                        ForEach([25, 50, 90], id: \.self) { m in
                            Button("\(m)m") { minutes = m }.buttonStyle(.bordered)
                                .tint(minutes == m ? .accentColor : .secondary)
                        }
                        Stepper("\(minutes)m", value: $minutes, in: 5...180, step: 5).fixedSize()
                    }
                    Toggle("Hide other apps when I start", isOn: $hideOthers).toggleStyle(.switch).frame(maxWidth: 260)
                    Toggle("Strict mode (confirm before ending)", isOn: $strict).toggleStyle(.switch).frame(maxWidth: 260)
                    Button { start() } label: {
                        Label("Start focusing", systemImage: "play.fill").frame(maxWidth: 200)
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                    Text("Tip: pair with a macOS Focus (Control Center) to silence notifications, and use the ambient bar below for background noise.")
                        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 20)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity).padding(16)
        }
        .overlay {
            if confirmEnd {
                ConfirmCard(title: "End focus early?", message: "Strict mode is on — you asked to see this.",
                            confirmLabel: "End focus",
                            onConfirm: { confirmEnd = false; p.reset() },
                            onCancel: { confirmEnd = false })
            }
        }
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
                }.padding(.horizontal, 12).padding(.top, 8)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(grouped, id: \.0) { day, items in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(dayHeader(day)).font(.caption.bold())
                                        .foregroundStyle(Calendar.current.isDateInToday(day) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                    Spacer()
                                    Text(timeStr(items.reduce(0) { $0 + $1.seconds })).font(.caption).foregroundStyle(.secondary)
                                }.padding(.horizontal, 12)
                                ForEach(items) { row($0) }
                            }
                        }
                    }.padding(.vertical, 10)
                }
            }
        }
        .overlay {
            if renaming != nil {
                ZStack {
                    Color.black.opacity(0.28).ignoresSafeArea().onTapGesture { renaming = nil }
                    VStack(spacing: 12) {
                        Text("Rename session").font(.headline)
                        TextField("Label", text: $newLabel).textFieldStyle(.roundedBorder)
                            .frame(width: 220).onSubmit { commitRename() }
                        HStack(spacing: 10) {
                            Button("Cancel") { renaming = nil }.keyboardShortcut(.cancelAction)
                            Button("Save") { commitRename() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding(20).frame(maxWidth: 280)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator)).shadow(radius: 20)
                }
            }
        }
    }

    private func row(_ e: TimeEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: kindIcon(e.kind)).frame(width: 18).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.label.isEmpty ? kindName(e.kind) : e.label).fontWeight(.medium).lineLimit(1)
                HStack(spacing: 6) {
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
        .padding(10).background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 10)
    }

    private func commitRename() {
        guard let e = renaming, let i = state.data.timeEntries.firstIndex(where: { $0.id == e.id }) else { return }
        state.data.timeEntries[i].label = newLabel
        renaming = nil
    }
    private func dayHeader(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return "TODAY" }
        if Calendar.current.isDateInYesterday(d) { return "YESTERDAY" }
        return d.formatted(.dateTime.weekday(.wide).month().day()).uppercased()
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
