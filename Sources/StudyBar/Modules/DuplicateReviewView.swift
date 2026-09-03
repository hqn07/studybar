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

    var body: some View {
        VStack(spacing: 0) {
            SubHeader("Duplicate Assignments") { }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    if groups.isEmpty {
                        EmptyState(symbol: ran ? "checkmark.circle" : "square.on.square",
                                   title: ran ? "No duplicates found" : "Checking…",
                                   subtitle: "Assignments in the same course with the same due date and a similar title are grouped here for review.")
                    } else {
                        Text("\(groups.count) possible duplicate group\(groups.count == 1 ? "" : "s"). Pick which to keep — merging removes the rest (undo with ⌘Z).")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        ForEach(groups) { groupCard($0) }
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
