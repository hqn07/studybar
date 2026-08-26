import SwiftUI

/// Sort feed-imported (Canvas) assignments that landed without a course. Auto-groups
/// by the `[CODE]` tag Canvas appends — one tap creates the course (or assigns an
/// existing one) for the whole group — and lists untagged items for manual mapping.
/// Inline page (no sheet); all actions are undoable.
struct ClassifyView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var scanning = true

    private var groups: [(tag: String, items: [Assignment])] { CanvasFeedImport.classifyGroups(state) }
    private var tagged: [(tag: String, items: [Assignment])] { groups.filter { !$0.tag.isEmpty } }
    private var untagged: [Assignment] { groups.first { $0.tag.isEmpty }?.items ?? [] }
    private var total: Int { CanvasFeedImport.unclassified(state).count }

    var body: some View {
        VStack(spacing: 0) {
            SubHeader("Classify Canvas items")
            Divider()
            if total == 0 {
                EmptyState(symbol: "checkmark.seal.fill", title: "All sorted",
                           subtitle: "Every imported item is assigned to a course.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.l) {
                        HStack(spacing: DS.Space.s) {
                            if scanning { ProgressView().controlSize(.small) }
                            Text("\(total) unsorted · \(tagged.count) course code\(tagged.count == 1 ? "" : "s") detected")
                                .font(.caption).foregroundStyle(.secondary)
                        }

                        if !tagged.isEmpty {
                            section("Detected by course code — one tap each") {
                                ForEach(tagged, id: \.tag) { g in tagRow(g.tag, g.items.count) }
                                if tagged.count > 1 {
                                    Button { createAll() } label: {
                                        Label("Create courses for all codes", systemImage: "square.stack.3d.up")
                                            .frame(maxWidth: .infinity)
                                    }.buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 2)
                                }
                            }
                        }

                        if !untagged.isEmpty {
                            section("No code tag — assign manually (\(untagged.count))") {
                                ForEach(untagged) { manualRow($0) }
                            }
                        }
                    }.padding(DS.Space.l)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("").toolbar(.hidden, for: .windowToolbar)
        .task {
            await CanvasFeedImport.backfillTags(state: state)   // recover tags for older imports
            scanning = false
        }
    }

    // MARK: rows

    private func tagRow(_ tag: String, _ count: Int) -> some View {
        HStack(spacing: DS.Space.m) {
            Chip(tag, .tag)
            Text("\(count) item\(count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: DS.Space.s)
            Menu {
                Button { create(tag) } label: { Label("Create course “\(tag)”", systemImage: "plus") }
                if !state.data.courses.isEmpty {
                    Divider()
                    ForEach(state.data.courses) { c in
                        Button(c.name.isEmpty ? c.code : c.name) { assign(tag, to: c.id) }
                    }
                }
            } label: {
                Label("Sort", systemImage: "plus.circle").font(.callout)
            }.menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.m)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }

    private func manualRow(_ a: Assignment) -> some View {
        HStack(spacing: DS.Space.m) {
            Text(a.title.isEmpty ? "Untitled" : a.title).font(.callout).lineLimit(1)
            Spacer(minLength: DS.Space.s)
            CoursePicker(courseID: Binding(
                get: { nil },
                set: { if let c = $0 { assignItem(a.id, to: c) } }))
        }
        .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.m)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }

    @ViewBuilder private func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionHeader(title: title)
            c()
        }
    }

    // MARK: actions (undoable)

    private func create(_ tag: String) {
        state.withUndo("Created \(tag)") { CanvasFeedImport.createCourseAndAssign(tag: tag, state: state) }
    }
    private func assign(_ tag: String, to id: UUID) {
        state.withUndo("Sorted \(tag)") { CanvasFeedImport.assign(tag: tag, to: id, state: state) }
    }
    private func assignItem(_ item: UUID, to id: UUID) {
        state.withUndo("Sorted item") { CanvasFeedImport.assign(ids: [item], to: id, state: state) }
    }
    private func createAll() {
        state.withUndo("Created courses from Canvas") {
            for g in CanvasFeedImport.classifyGroups(state) where !g.tag.isEmpty {
                CanvasFeedImport.createCourseAndAssign(tag: g.tag, state: state)
            }
        }
    }
}
