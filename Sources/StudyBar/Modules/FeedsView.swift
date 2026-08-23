import SwiftUI

/// Editor for a subscribed iCal feed. Feeds now live inside Calendar ▸ Sources.
struct FeedEditor: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ICSFeed
    init(feed: ICSFeed) { _draft = State(initialValue: feed) }

    var body: some View {
        VStack(spacing: 0) {
            SubHeader("Calendar Feed") {
                Button("Delete", role: .destructive) { state.data.icsFeeds.removeAll { $0.id == draft.id }; dismiss() }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                TextField("Name (e.g. Canvas)", text: $draft.name).textFieldStyle(.roundedBorder)
                TextField("Feed URL (.ics or webcal://)", text: $draft.url).textFieldStyle(.roundedBorder)
                HStack {
                    Text("Course").font(.caption).foregroundStyle(.secondary)
                    CoursePicker(courseID: $draft.courseID)
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
