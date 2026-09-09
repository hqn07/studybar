import SwiftUI

/// Review and merge duplicate assignments. A fast deterministic pass (same course + due date +
/// similar title) runs on open. Merging is propose→accept — you pick which to keep, and the rest
/// are removed with undo. Nothing is deleted automatically.
struct DuplicateReviewView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var groups: [DupGroup] = []
    @State private var keepChoice: [UUID: UUID] = [:]
    @State private var ran = false
    @State private var deepRunning = false
    @State private var deepRan = false
    @State private var deepCandidates = 0

    var body: some View {
        VStack(spacing: 0) {
            SubHeader("Duplicate Assignments") { }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    if groups.isEmpty {
                        VStack(alignment: .leading, spacing: DS.Space.l) {
                            EmptyState(symbol: ran ? "checkmark.circle" : "square.on.square",
                                       title: ran ? "No exact duplicates" : "Checking…",
                                       subtitle: "Assignments in the same course with the same due date and a similar title are grouped here for review.")
                            if ran { deepScanBar }
                        }
                    } else {
                        Text("\(groups.count) possible duplicate group\(groups.count == 1 ? "" : "s"). Pick which to keep — merging removes the rest (undo with ⌘Z).")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        ForEach(groups) { groupCard($0) }
                        deepScanBar
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Space.l)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("").toolbar(.hidden, for: .windowToolbar)
        .task {
            if !ran {
                groups = DuplicateFinder.find(state.data.assignments)
                ran = true
                seedChoices()
            }
        }
    }

    /// The second pass. Kept separate and opt-in: it costs a request, and its answers are a
    /// model's judgement rather than a rule, so they are labelled as such in the list.
    @ViewBuilder private var deepScanBar: some View {
        let engineReady = AIConfig.isReady(for: .ask)
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Divider()
            HStack(spacing: DS.Space.m) {
                Image(systemName: "sparkle.magnifyingglass").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Look harder").font(.callout.weight(.medium))
                    Text(deepRan
                         ? "Checked \(deepCandidates) near-miss pair\(deepCandidates == 1 ? "" : "s")."
                         : "Compares near-miss pairs — same course, within a week, partly matching titles — including re-imports whose date moved.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: DS.Space.s)
                if deepRunning {
                    ProgressView().controlSize(.small)
                } else if engineReady {
                    Button(deepRan ? "Scan again" : "Deep scan") { runDeepScan() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            if !engineReady {
                Text("Needs an engine for questions — Settings ▸ Intelligence.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func runDeepScan() {
        deepRunning = true
        Task { @MainActor in
            deepCandidates = DuplicateFinder.candidates(state.data.assignments).count
            let found = await DuplicateFinder.deepScan(state.data.assignments)
            // Don't propose a pair the fast pass already grouped.
            let known = Set(groups.flatMap { $0.items.map(\.id) })
            let fresh = found.filter { g in !g.items.contains { known.contains($0.id) } }
            groups.append(contentsOf: fresh)
            seedChoices()
            deepRunning = false
            deepRan = true
        }
    }

    private func groupCard(_ g: DupGroup) -> some View {
        let keepID = keepChoice[g.id] ?? DuplicateFinder.keeper(g.items).id
        return VStack(alignment: .leading, spacing: 6) {
            Text(g.reason.uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(g.reason.hasPrefix("AI") ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            ForEach(g.items) { a in
                Button { keepChoice[g.id] = a.id } label: {
                    HStack(spacing: 8) {
                        Image(systemName: a.id == keepID ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(a.id == keepID ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.title.isEmpty ? "Untitled" : a.title).font(.callout).lineLimit(1)
                            Text(sourceLabel(a)).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                        Text(a.due?.dayMonth ?? "—").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .opacity(a.id == keepID ? 1 : 0.55)
                }
                .buttonStyle(.plain)
            }
            HStack {
                Button { merge(g, keepID: keepID) } label: {
                    Label("Keep selected · remove \(g.items.count - 1)", systemImage: "arrow.triangle.merge")
                }.buttonStyle(.borderedProminent).controlSize(.small)
                Button("Not duplicates") { groups.removeAll { $0.id == g.id } }
                    .buttonStyle(.borderless).controlSize(.small).foregroundStyle(.secondary)
            }
        }
        .padding(DS.Space.m)
        .background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }

    private func sourceLabel(_ a: Assignment) -> String {
        var parts: [String] = []
        if a.canvasID != nil || a.sourceUID != nil { parts.append("imported") } else { parts.append("added here") }
        if let c = state.course(a.courseID) { parts.append(c.code.isEmpty ? c.name : c.code) }
        return parts.joined(separator: " · ")
    }

    private func seedChoices() {
        for g in groups where keepChoice[g.id] == nil { keepChoice[g.id] = DuplicateFinder.keeper(g.items).id }
    }

    private func merge(_ g: DupGroup, keepID: UUID) {
        let remove = Set(g.items.filter { $0.id != keepID }.map(\.id))
        guard !remove.isEmpty else { return }
        state.withUndo("Merged \(remove.count + 1) duplicates") {
            state.data.assignments.removeAll { remove.contains($0.id) }
        }
        groups.removeAll { $0.id == g.id }
    }
}
