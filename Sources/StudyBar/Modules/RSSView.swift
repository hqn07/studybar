import SwiftUI
import UniformTypeIdentifiers

/// News — subscribe to RSS/Atom feeds (professor blogs, journal TOCs, course news, or a
/// Google News topic), read a merged newest-first list with per-item read state, skim the
/// article in an in-app reader, and organize feeds into folders. Free, no key, no cloud.
struct RSSView: View {
    @EnvironmentObject var state: AppState
    @State private var articles: [Article] = []
    @State private var loading = false
    @State private var managing = false
    @State private var reader: Article?
    @State private var unreadOnly = false
    @State private var folder: String? = nil    // nil = all folders

    // MARK: Derived

    private var folders: [String] {
        Array(Set(state.rssFeeds.map(\.folder).filter { !$0.isEmpty })).sorted()
    }
    private func folderOf(source: String) -> String {
        state.rssFeeds.first { $0.title == source }?.folder ?? ""
    }
    private var visible: [Article] {
        articles.filter { a in
            (folder == nil || folderOf(source: a.source) == folder!)
                && (!unreadOnly || !state.isRead(a.link))
        }
    }
    private var unreadCount: Int { articles.filter { !state.isRead($0.link) }.count }

    var body: some View {
        NavigationStack {
            ModulePane(title: "News") {
                HStack(spacing: 8) {
                    if unreadCount > 0 {
                        Button { markAllRead() } label: { Image(systemName: "checkmark.circle") }
                            .help("Mark all as read")
                    }
                    Button { unreadOnly.toggle() } label: {
                        Image(systemName: unreadOnly ? "circle.fill" : "circle.dashed")
                    }
                    .foregroundStyle(unreadOnly ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .help(unreadOnly ? "Showing unread — tap for all" : "Show unread only")
                    Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(loading || state.rssFeeds.isEmpty)
                    Button { managing = true } label: { Image(systemName: "list.bullet") }.help("Manage feeds")
                }
            } content: {
                Group {
                    if state.rssFeeds.isEmpty {
                        VStack(spacing: 12) {
                            EmptyState(symbol: "dot.radiowaves.left.and.right", title: "No feeds yet",
                                       subtitle: "Subscribe to professor blogs, journal tables of contents, course news — or follow a Google News topic.")
                            Button("Add a feed") { managing = true }.buttonStyle(.borderedProminent)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        VStack(spacing: 0) {
                            if !folders.isEmpty { folderBar; Divider() }
                            list
                        }
                    }
                }
            }
            .navigationDestination(isPresented: $managing) { manageFeeds }
            .navigationDestination(item: $reader) { ArticleReader(article: $0) }
            .task { if articles.isEmpty { await refresh() } }
        }
    }

    // MARK: Folder filter bar

    private var folderBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button { folder = nil } label: { Chip("All", .filter, selected: folder == nil) }.buttonStyle(.plain)
                ForEach(folders, id: \.self) { f in
                    Button { folder = f } label: { Chip(f, .filter, selected: folder == f) }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 10).padding(.vertical, 6)
        }
    }

    // MARK: List

    private var list: some View {
        Group {
            if visible.isEmpty && !loading {
                EmptyState(symbol: unreadOnly ? "checkmark.circle" : "tray",
                           title: unreadOnly ? "All caught up" : "No recent items",
                           subtitle: unreadOnly ? "No unread articles. Refresh, or show all." : "Refresh, or check the feed URLs.")
            } else {
                ScrollView {
                    if loading { ProgressView().padding(.top, 8) }
                    LazyVStack(spacing: 6) {
                        ForEach(visible) { articleRow($0) }
                    }.padding(10)
                }
            }
        }
    }

    private func articleRow(_ a: Article) -> some View {
        let read = state.isRead(a.link)
        return Button { reader = a } label: {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(read ? AnyShapeStyle(.clear) : AnyShapeStyle(.tint))
                    .frame(width: 7, height: 7).padding(.top, 5)
                VStack(alignment: .leading, spacing: 3) {
                    Text(a.title).fontWeight(read ? .regular : .semibold)
                        .foregroundStyle(read ? .secondary : .primary)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    if !a.summary.isEmpty {
                        Text(a.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    HStack(spacing: 6) {
                        FaviconView(urlString: a.link, fallbackSymbol: "dot.radiowaves.left.and.right", size: 13)
                        Text(a.source).font(.caption2).foregroundStyle(.tint).lineLimit(1)
                        if let d = a.date { Text("· \(d.relativeShort)").font(.caption2).foregroundStyle(.secondary) }
                        Spacer()
                        Button {
                            state.data.readingList.append(ReadingListItem(title: a.title, url: a.link))
                        } label: { Image(systemName: "books.vertical") }
                            .buttonStyle(.borderless).font(.caption2).help("Read later")
                    }
                }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(.sbSurfaceStroke, lineWidth: 0.5))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    // MARK: Manage feeds

    @State private var newURL = ""
    @State private var newFolder = ""
    @State private var googleTopic = ""
    @State private var adding = false

    private var manageFeeds: some View {
        VStack(spacing: 0) {
            SubHeader("Feeds") {
                Menu {
                    Button { importOPML() } label: { Label("Import OPML…", systemImage: "square.and.arrow.down") }
                    Button { exportOPML() } label: { Label("Export OPML…", systemImage: "square.and.arrow.up") }
                        .disabled(state.rssFeeds.isEmpty)
                } label: { Image(systemName: "ellipsis.circle") }
            }
            Divider()
            List {
                Section("Add a feed") {
                    HStack {
                        TextField("Feed URL (https://…/feed.xml)", text: $newURL).textFieldStyle(.roundedBorder)
                        if adding { ProgressView().controlSize(.small) }
                        else { Button("Add") { addFeed(newURL) }.disabled(newURL.trimmingCharacters(in: .whitespaces).isEmpty) }
                    }
                    TextField("Folder (optional)", text: $newFolder).textFieldStyle(.roundedBorder)
                }
                Section("Follow a Google News topic") {
                    HStack {
                        TextField("Topic (e.g. machine learning)", text: $googleTopic).textFieldStyle(.roundedBorder)
                        Button("Follow") { addGoogleNews() }
                            .disabled(googleTopic.trimmingCharacters(in: .whitespaces).isEmpty || adding)
                    }
                    Text("Builds a Google News RSS feed for that search.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if !state.rssFeeds.isEmpty {
                    Section("Subscribed (\(state.rssFeeds.count))") {
                        ForEach(state.rssFeeds) { f in feedRow(f) }
                    }
                }
            }
        }
        .navigationTitle("").toolbar(.hidden, for: .windowToolbar)
    }

    private func feedRow(_ f: RSSFeed) -> some View {
        HStack {
            FaviconView(urlString: f.url, fallbackSymbol: "dot.radiowaves.left.and.right", size: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(f.title.isEmpty ? f.url : f.title).lineLimit(1)
                Text(f.url).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Menu {
                Button(f.folder.isEmpty ? "No folder" : "Move out of “\(f.folder)”") { setFolder(f, "") }
                ForEach(folders, id: \.self) { name in
                    if name != f.folder { Button("Move to “\(name)”") { setFolder(f, name) } }
                }
            } label: {
                Label(f.folder.isEmpty ? "Folder" : f.folder, systemImage: "folder")
                    .font(.caption2)
            }.menuStyle(.borderlessButton).fixedSize()
            Button(role: .destructive) { remove(f) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
        }
    }

    // MARK: Actions

    private func addFeed(_ raw: String) {
        let url = raw.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }
        let normalized = url.contains("://") ? url : "https://\(url)"
        let fol = newFolder.trimmingCharacters(in: .whitespaces)
        adding = true
        Task {
            let title = await RSSService.probeTitle(normalized) ?? ""
            state.rssFeeds.append(RSSFeed(title: title, url: normalized, folder: fol))
            newURL = ""; newFolder = ""; adding = false
            await refresh()
        }
    }

    private func addGoogleNews() {
        let topic = googleTopic.trimmingCharacters(in: .whitespaces)
        guard !topic.isEmpty else { return }
        let url = RSSService.googleNews(topic: topic)
        let fol = newFolder.trimmingCharacters(in: .whitespaces)
        adding = true
        Task {
            state.rssFeeds.append(RSSFeed(title: "Google News: \(topic)", url: url, folder: fol.isEmpty ? "Google News" : fol))
            googleTopic = ""; adding = false
            await refresh()
        }
    }

    private func setFolder(_ f: RSSFeed, _ name: String) {
        guard let i = state.rssFeeds.firstIndex(where: { $0.id == f.id }) else { return }
        state.rssFeeds[i].folder = name
    }
    private func remove(_ f: RSSFeed) {
        state.rssFeeds.removeAll { $0.id == f.id }
        articles.removeAll { $0.source == f.title }
    }
    private func markAllRead() { state.markRead(visible.map(\.link)) }

    private func refresh() async {
        guard !state.rssFeeds.isEmpty else { articles = []; return }
        loading = true
        articles = await RSSService.fetchAll(state.rssFeeds)
        loading = false
    }

    @MainActor private func importOPML() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "opml") ?? .xml, .xml]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        let existing = Set(state.rssFeeds.map(\.url))
        var added = 0
        for row in RSSService.parseOPML(data) where !existing.contains(row.url) {
            state.rssFeeds.append(RSSFeed(title: row.title, url: row.url, folder: row.folder))
            added += 1
        }
        if added > 0 { Task { await refresh() } }
    }

    @MainActor private func exportOPML() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "opml") ?? .xml]
        panel.nameFieldStringValue = "StudyBar-feeds.opml"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? RSSService.exportOPML(state.rssFeeds).data(using: .utf8)?.write(to: url)
    }
}

/// The in-app reader — skim an article without a browser bounce. Shows the feed's
/// content (full body when the feed ships `content:encoded`, else its summary), with a
/// one-tap handoff to the original page. Opening it marks the item read.
struct ArticleReader: View {
    @EnvironmentObject var state: AppState
    let article: Article

    var body: some View {
        VStack(spacing: 0) {
            SubHeader("Article") {
                Button { state.data.readingList.append(ReadingListItem(title: article.title, url: article.link)) } label: {
                    Image(systemName: "books.vertical")
                }.help("Read later")
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    Text(article.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                    HStack(spacing: 6) {
                        FaviconView(urlString: article.link, fallbackSymbol: "dot.radiowaves.left.and.right", size: 14)
                        Text(article.source).font(.caption).foregroundStyle(.tint)
                        if let d = article.date {
                            Text("· \(d.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if article.readable.isEmpty {
                        Text("No preview text in this feed — open the original to read it.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text(article.readable).font(.callout).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button { open(article.link) } label: {
                        Label("Open original", systemImage: "safari")
                    }.buttonStyle(.borderedProminent)
                }
                .padding(DS.Space.xl).frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle("").toolbar(.hidden, for: .windowToolbar)
        .onAppear { state.markRead(article.link) }
    }

    private func open(_ s: String) {
        guard let url = URL(string: s.contains("://") ? s : "https://\(s)") else { return }
        NSWorkspace.shared.open(url)
    }
}
