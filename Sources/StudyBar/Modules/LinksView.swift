import SwiftUI

struct LinksView: View {
    @EnvironmentObject var state: AppState
    @State private var editing: QuickLink?
    @Environment(\.listFilter) private var filter
    @State private var selectedLink: UUID?
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
    /// The toolbar filter on a link: title or URL, in the token's course. Pure.
    static func matches(_ l: QuickLink, filter: ListFilter) -> Bool {
        filter.matches(courseID: l.courseID, fields: [l.title, l.url])
    }
    private var filtered: [QuickLink] { state.data.links.filter { Self.matches($0, filter: filter) } }
    /// The rows top to bottom, for the keyboard: flat while filtered, by group otherwise.
    private var rowIDs: [UUID] { filter.isActive ? filtered.map(\.id) : grouped.flatMap { $0.1.map(\.id) } }

    var body: some View {
        NavigationStack {
            ModulePane(title: "Library",
                       primary: ModuleAction(title: "New", systemImage: "plus", help: "New link") { editing = QuickLink(title: "", url: "") },
                       controls: { LibraryTabPicker() },
                       more: {
                Button { addCurrentTab() } label: { Label("Add current browser tab", systemImage: "safari") }
            }) {
                if state.data.links.isEmpty {
                    EmptyState(symbol: "link", title: "No links",
                               subtitle: "Pin your LMS, library, email and course pages. Use the Safari button to grab the current tab.")
                } else {
                    VStack(spacing: 0) {
                        FilterStatus(shown: filtered.count, total: state.data.links.count, noun: "links")
                        if !note.isEmpty {
                            Text(note).font(.caption2).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 4)
                        }
                        Divider()
                        if filter.isActive && filtered.isEmpty { FilteredEmpty(noun: "links") } else {
                            ScrollView {
                                if filter.isActive {
                                    LazyVStack(spacing: 0) {
                                        ForEach(filtered) { link in row(link) }
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
                                            ForEach(items) { link in row(link) }
                                        }
                                    }.padding(.vertical, 8)
                                }
                            }
                            // ↩ and Space open the link; ⌫ deletes it (Undo, Trash).
                            .keyboardListNav(ids: rowIDs, selection: $selectedLink,
                                             onActivate: { id in if let l = state.data.links.first(where: { $0.id == id }) { open(l.url) } },
                                             onRemove: { id in state.withUndo("Deleted link") { state.data.links.removeAll { $0.id == id } } },
                                             onEscape: { selectedLink = nil })
                        }
                    }
                }
            }
            .navigationDestination(item: $editing) { LinkEditor(link: $0).moduleColumn(DS.Width.form) }
            .preference(key: SelectionKey.self, value: selectedLink.map(ItemRef.link))
            .onAppear(perform: consumeEdit)
            .onChange(of: state.pendingEdit) { _, _ in consumeEdit() }
        }
    }

    private func row(_ link: QuickLink) -> some View {
        LinkRow(link: link, selected: link.id == selectedLink) { editing = link }
            .kbSelected(link.id == selectedLink, radius: DS.Radius.control)
            .itemContextMenu(.link(link.id), state: state)
    }

    private func consumeEdit() {
        guard case .link(let id) = state.pendingEdit else { return }
        state.pendingEdit = nil
        editing = state.data.links.first { $0.id == id }
    }

    private func addCurrentTab() {
        note = ""
        guard let tab = BrowserURL.current() else {
            note = "Couldn't read the browser. Open Safari/Chrome/Arc and allow automation when prompted."
            return
        }
        state.data.links.append(QuickLink(title: tab.title, url: CleanURL.strip(tab.url)))
    }
    private func open(_ s: String) {
        let u = s.contains("://") ? s : "https://\(s)"
        if let url = URL(string: u) { NSWorkspace.shared.open(url) }
    }
}

struct LinkRow: View {
    @EnvironmentObject var state: AppState
    let link: QuickLink
    var selected = false
    let onEdit: () -> Void

    init(link: QuickLink, selected: Bool = false, onEdit: @escaping () -> Void) {
        self.link = link; self.selected = selected; self.onEdit = onEdit
    }
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
            RowActions {
                Button(action: onEdit) { Image(systemName: "pencil").accessibilityLabel("Edit link") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.s + 1)
        .rowActionsHost(selected: selected)
        .accessibilityActions { Button("Edit link", action: onEdit) }
        .sbRowSeparator(leading: DS.Space.m)
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
                Button("Delete", role: .destructive) { delete(); dismiss() }
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
                                            .accessibilityLabel("Icon: " + s.replacingOccurrences(of: ".", with: " "))
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
        .toolbar(.hidden, for: .windowToolbar).navigationBarBackButtonHidden()
    }
    /// Undoable, and kept in the Trash — unless it was a new link never saved.
    private func delete() {
        guard state.data.links.contains(where: { $0.id == draft.id }) else { return }
        state.withUndo("Deleted link") { state.data.links.removeAll { $0.id == draft.id } }
    }
    private func save() {
        draft.url = CleanURL.strip(draft.url)
        if draft.url.trimmingCharacters(in: .whitespaces).isEmpty {
            delete()
        } else if let i = state.data.links.firstIndex(where: { $0.id == draft.id }) {
            state.data.links[i] = draft
        } else {
            state.data.links.append(draft)
        }
        dismiss()
    }
}
