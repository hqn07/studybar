import SwiftUI

struct ReadingListView: View {
    @EnvironmentObject var state: AppState
    @State private var newURL = ""
    @State private var hideRead = false
    @State private var note = ""
    @State private var search = ""

    private var items: [ReadingListItem] {
        state.data.readingList
            .filter { !hideRead || !$0.read }
            .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.url.localizedCaseInsensitiveContains(search) }
            .sorted { $0.addedAt > $1.addedAt }
    }

    var body: some View {
        ModulePane(title: "Reading List") {
            HStack(spacing: 8) {
                Toggle("Unread", isOn: $hideRead).toggleStyle(.switch).controlSize(.mini)
                Button { addCurrentTab() } label: { Image(systemName: "safari") }
                    .help("Add current browser tab")
            }
        } content: {
            VStack(spacing: 0) {
                HStack {
                    TextField("Paste a URL to read later…", text: $newURL, onCommit: addURL)
                        .textFieldStyle(.roundedBorder)
                    Button("Add", action: addURL).disabled(newURL.isEmpty)
                }.padding(10)
                if state.data.readingList.count > 4 { SearchField(text: $search).padding(.horizontal, 10).padding(.bottom, 8) }
                if !note.isEmpty {
                    Text(note).font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
                }
                Divider()
                if items.isEmpty {
                    EmptyState(symbol: "books.vertical", title: "Nothing saved",
                               subtitle: "Save articles and pages to read later. Use the Safari button to grab the current tab.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 5) {
                            ForEach(items) { item in ReadingListRow(item: item) }
                        }.padding(10)
                    }
                }
            }
        }
    }

    private func addURL() {
        let u = newURL.trimmingCharacters(in: .whitespaces)
        guard !u.isEmpty else { return }
        let item = ReadingListItem(title: u, url: u)
        let id = item.id
        state.data.readingList.insert(item, at: 0)
        newURL = ""
        Task { @MainActor in
            if let title = await MetadataFetcher.pageTitle(u),
               let i = state.data.readingList.firstIndex(where: { $0.id == id }) {
                state.data.readingList[i].title = title
            }
        }
    }

    private func addCurrentTab() {
        note = ""
        guard let tab = BrowserURL.current() else {
            note = "Couldn't read the browser. Open Safari/Chrome/Arc and allow automation when prompted."
            return
        }
        state.data.readingList.insert(ReadingListItem(title: tab.title, url: tab.url), at: 0)
    }
}

struct ReadingListRow: View {
    @EnvironmentObject var state: AppState
    let item: ReadingListItem
    var body: some View {
        HStack(spacing: 8) {
            Button { toggle() } label: {
                Image(systemName: item.read ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.read ? AnyShapeStyle(Color.dsDone) : AnyShapeStyle(.secondary))
            }.buttonStyle(.plain)
            FaviconView(urlString: item.url, fallbackSymbol: "doc.text", size: 16)
            Button { open() } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).fontWeight(.medium).lineLimit(1).strikethrough(item.read)
                    Text(item.url).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }.buttonStyle(.plain)
            Spacer()
            CoursePicker(courseID: Binding(
                get: { item.courseID },
                set: { v in if let i = state.data.readingList.firstIndex(where: { $0.id == item.id }) { state.data.readingList[i].courseID = v } }))
            Button { state.data.readingList.removeAll { $0.id == item.id } } label: {
                Image(systemName: "xmark")
            }.buttonStyle(.borderless).foregroundStyle(.secondary).font(.caption)
        }
        .padding(DS.Space.m).background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }
    private func toggle() {
        guard let i = state.data.readingList.firstIndex(where: { $0.id == item.id }) else { return }
        state.data.readingList[i].read.toggle()
    }
    private func open() {
        let u = item.url.contains("://") ? item.url : "https://\(item.url)"
        if let url = URL(string: u) { NSWorkspace.shared.open(url) }
    }
}
