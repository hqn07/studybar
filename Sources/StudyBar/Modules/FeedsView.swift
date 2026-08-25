import SwiftUI

/// Editor for a subscribed iCal feed. Feeds now live inside Calendar ▸ Sources.
struct FeedEditor: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ICSFeed
    @State private var confirmingDelete = false
    @State private var alsoRemoveImports = false
    init(feed: ICSFeed) { _draft = State(initialValue: feed) }

    private var importedCount: Int {
        state.data.assignments.filter { $0.sourceFeedID == draft.id }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            SubHeader("Calendar Feed") {
                Button("Delete", role: .destructive) { confirmingDelete = true }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                TextField("Name (e.g. Canvas)", text: $draft.name).textFieldStyle(.roundedBorder)
                TextField("Feed URL (.ics or webcal://)", text: $draft.url).textFieldStyle(.roundedBorder)
                HStack {
                    Text("Course").font(.caption).foregroundStyle(.secondary)
                    CoursePicker(courseID: $draft.courseID)
                }
                if let synced = draft.lastSynced {
                    Text("Last synced \(synced.relativeShort) · \(importedCount) assignment\(importedCount == 1 ? "" : "s") imported")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text("Canvas: Calendar ▸ Calendar Feed (bottom-right) ▸ copy the URL.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(14)
            Divider()
            HStack { Spacer(); Button("Cancel") { dismiss() }
                Button("Save") { save() }.keyboardShortcut(.defaultAction) }.padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("").toolbar(.hidden, for: .windowToolbar)
        .overlay { if confirmingDelete { deleteCard } }
    }

    private var deleteCard: some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea().onTapGesture { confirmingDelete = false }
            VStack(spacing: 12) {
                Text("Remove this feed?").font(.headline)
                Text("It will no longer refresh assignments.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if importedCount > 0 {
                    Toggle(isOn: $alsoRemoveImports) {
                        Text("Also delete \(importedCount) imported assignment\(importedCount == 1 ? "" : "s")")
                            .font(.caption)
                    }
                }
                HStack(spacing: 10) {
                    Button("Cancel") { confirmingDelete = false }.keyboardShortcut(.cancelAction)
                    Button("Remove", role: .destructive) { deleteFeed() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
            .padding(20).frame(maxWidth: 300)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.modal))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.modal).stroke(.separator))
            .shadow(radius: 20)
        }
    }

    private func deleteFeed() {
        if alsoRemoveImports {
            state.data.assignments.removeAll { $0.sourceFeedID == draft.id }
        }
        state.data.icsFeeds.removeAll { $0.id == draft.id }
        confirmingDelete = false
        dismiss()
    }
    private func save() {
        if draft.url.trimmingCharacters(in: .whitespaces).isEmpty {
            state.data.icsFeeds.removeAll { $0.id == draft.id }
        } else if let i = state.data.icsFeeds.firstIndex(where: { $0.id == draft.id }) {
            state.data.icsFeeds[i] = draft
        } else {
            state.data.icsFeeds.append(draft)
        }
        dismiss()
    }
}
