import SwiftUI

/// Weighted grade "what-if" calculator: enter graded components, see your current
/// standing, and compute what you need on what's left to hit a target. Pure/offline.
struct GradeCalcView: View {
    @EnvironmentObject var state: AppState
    @State private var courseID: UUID?
    @AppStorage("gradeTarget") private var target = 90.0

    private var items: [GradeItem] {
        state.gradeItems.filter { $0.courseID == courseID }
    }
    private var graded: [GradeItem] { items.filter { $0.graded } }
    private var gradedWeight: Double { graded.reduce(0) { $0 + $1.weight } }
    private var ungradedWeight: Double { items.filter { !$0.graded }.reduce(0) { $0 + $1.weight } }
    private var totalWeight: Double { items.reduce(0) { $0 + $1.weight } }
    /// Percentage points of the final grade already earned.
    private var earnedPoints: Double { graded.reduce(0) { $0 + $1.weight * $1.score / 100 } }
    /// Current grade on the graded portion only.
    private var currentPct: Double { gradedWeight > 0 ? earnedPoints / gradedWeight * 100 : 0 }
    /// Score needed on the remaining (ungraded) weight to reach `target` overall.
    private var neededOnRest: Double? {
        guard ungradedWeight > 0 else { return nil }
        return (target - earnedPoints) / ungradedWeight * 100
    }
    private var neededMessage: (text: String, color: Color)? {
        guard let need = neededOnRest else { return nil }
        if need <= 0 { return ("Already secured — even a 0% on the rest keeps you at your target.", .green) }
        if need > 100 { return ("Not reachable with the remaining \(Int(ungradedWeight))% — the most you can finish with is \(String(format: "%.1f", earnedPoints + ungradedWeight))%.", .red) }
        return (String(format: "Need %.1f%% on the remaining %d%% to hit %d%%.", need, Int(ungradedWeight), Int(target)), .primary)
    }

    // MARK: projected GPA (all courses, from their graded components)

    private func coursePct(_ cid: UUID) -> Double? {
        let its = state.gradeItems.filter { $0.courseID == cid && $0.graded }
        let w = its.reduce(0) { $0 + $1.weight }
        guard w > 0 else { return nil }
        return its.reduce(0) { $0 + $1.weight * $1.score / 100 } / w * 100
    }
    private func gpaPoints(_ pct: Double) -> Double {
        switch pct {
        case 93...: 4.0; case 90..<93: 3.7; case 87..<90: 3.3; case 83..<87: 3.0
        case 80..<83: 2.7; case 77..<80: 2.3; case 73..<77: 2.0; case 70..<73: 1.7
        case 67..<70: 1.3; case 63..<67: 1.0; case 60..<63: 0.7; default: 0.0
        }
    }
    private var gpaCourses: [(course: Course, pct: Double)] {
        state.data.courses.compactMap { c in coursePct(c.id).map { (c, $0) } }
    }
    private var projectedGPA: Double? {
        let rows = gpaCourses
        let credits = rows.reduce(0) { $0 + $1.course.credits }
        guard credits > 0 else { return nil }
        return rows.reduce(0) { $0 + gpaPoints($1.pct) * $1.course.credits } / credits
    }

    private var gpaCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(projectedGPA.map { String(format: "%.2f", $0) } ?? "—")
                    .font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                Text("GPA").font(.title3.bold()).foregroundStyle(.tint)
                Spacer()
                Text("projected · \(gpaCourses.count) course\(gpaCourses.count == 1 ? "" : "s")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(gpaCourses, id: \.course.id) { row in
                HStack(spacing: DS.Space.s) {
                    Circle().fill(row.course.color).frame(width: 7, height: 7)
                    Text(row.course.code.isEmpty ? row.course.name : row.course.code)
                        .font(.caption).lineLimit(1)
                    Spacer()
                    Text(letter(row.pct)).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Text(String(format: "%.0f%%", row.pct)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(DS.Space.l).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }

    var body: some View {
        NavigationStack {
            ModulePane(title: "Grade Calc") {
                HStack(spacing: 8) {
                    CoursePicker(courseID: $courseID)
                    Button { add() } label: { Image(systemName: "plus") }
                }
            } content: {
                if state.data.courses.isEmpty {
                    EmptyState(symbol: "percent", title: "Add a course first",
                               subtitle: "Grade components attach to a course.")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if projectedGPA != nil { gpaCard }
                            summary
                            targetCard
                            componentsList
                        }.padding(12)
                    }
                }
            }
            .onAppear { if courseID == nil { courseID = state.data.courses.first?.id } }
        }
    }

    // MARK: summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(gradedWeight > 0 ? String(format: "%.1f%%", currentPct) : "—")
                    .font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                Text(gradedWeight > 0 ? letter(currentPct) : "")
                    .font(.title3.bold()).foregroundStyle(.tint)
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("current (graded portion)").font(.caption2).foregroundStyle(.secondary)
                    Text("\(Int(gradedWeight))% of grade graded").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if totalWeight != 100 && totalWeight > 0 {
                Label("Weights sum to \(Int(totalWeight))% — usually should be 100%.", systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.sbSurface, in: RoundedRectangle(cornerRadius: 10))
    }

    private var targetCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Target").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int(target))%").font(.subheadline.monospacedDigit()).foregroundStyle(.tint)
            }
            Slider(value: $target, in: 50...100, step: 1)
            if let m = neededMessage {
                Label(m.text, systemImage: "target").font(.caption).foregroundStyle(m.color)
            } else {
                Text("Mark a component as “not taken yet” to compute what you need on it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.sbSurface, in: RoundedRectangle(cornerRadius: 10))
    }

    private var componentsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("COMPONENTS").font(.caption2.bold()).foregroundStyle(.secondary)
            if items.isEmpty {
                Text("No components yet. Tap + to add exams, homework, projects with their weights.")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 6)
            } else {
                ForEach(items) { item in row(item) }
            }
        }
    }

    private func row(_ item: GradeItem) -> some View {
        let b = binding(item.id)
        return VStack(spacing: 6) {
            HStack(spacing: 8) {
                TextField("Component (e.g. Midterm)", text: b.name).textFieldStyle(.plain).fontWeight(.medium)
                Button(role: .destructive) { remove(item.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).font(.caption)
            }
            HStack(spacing: 10) {
                field("Weight", b.weight, suffix: "%")
                if item.graded { field("Score", b.score, suffix: "%") }
                Toggle("Taken", isOn: b.graded).toggleStyle(.button).controlSize(.small).font(.caption)
            }
        }
        .padding(10).background(Color.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }

    private func field(_ label: String, _ value: Binding<Double>, suffix: String) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            TextField(label, value: value, format: .number).textFieldStyle(.roundedBorder)
                .frame(width: 54).multilineTextAlignment(.trailing)
            Text(suffix).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: mutations

    private func binding(_ id: UUID) -> Binding<GradeItem> {
        Binding(
            get: { state.gradeItems.first(where: { $0.id == id }) ?? GradeItem() },
            set: { nv in if let i = state.gradeItems.firstIndex(where: { $0.id == id }) { state.gradeItems[i] = nv } })
    }
    private func add() {
        var g = GradeItem(courseID: courseID)
        g.graded = true
        state.gradeItems.append(g)
    }
    private func remove(_ id: UUID) {
        state.gradeItems.removeAll { $0.id == id }
    }

    private func letter(_ pct: Double) -> String {
        switch pct {
        case 93...:    return "A"
        case 90..<93:  return "A−"
        case 87..<90:  return "B+"
        case 83..<87:  return "B"
        case 80..<83:  return "B−"
        case 77..<80:  return "C+"
        case 73..<77:  return "C"
        case 70..<73:  return "C−"
        case 67..<70:  return "D+"
        case 63..<67:  return "D"
        case 60..<63:  return "D−"
        default:       return "F"
        }
    }
}
