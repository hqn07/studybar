import SwiftUI

/// News: subscribe to RSS/Atom feeds (professor blogs, journal TOC, course news) and
/// read a merged, newest-first list. Free, no key.
struct RSSView: View {
    @EnvironmentObject var state: AppState
    @State private var articles: [Article] = []
    @State private var loading = false
    @State private var managing = false

    var body: some View {
        NavigationStack {
            ModulePane(title: "News") {
                HStack(spacing: 8) {
                    Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(loading || state.rssFeeds.isEmpty)
                    Button { managing = true } label: { Image(systemName: "list.bullet") }.help("Manage feeds")
                }
            } content: {
                Group {
                    if state.rssFeeds.isEmpty {
                        VStack(spacing: 12) {
                            EmptyState(symbol: "dot.radiowaves.left.and.right", title: "No feeds yet",
                                       subtitle: "Subscribe to professor blogs, journal tables of contents, or course news.")
                            Button("Add a feed") { managing = true }.buttonStyle(.borderedProminent)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if articles.isEmpty && !loading {
                        EmptyState(symbol: "tray", title: "No recent items", subtitle: "Pull refresh, or check the feed URLs.")
                    } else {
                        ScrollView {
                            if loading { ProgressView().padding(.top, 8) }
                            LazyVStack(spacing: 6) {
                                ForEach(articles) { articleRow($0) }
                            }.padding(10)
                        }
                    }
                }
            }
            .navigationDestination(isPresented: $managing) { manageFeeds }
            .task { if articles.isEmpty { await refresh() } }
        }
    }

    private func articleRow(_ a: Article) -> some View {
        Button { open(a.link) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(a.title).fontWeight(.medium).lineLimit(2).multilineTextAlignment(.leading)
                if !a.summary.isEmpty {
                    Text(a.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text(a.source).font(.caption2).foregroundStyle(.tint).lineLimit(1)
                    if let d = a.date { Text("· \(d.relativeShort)").font(.caption2).foregroundStyle(.secondary) }
                    Spacer()
                    Button {
                        state.data.readingList.append(ReadingListItem(title: a.title, url: a.link))
                    } label: { Image(systemName: "books.vertical") }
                        .buttonStyle(.borderless).font(.caption2).help("Read later")
                }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    // MARK: manage feeds sub-page

    @State private var newURL = ""
    @State private var adding = false

    private var manageFeeds: some View {
        VStack(spacing: 0) {
            SubHeader("Feeds")
            Divider()
            List {
                Section("Add a feed") {
                    HStack {
                        TextField("Feed URL (https://…/feed.xml)", text: $newURL).textFieldStyle(.roundedBorder)
                        Button("Add") { addFeed() }.disabled(newURL.trimmingCharacters(in: .whitespaces).isEmpty || adding)
                        if adding { ProgressView().controlSize(.small) }
                    }
                }
                if !state.rssFeeds.isEmpty {
                    Section("Subscribed") {
                        ForEach(state.rssFeeds) { f in
                            HStack {
                                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(f.title.isEmpty ? f.url : f.title).lineLimit(1)
                                    Text(f.url).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Button(role: .destructive) { remove(f) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("").toolbar(.hidden, for: .windowToolbar)
    }

    private func addFeed() {
        let url = newURL.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }
        let normalized = url.contains("://") ? url : "https://\(url)"
        adding = true
        Task {
            let title = await RSSService.probeTitle(normalized) ?? ""
            state.rssFeeds.append(RSSFeed(title: title, url: normalized))
            newURL = ""; adding = false
            await refresh()
        }
    }
    private func remove(_ f: RSSFeed) {
        state.rssFeeds.removeAll { $0.id == f.id }
        articles.removeAll { $0.source == f.title }
    }
    private func refresh() async {
        guard !state.rssFeeds.isEmpty else { articles = []; return }
        loading = true
        articles = await RSSService.fetchAll(state.rssFeeds)
        loading = false
    }
    private func open(_ s: String) {
        guard let url = URL(string: s.contains("://") ? s : "https://\(s)") else { return }
        NSWorkspace.shared.open(url)
    }
}
