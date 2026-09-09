import SwiftUI

/// Review what the triage proposes before any of it is written.
///
/// The list is grouped by kind, because the decision being made is per-group ("yes, those 29
/// really are attendance") far more often than per-item. Anything can be re-kinded or dropped,
/// and applying is one undoable step.
struct TriageReviewView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var proposals: [AssignmentTriage.Proposal] = []
    @State private var running = true
    @State private var batch = (done: 0, total: 0)
    @State private var task: Task<Void, Never>?

    private var untriaged: [Assignment] { state.data.assignments.filter { $0.isOpen && $0.kind == nil } }
    private var grouped: [(kind: AssignmentTriage.Kind, items: [AssignmentTriage.Proposal])] {
        AssignmentTriage.Kind.allCases.compactMap { k in
            let items = proposals.filter { $0.kind == k }
            return items.isEmpty ? nil : (k, items)
        }
    }
    private var acceptedCount: Int { proposals.filter(\.accepted).count }

    var body: some View {
        VStack(spacing: 0) {
            SubHeader("Sort by kind") {
                if !running, !proposals.isEmpty {
                    Button("Apply \(acceptedCount)") { apply() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(acceptedCount == 0)
                }
            }
            Divider()
            if running {
                VStack(spacing: DS.Space.m) {
                    ProgressView()
                    Text(batch.total > 0 ? "Reading titles… batch \(batch.done + 1) of \(batch.total)"
                                         : "Sorting what the rules can settle…")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Most are decided here without a model; only the ambiguous ones are sent.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if proposals.isEmpty {
                EmptyState(symbol: "checkmark.circle", title: "Nothing to sort",
                           subtitle: "Every open assignment already has a kind.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.l) {
                        summary
                        ForEach(grouped, id: \.kind) { group in
                            VStack(alignment: .leading, spacing: DS.Space.s) {
                                HStack(spacing: DS.Space.s) {
                                    SectionHeader(title: group.kind.label, count: group.items.count,
                                                  systemImage: group.kind.symbol)
                                    Spacer()
                                    Button(group.items.allSatisfy(\.accepted) ? "Skip all" : "Accept all") {
                                        toggleGroup(group.kind)
                                    }.buttonStyle(.plain).font(.caption).foregroundStyle(.tint)
                                }
                                Text(group.kind.blurb).font(.caption).foregroundStyle(.secondary)
                                ForEach(group.items) { p in row(p) }
                            }
                        }
                    }.padding(DS.Space.l)
                }
            }
        }
        .onAppear(perform: start)
        .onDisappear { task?.cancel() }
    }

    private var summary: some View {
        let work = proposals.filter { $0.kind == .work && $0.accepted }.count
        let rest = acceptedCount - work
        return Text(rest == 0
                    ? "^[\(proposals.count) item](inflect: true) looked at — all of it real work."
                    : "\(work) real, \(rest) housekeeping. Applying lets the list hide the housekeeping without deleting it.")
            .font(.callout).foregroundStyle(.secondary)
    }

    private func row(_ p: AssignmentTriage.Proposal) -> some View {
        HStack(spacing: DS.Space.m) {
            Button { toggle(p.id) } label: {
                Image(systemName: p.accepted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(p.accepted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }.buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text(p.title).font(.callout).lineLimit(1)
                HStack(spacing: 4) {
                    Text(p.reason).font(.caption2).foregroundStyle(.secondary)
                    if !p.deterministic {
                        Chip("AI", .tag).help("Decided by the model — the rules couldn't tell")
                    }
                }
            }
            Spacer(minLength: DS.Space.s)

            Picker("", selection: Binding(
                get: { p.kind },
                set: { k in if let i = proposals.firstIndex(where: { $0.id == p.id }) { proposals[i].kind = k } })) {
                    ForEach(AssignmentTriage.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
        }
        .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
        .background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.control))
        .opacity(p.accepted ? 1 : 0.45)
    }

    private func toggle(_ id: UUID) {
        guard let i = proposals.firstIndex(where: { $0.id == id }) else { return }
        proposals[i].accepted.toggle()
    }

    private func toggleGroup(_ kind: AssignmentTriage.Kind) {
        let all = proposals.filter { $0.kind == kind }.allSatisfy(\.accepted)
        for i in proposals.indices where proposals[i].kind == kind { proposals[i].accepted = !all }
    }

    private func start() {
        let items = untriaged
        guard !items.isEmpty else { running = false; return }
        task = Task { @MainActor in
            let result = await AssignmentTriage.classify(items) { done, total in batch = (done, total) }
            proposals = result.sorted { $0.title < $1.title }
            running = false
        }
    }

    private func apply() {
        let picks = Dictionary(proposals.filter(\.accepted).map { ($0.id, $0.kind.rawValue) },
                               uniquingKeysWith: { a, _ in a })
        guard !picks.isEmpty else { return }
        state.withUndo("Sorted \(picks.count) assignment\(picks.count == 1 ? "" : "s")") {
            for i in state.data.assignments.indices {
                if let k = picks[state.data.assignments[i].id] { state.data.assignments[i].kind = k }
            }
        }
        dismiss()
    }
}
