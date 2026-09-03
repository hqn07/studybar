import SwiftUI

/// A weekly study-time goal — a single number of minutes the student aims to study each week,
/// stored in defaults (0 = no goal set). Gives the streak something to *reach*, and the ring
/// below renders progress toward it. Deterministic; no model involved.
enum StudyGoal {
    static let key = "weeklyStudyGoalMinutes"
    /// Preset goals offered in the picker, in minutes (5h … 25h per week).
    static let presets = [300, 600, 900, 1200, 1500]
    static func label(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}

/// A circular progress ring: how much of the weekly goal has been studied. Fills the accent as
/// it climbs and swaps to a check when the goal is reached.
struct WeeklyGoalRing: View {
    let doneMinutes: Int
    let goalMinutes: Int
    var size: CGFloat = 46
    var line: CGFloat = 5

    private var progress: Double {
        goalMinutes > 0 ? min(1, Double(doneMinutes) / Double(goalMinutes)) : 0
    }
    private var reached: Bool { goalMinutes > 0 && doneMinutes >= goalMinutes }

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.18), lineWidth: line)
            Circle().trim(from: 0, to: progress)
                .stroke(reached ? Color.dsDone : Color.accentColor,
                        style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.snappy, value: progress)
            if reached {
                Image(systemName: "checkmark").font(.system(size: size * 0.34, weight: .bold))
                    .foregroundStyle(Color.dsDone)
            } else {
                Text("\(Int(progress * 100))%")
                    .font(.system(size: size * 0.26, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(goalMinutes > 0
            ? "Weekly goal \(Int(progress * 100)) percent, \(StudyGoal.label(doneMinutes)) of \(StudyGoal.label(goalMinutes))"
            : "No weekly goal set")
    }
}

/// The menu of goal choices, shared by Today and Insights. Binds straight to the stored value.
struct WeeklyGoalMenu: View {
    @Binding var goalMinutes: Int
    var body: some View {
        ForEach(StudyGoal.presets, id: \.self) { p in
            Button { goalMinutes = p } label: {
                if goalMinutes == p { Label("\(StudyGoal.label(p)) / week", systemImage: "checkmark") }
                else { Text("\(StudyGoal.label(p)) / week") }
            }
        }
        if goalMinutes > 0 {
            Divider()
            Button("Turn off goal", role: .destructive) { goalMinutes = 0 }
        }
    }
}
