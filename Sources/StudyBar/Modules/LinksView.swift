import SwiftUI

struct LinksView: View {
    @EnvironmentObject var state: AppState
    @State private var editing: QuickLink?
    @State private var search = ""
    @State private var note = ""

    private var grouped: [(String, [QuickLink])] {
        let sorted = state.data.links.sorted { ($0.pinned ? 1 : 0) > ($1.pinned ? 1 : 0) }
        let general = sorted.filter { $0.courseID == nil }
        var out: [(String, [QuickLink])] = []
        if !general.isEmpty { out.append(("General", general)) }
        for c in state.data.courses {
            let items = sorted.filter { $0.courseID == c.id }
            if !items.isEmpty { out.append((c.name, items)) }
        }
        return out
    }
    private var searchResults: [QuickLink] {
        state.data.links.filter {
            $0.title.localizedCaseInsensitiveContains(search) || $0.url.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            ModulePane(title: "Quick Links") {
                HStack(spacing: 8) {
                    Button { addCurrentTab() } label: { Image(systemName: "safari") }
                        .help("Add current browser tab")
                    Button { editing = QuickLink(title: "", url: "") } label: { Image(systemName: "plus") }
                }
            } content: {
                if state.data.links.isEmpty {
                    EmptyState(symbol: "link", title: "No links",
                               subtitle: "Pin your LMS, library, email and course pages. Use the Safari button to grab the current tab.")
                } else {
                    VStack(spacing: 0) {
                        if state.data.links.count > 4 { SearchField(text: $search).padding(8) }
                        if !note.isEmpty {
                            Text(note).font(.caption2).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 4)
                        }
                        Divider()
                        ScrollView {
                            if !search.isEmpty {
                                LazyVStack(spacing: 6) {
                                    ForEach(searchResults) { link in LinkRow(link: link) { editing = link } }
                                }.padding(.vertical, 8)
                            } else {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(grouped, id: \.0) { name, items in
                                        HStack {
                                            SectionHeader(title: name, count: items.count)
                                            Spacer()
                                            if items.count > 1 {
                                                Button { items.forEach { open($0.url) } } label: { Text("Open all").font(.caption2) }
                                                    .buttonStyle(.borderless)
                                            }
                                        }.padding(.horizontal, 12).padding(.top, 4)
                                        ForEach(items) { link in LinkRow(link: link) { editing = link } }
                                    }
                                }.padding(.vertical, 8)
                            }
                        }
                    }
                }
            }
            .navigationDestination(item: $editing) { LinkEditor(link: $0) }
        }
    }

    private func addCurrentTab() {
        note = ""
        guard let tab = BrowserURL.current() else {
            note = "Couldn't read the browser. Open Safari/Chrome/Arc and allow automation when prompted."
            return
        }
        state.data.links.append(QuickLink(title: tab.title, url: tab.url))
    }
    private func open(_ s: String) {
        let u = s.contains("://") ? s : "https://\(s)"
        if let url = URL(string: u) { NSWorkspace.shared.open(url) }
    }
}

struct LinkRow: View {
    @EnvironmentObject var state: AppState
    let link: QuickLink
    let onEdit: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            FaviconView(urlString: link.url, fallbackSymbol: link.symbol.isEmpty ? "link" : link.symbol, size: 18)
                .frame(width: 20)
            Button { open() } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(link.title.isEmpty ? link.url : link.title).fontWeight(.medium)
                    Text(link.url).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }.buttonStyle(.plain)
            Spacer()
            if link.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
            Button(action: onEdit) { Image(systemName: "pencil") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
        }
        .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.s + 1)
        .background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .padding(.horizontal, DS.Space.m)
    }
    private func open() {
        let s = link.url.contains("://") ? link.url : "https://\(link.url)"
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
}

struct LinkEditor: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var draft: QuickLink
    init(link: QuickLink) { _draft = State(initialValue: link) }

    let symbols = ["link","graduationcap","books.vertical","envelope","doc.text","calendar","globe","folder","video","music.note"]

    var body: some View {
        VStack(spacing: 0) {
            SubHeader("Link") {
                Button("Delete", role: .destructive) { state.data.links.removeAll { $0.id == draft.id }; dismiss() }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                TextField("Title", text: $draft.title).textFieldStyle(.roundedBorder)
                TextField("URL", text: $draft.url).textFieldStyle(.roundedBorder)
                HStack {
                    Text("Course").font(.caption).foregroundStyle(.secondary)
                    CoursePicker(courseID: $draft.courseID)
                    Spacer()
                    Toggle("Pin", isOn: $draft.pinned)
                }
                Text("Icon").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 10), spacing: 8) {
                    ForEach(symbols, id: \.self) { s in
                        Button { draft.symbol = s } label: {
                            Image(systemName: s).frame(width: 24, height: 24)
                                .background(draft.symbol == s ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.clear),
                                            in: RoundedRectangle(cornerRadius: 5))
                        }.buttonStyle(.plain)
                    }
                }
            }.padding(14)
            Divider()
            HStack { Spacer(); Button("Cancel") { dismiss() }
                Button("Save") { save() }.keyboardShortcut(.defaultAction) }.padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("")
        .toolbar(.hidden, for: .windowToolbar)
    }
    private func save() {
        if draft.url.trimmingCharacters(in: .whitespaces).isEmpty {
            state.data.links.removeAll { $0.id == draft.id }
        } else if let i = state.data.links.firstIndex(where: { $0.id == draft.id }) {
            state.data.links[i] = draft
        } else {
            state.data.links.append(draft)
        }
        dismiss()
    }
}
