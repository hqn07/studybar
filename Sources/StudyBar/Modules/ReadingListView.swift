import SwiftUI

struct ReadingListView: View {
    @EnvironmentObject var state: AppState
    @State private var newURL = ""
    @State private var hideRead = false
    @State private var note = ""
    @Environment(\.listFilter) private var filter
    @State private var selectedItem: UUID?

    /// The toolbar filter on a saved page: title or URL, in the token's course. Pure.
    static func matches(_ item: ReadingListItem, filter: ListFilter) -> Bool {
        filter.matches(courseID: item.courseID, fields: [item.title, item.url])
    }

    private var items: [ReadingListItem] {
        state.data.readingList
            .filter { (!hideRead || !$0.read) && Self.matches($0, filter: filter) }
            .sorted { $0.addedAt > $1.addedAt }
    }

    var body: some View {
        ModulePane(title: "Library",
                   primary: ModuleAction(title: "Add current tab", systemImage: "safari", help: "Add the browser's current tab") { addCurrentTab() },
                   controls: { LibraryTabPicker() },
                   more: {
            Toggle("Unread only", isOn: $hideRead)
        }) {
            VStack(spacing: 0) {
                HStack {
                    TextField("Paste a URL to read later…", text: $newURL, onCommit: addURL)
                        .textFieldStyle(.roundedBorder)
                    Button("Add", action: addURL).disabled(newURL.isEmpty)
                }.padding(10)
                if !note.isEmpty {
                    Text(note).font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
                }
                Divider()
                FilterStatus(shown: items.count, total: state.data.readingList.count, noun: "pages")
                if items.isEmpty && filter.isActive {
                    FilteredEmpty(noun: "pages")
                } else if items.isEmpty {
                    EmptyState(symbol: "books.vertical", title: "Nothing saved",
                               subtitle: "Save articles and pages to read later. Use the Safari button to grab the current tab.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(items) { item in
                                ReadingListRow(item: item)
                                    .kbSelected(item.id == selectedItem, radius: DS.Radius.control)
                                    .itemContextMenu(.readLater(item.id), state: state)
                            }
                        }.padding(10)
                    }
                    // ↩ and Space open the page; ⌫ removes it (Undo, Trash).
                    .keyboardListNav(ids: items.map(\.id), selection: $selectedItem,
                                     onActivate: { id in if let i = items.first(where: { $0.id == id }) { open(i.url) } },
                                     onRemove: { id in state.withUndo("Removed from Read later") { state.data.readingList.removeAll { $0.id == id } } },
                                     onEscape: { selectedItem = nil })
                }
            }
        }
        .preference(key: SelectionKey.self, value: selectedItem.map(ItemRef.readLater))
    }

    private func open(_ s: String) {
        let u = s.contains("://") ? s : "https://\(s)"
        if let url = URL(string: u) { NSWorkspace.shared.open(url) }
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
                    .accessibilityLabel(item.read ? "Mark unread" : "Mark read")
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
            Button { state.withUndo("Removed from Read later") { state.data.readingList.removeAll { $0.id == item.id } } } label: {
                Image(systemName: "xmark")
                .accessibilityLabel("Remove from Read later")
            }.buttonStyle(.borderless).foregroundStyle(.secondary).font(.caption)
        }
        .padding(DS.Space.m).sbRowSeparator(leading: DS.Space.m)
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
