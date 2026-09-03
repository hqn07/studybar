import SwiftUI

/// A focused "plan this day" surface, summoned from a day on the Schedule. It reuses the
/// same propose→accept machinery as Today's "Plan my day" (`DailyPlan.plan`), but anchored
/// to an arbitrary date: candidates and their reasons are computed relative to *that* day,
/// and accepted blocks land on that day's plan — not today's.
struct PlanDaySheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let date: Date

    @State private var drafts: [DailyPlan.PlanBlockDraft] = []
    @State private var loading = true
    @State private var task: Task<Void, Never>?

    private var heading: String { date.formatted(.dateTime.weekday(.wide).month().day()) }

    var body: some View {
        VStack(spacing: 0) {
            SubHeader("Plan \(heading)") {
                if !drafts.isEmpty && !loading {
                    Button("Add all") { acceptAll() }.font(.caption.bold())
                }
            }
            Divider()
            Group {
                if loading {
                    HStack(spacing: DS.Space.s) {
                        ProgressView().controlSize(.small)
                        Text("Planning that day…").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if drafts.isEmpty {
                    EmptyState(symbol: "checkmark.circle",
                               title: "Nothing pressing",
                               subtitle: "No open work is due around \(heading). Enjoy the breather — or add a block by hand from the planner.")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: DS.Space.s) {
                            Text("Suggested blocks for \(heading). Tweak the length, then add the ones you want.")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach($drafts) { row($0) }
                        }.padding(14)
                    }
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(12)
        }
        .frame(minWidth: 380, minHeight: 320)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("").toolbar(.hidden, for: .windowToolbar)
        .onAppear(perform: generate)
        .onDisappear { task?.cancel() }
    }

    private func row(_ d: Binding<DailyPlan.PlanBlockDraft>) -> some View {
        let draft = d.wrappedValue
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: DS.Space.s) {
                Text(draft.title).font(.callout.weight(.medium)).lineLimit(1)
                if let c = state.course(draft.courseID) { CourseChip(course: c) }
                Spacer(minLength: DS.Space.s)
                Stepper(value: d.minutes, in: 15...120, step: 15) {
                    Text("\(draft.minutes) min").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }.fixedSize()
                Button { accept(draft) } label: { Image(systemName: "checkmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.green).help("Add this block to \(heading)")
                Button { withAnimation { drafts.removeAll { $0.id == draft.id } } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Skip")
            }
            if !draft.why.isEmpty {
                Text(draft.why).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Space.s)
        .background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }

    private func generate() {
        loading = true
        let provider = AIConfig.isReady ? AIService.makeProvider() : nil
        let data = state.data
        let ref = date
        task?.cancel()
        task = Task {
            let result = await DailyPlan.plan(data, asOf: ref, provider: provider)
            await MainActor.run {
                loading = false
                withAnimation(.easeOut(duration: 0.2)) { drafts = result }
            }
        }
    }

    private func accept(_ d: DailyPlan.PlanBlockDraft) {
        if state.data.assignments.contains(where: { $0.id == d.assignmentID }) {
            state.planBlock(title: d.title, minutes: d.minutes, courseID: d.courseID, assignmentID: d.assignmentID, on: date)
        }
        withAnimation { drafts.removeAll { $0.id == d.id } }
    }

    private func acceptAll() {
        for d in drafts where state.data.assignments.contains(where: { $0.id == d.assignmentID }) {
            state.planBlock(title: d.title, minutes: d.minutes, courseID: d.courseID, assignmentID: d.assignmentID, on: date)
        }
        drafts = []
        dismiss()
    }
}
