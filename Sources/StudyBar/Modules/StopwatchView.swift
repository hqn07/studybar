import SwiftUI
import Combine

struct StopwatchView: View {
    @EnvironmentObject var state: AppState
    @State private var elapsed: TimeInterval = 0
    @State private var running = false
    @State private var laps: [TimeInterval] = []
    @State private var label = ""
    @State private var courseID: UUID?
    @State private var assignmentID: UUID?
    @State private var startDate: Date?
    @State private var timer: AnyCancellable?

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
        ModulePane(title: "Stopwatch") {
            HStack(spacing: 10) {
                CoursePicker(courseID: $courseID)
                AssignmentPicker(assignmentID: $assignmentID)
            }
        } content: {
            VStack(spacing: 16) {
                Text(format(elapsed))
                    .font(.system(size: 46, weight: .bold, design: .rounded)).monospacedDigit()
                    .padding(.top, 20)
                TextField("Label (e.g. Chem problem set)", text: $label)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                if !recentPresets.isEmpty && elapsed < 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(recentPresets, id: \.self) { preset in
                                Button {
                                    label = preset.label; courseID = preset.courseID; assignmentID = preset.assignmentID
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
                    Button { lap() } label: { Text("Lap").frame(width: 44) }
                        .controlSize(.large).disabled(!running)
                    Button { toggle() } label: {
                        Image(systemName: running ? "pause.fill" : "play.fill").frame(width: 30)
                    }.controlSize(.large).buttonStyle(.borderedProminent)
                    Button { saveAndReset() } label: { Text("Save").frame(width: 44) }
                        .controlSize(.large).disabled(elapsed < 1)
                }
                if !laps.isEmpty {
                    ScrollView {
                        VStack(spacing: 3) {
                            ForEach(Array(laps.enumerated().reversed()), id: \.offset) { i, t in
                                HStack {
                                    Text("Lap \(i + 1)").foregroundStyle(.secondary)
                                    Spacer()
                                    Text(format(t)).monospacedDigit()
                                }.font(.caption).padding(.horizontal, 12).padding(.vertical, 2)
                            }
                        }
                    }.frame(maxHeight: 140)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .onDisappear { timer?.cancel() }
        }
    }

    private func toggle() {
        running.toggle()
        if running {
            if startDate == nil { startDate = .now }
            timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
                .sink { _ in elapsed += 0.1 }
        } else {
            timer?.cancel()
        }
    }

    private func lap() { laps.append(elapsed) }

    private func saveAndReset() {
        timer?.cancel(); running = false
        if elapsed >= 1 {
            let cid = courseID ?? state.data.assignments.first { $0.id == assignmentID }?.courseID
            state.data.timeEntries.append(
                TimeEntry(courseID: cid, assignmentID: assignmentID, label: label,
                          seconds: Int(elapsed), kind: "stopwatch"))
        }
        elapsed = 0; laps = []; label = ""; startDate = nil
    }

    private func format(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        let cs = Int((t - Double(total)) * 10)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%02d:%02d.%d", m, s, cs)
    }
}
