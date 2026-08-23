import SwiftUI
import AppKit

struct FocusView: View {
    @EnvironmentObject var state: AppState
    @AppStorage("focusMinutes") private var minutes = 50
    @AppStorage("focusHideOthers") private var hideOthers = true
    @AppStorage("focusSound") private var soundRaw = FocusSounds.Kind.none.rawValue
    @AppStorage("focusVolume") private var volume = 0.5
    @AppStorage("focusStrict") private var strict = false
    @State private var task = ""
    @State private var courseID: UUID? = nil
    @State private var assignmentID: UUID? = nil
    @State private var previewing = false
    @State private var confirmEnd = false

    private var p: PomodoroEngine { state.pomodoro }
    private var active: Bool { p.running && p.phase == .focus }

    var body: some View {
        ModulePane(title: "Focus") {
            EmptyView()
        } content: {
            VStack(spacing: 18) {
                if active {
                    Spacer()
                    Text(p.mmss).font(.system(size: 60, weight: .bold, design: .rounded)).monospacedDigit()
                    if !p.label.isEmpty { Text(p.label).font(.title3).foregroundStyle(.secondary) }
                    Text("Stay on task. You've got this.").font(.callout).foregroundStyle(.secondary)
                    if soundKind != .none {
                        volumeSlider.frame(maxWidth: 240)
                    }
                    Button(role: .destructive) { endPressed() } label: {
                        Label("End focus", systemImage: "stop.fill")
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                    Spacer()
                } else {
                    Spacer()
                    Image(systemName: "moon.stars.fill").font(.system(size: 40)).foregroundStyle(.tint)
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
                            Button("\(m)m") { minutes = m }
                                .buttonStyle(.bordered)
                                .tint(minutes == m ? .accentColor : .secondary)
                        }
                        Stepper("\(minutes)m", value: $minutes, in: 5...180, step: 5).fixedSize()
                    }
                    Toggle("Hide other apps when I start", isOn: $hideOthers)
                        .toggleStyle(.switch).frame(maxWidth: 260)
                    Toggle("Strict mode (confirm before ending)", isOn: $strict)
                        .toggleStyle(.switch).frame(maxWidth: 260)
                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "speaker.wave.2").font(.caption).foregroundStyle(.secondary)
                            Picker("Ambient sound", selection: $soundRaw) {
                                ForEach(FocusSounds.Kind.allCases) { Text($0.rawValue).tag($0.rawValue) }
                            }.labelsHidden().fixedSize()
                            .onChange(of: soundRaw) { _, _ in if previewing { startPreview() } }
                            if soundKind != .none {
                                Button { togglePreview() } label: {
                                    Image(systemName: previewing ? "stop.circle" : "play.circle")
                                }.buttonStyle(.borderless).help(previewing ? "Stop preview" : "Preview")
                            }
                        }
                        if soundKind != .none { volumeSlider.frame(maxWidth: 240) }
                    }
                    Button { start() } label: {
                        Label("Start focusing", systemImage: "play.fill").frame(maxWidth: 200)
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                    Text("Tip: pair with a macOS Focus (Control Center) to silence notifications — apps can't toggle that for you.")
                        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity)
            .padding(16)
        }
        .onDisappear { if previewing { stopPreview() } }
        .overlay {
            if confirmEnd {
                ConfirmCard(title: "End focus early?", message: "Strict mode is on — you asked to see this.",
                            confirmLabel: "End focus",
                            onConfirm: { confirmEnd = false; endFocus() },
                            onCancel: { confirmEnd = false })
            }
        }
    }

    private func endPressed() {
        if strict { confirmEnd = true } else { endFocus() }
    }
    private func endFocus() {
        p.reset(); FocusSounds.shared.stop()
    }

    private var soundKind: FocusSounds.Kind { FocusSounds.Kind(rawValue: soundRaw) ?? .none }

    private var volumeSlider: some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker.fill").font(.caption2).foregroundStyle(.secondary)
            Slider(value: $volume, in: 0...1)
                .onChange(of: volume) { _, v in FocusSounds.shared.setVolume(Float(v)) }
            Image(systemName: "speaker.wave.3.fill").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func togglePreview() {
        previewing ? stopPreview() : startPreview()
    }
    private func startPreview() {
        guard soundKind != .none else { return }
        FocusSounds.shared.volume = Float(volume)
        FocusSounds.shared.play(soundKind)
        previewing = true
    }
    private func stopPreview() {
        FocusSounds.shared.stop()
        previewing = false
    }

    private func start() {
        previewing = false
        p.focusMinutes = minutes
        p.startFocus(label: task, courseID: courseID, assignmentID: assignmentID)
        if hideOthers { NSApp.hideOtherApplications(nil) }
        if soundKind != .none {
            FocusSounds.shared.volume = Float(volume)
            FocusSounds.shared.play(soundKind)
        }
    }
}
