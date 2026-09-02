import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// One turn in the "Ask the book" thread — a question, its grounded answer, and the pages
/// the answer was drawn from.
struct BookQA: Identifiable { let id = UUID(); let question: String; var answer: String; var pages: [Int] }

enum BookTab: String, CaseIterable { case overview = "Overview", highlights = "Highlights", ask = "Ask AI" }

enum ReadingSort: String, CaseIterable, Identifiable {
    case recent = "Recently read", progress = "Progress", title = "Title", rating = "Rating"
    var id: String { rawValue }
}

struct ReadingView: View {
    @EnvironmentObject var state: AppState
    @State private var newTitle = ""
    @State private var shelf = 0            // 0 all, 1 to-read, 2 reading, 3 finished
    @State private var query = ""
    @State private var sort = ReadingSort.recent
    @State private var goodreads = false
    @State private var showManualAdd = false
    @State private var openBookID: UUID?
    // Inline book search (add new books without leaving the page)
    @State private var bookQuery = ""
    @State private var bookResults: [BookInfo] = []
    @State private var bookSearching = false
    @State private var bookError = ""
    @State private var scanning = false
    @FocusState private var bookSearchFocused: Bool

    private var items: [ReadingItem] {
        var list = state.data.reading
        if shelf != 0 { list = list.filter { $0.shelf == shelf - 1 } }
        if !query.isEmpty {
            list = list.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.author.localizedCaseInsensitiveContains(query) }
        }
        switch sort {
        case .recent:   list.sort { $0.updatedAt > $1.updatedAt }
        case .progress: list.sort { $0.progress > $1.progress }
        case .title:    list.sort { $0.title.localizedCompare($1.title) == .orderedAscending }
        case .rating:   list.sort { $0.rating > $1.rating }
        }
        return list
    }

    var body: some View {
        NavigationStack {
            ModulePane(title: "Reading") {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(ReadingSort.allCases) { s in
                            Button { sort = s } label: {
                                Label(s.rawValue, systemImage: sort == s ? "checkmark" : "arrow.up.arrow.down")
                            }
                        }
                        Divider()
                        Button { goodreads = true } label: { Label("Import Goodreads CSV…", systemImage: "square.and.arrow.down") }
                    } label: { Image(systemName: "ellipsis.circle") }
                    Button { showManualAdd.toggle() } label: { Image(systemName: "plus") }
                        .help("Add a book manually (no search)")
                }
            } content: {
                VStack(spacing: 0) {
                    if !state.data.reading.isEmpty { statsStrip }
                    bookSearchBar
                    if scanning {
                        BarcodeScannerView { code in bookQuery = code; scanning = false; Task { await runBookSearch() } }
                            .frame(height: 180).clipShape(RoundedRectangle(cornerRadius: 10))
                            .padding(.horizontal, 10).padding(.top, 8)
                    }
                    if searchActive {
                        searchResultsPanel
                    } else {
                        if showManualAdd {
                            HStack {
                                TextField("Add manually by title…", text: $newTitle, onCommit: add)
                                    .textFieldStyle(.roundedBorder)
                                Button("Add") { add(); showManualAdd = false }.disabled(newTitle.isEmpty)
                            }.padding(.horizontal, 10).padding(.top, 8)
                        }
                        if state.data.reading.count > 4 { SearchField(text: $query).padding(.horizontal, 10).padding(.top, 8) }
                        Picker("", selection: $shelf) {
                            Text("All").tag(0); Text("To-Read").tag(1); Text("Reading").tag(2); Text("Finished").tag(3)
                        }.pickerStyle(.segmented).labelsHidden().padding(10)
                        Divider()
                        if items.isEmpty {
                            EmptyState(symbol: "books.vertical",
                                       title: state.data.reading.isEmpty ? "Your bookshelf is empty" : "Nothing on this shelf",
                                       subtitle: state.data.reading.isEmpty ? "Search for a book above to auto-fill cover, author and pages — or tap ＋ to add one manually." : "Try another shelf or search.")
                        } else {
                            ScrollView {
                                LazyVStack(spacing: 8) {
                                    ForEach(items) { item in
                                        Button { openBookID = item.id } label: { BookCard(item: item) }.buttonStyle(.plain)
                                            .contextMenu {
                                                Button { state.toggleReadingDone(item.id) } label: {
                                                    Label(item.done ? "Mark unread" : "Mark done",
                                                          systemImage: item.done ? "arrow.uturn.left" : "checkmark.circle")
                                                }
                                                Button { state.addToReadingList(item) } label: {
                                                    Label("Add to Reading List", systemImage: "bookmark")
                                                }
                                                Divider()
                                                Button(role: .destructive) { state.withUndo("Deleted book") { state.data.reading.removeAll { $0.id == item.id } } } label: {
                                                    Label("Delete book", systemImage: "trash")
                                                }
                                            }
                                    }
                                }.padding(10)
                            }
                        }
                    }
                }
            }
            .navigationDestination(isPresented: $goodreads) { GoodreadsImportView() }
            .navigationDestination(item: $openBookID) { ReadingDetailView(itemID: $0) }
        }
    }

    private var statsStrip: some View {
        HStack(spacing: 0) {
            miniStat("\(StudyStats.readingStreak(state.data))", "day streak", "flame.fill", .orange)
            miniStat("\(StudyStats.pagesThisWeek(state.data))", "pages / wk", "book.pages", .accentColor)
            miniStat("\(StudyStats.booksThisYear(state.data))", "read \(Calendar.current.component(.year, from: .now))", "checkmark.seal.fill", .green)
        }.padding(.horizontal, 10).padding(.top, 8)
    }
    private func miniStat(_ v: String, _ l: String, _ icon: String, _ c: Color) -> some View {
        VStack(spacing: 1) {
            HStack(spacing: 3) { Image(systemName: icon).font(.caption2).foregroundStyle(c); Text(v).font(.callout.bold()) }
            Text(l).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }

    private func add() {
        let t = newTitle.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        state.data.reading.append(ReadingItem(title: t))
        newTitle = ""
    }

    // MARK: Inline book search

    private var searchActive: Bool { bookSearching || !bookResults.isEmpty || !bookError.isEmpty }

    private var bookSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search a book by title or ISBN…", text: $bookQuery)
                .textFieldStyle(.plain).focused($bookSearchFocused)
                .onSubmit { Task { await runBookSearch() } }
            if BarcodeScanner.isAvailable {
                Button { scanning.toggle() } label: { Image(systemName: "barcode.viewfinder") }
                    .buttonStyle(.borderless).help("Scan barcode")
            }
            if !bookQuery.isEmpty || searchActive {
                Button { clearBookSearch() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).stroke(bookSearchFocused ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear)))
        .padding(.horizontal, 10).padding(.top, 8)
    }

    private var searchResultsPanel: some View {
        VStack(spacing: 0) {
            if bookSearching {
                HStack { ProgressView().controlSize(.small); Text("Searching…").font(.caption).foregroundStyle(.secondary); Spacer() }
                    .padding(10)
            }
            if !bookError.isEmpty {
                Text(bookError).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(Array(bookResults.enumerated()), id: \.offset) { _, info in
                        Button { addFoundBook(info) } label: {
                            HStack(spacing: 10) {
                                RemoteThumb(url: info.coverURL, size: CGSize(width: 40, height: 58))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(info.title).fontWeight(.medium).lineLimit(2)
                                    if !info.author.isEmpty { Text(info.author).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                    Text([info.year, info.pageCount > 0 ? "\(info.pageCount) p" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Image(systemName: "plus.circle.fill").foregroundStyle(.tint)
                            }
                            .padding(8).contentShape(Rectangle())
                            .background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                        }.buttonStyle(.plain)
                    }
                }.padding(10)
            }
        }
    }

    private func runBookSearch() async {
        let q = bookQuery.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return }
        bookError = ""; bookResults = []; bookSearching = true
        defer { bookSearching = false }
        let digits = q.filter { $0.isNumber }
        let looksISBN = (digits.count == 10 || digits.count == 13)
            && q.allSatisfy { $0.isNumber || $0 == "-" || $0.isWhitespace || $0 == "X" || $0 == "x" }
        if looksISBN {
            if let info = await BookLookup.fetch(isbn: q) { bookResults = [info] }
            else { bookError = "No match for that ISBN — try the title instead." }
        } else {
            bookResults = await BookLookup.search(title: q)
            if bookResults.isEmpty { bookError = "No books found. Check spelling, or tap ＋ to add manually." }
        }
    }

    private func addFoundBook(_ info: BookInfo) {
        let item = ReadingItem(title: info.title, author: info.author, isbn: info.isbn,
                               publisher: info.publisher, year: info.year, totalPages: info.pageCount)
        let id = item.id
        state.data.reading.append(item)
        let coverURL = info.coverURL
        Task { @MainActor in
            if let name = await CoverStore.download(from: coverURL, id: id),
               let i = state.data.reading.firstIndex(where: { $0.id == id }) {
                state.data.reading[i].coverPath = name
            }
        }
        clearBookSearch()
    }

    private func clearBookSearch() {
        bookQuery = ""; bookResults = []; bookError = ""; bookSearching = false; scanning = false
        bookSearchFocused = false
    }
}

// MARK: - Book card

struct BookCard: View {
    @EnvironmentObject var state: AppState
    let item: ReadingItem

    var body: some View {
        HStack(spacing: 12) {
            CoverThumb(coverPath: item.coverPath, size: CGSize(width: 46, height: 66))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(item.title).fontWeight(.semibold).lineLimit(2).strikethrough(item.done)
                    if item.timesRead > 1 {
                        Text("×\(item.timesRead)").font(.caption2.bold()).foregroundStyle(.tint)
                    }
                }
                if !item.author.isEmpty {
                    Text(item.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                ProgressView(value: item.progress).tint(item.done ? .green : .accentColor)
                HStack(spacing: 6) {
                    Text(item.usesUnits ? "\(item.unitsDone)/\(item.units.count) ch"
                         : (item.totalPages > 0 ? "\(item.currentPage)/\(item.totalPages) p" : "\(item.currentPage) p"))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    if item.done, item.rating > 0 {
                        Text(String(repeating: "★", count: item.rating)).font(.caption2).foregroundStyle(.yellow)
                    }
                    CourseChip(course: state.course(item.courseID))
                    Spacer()
                    if let eta = StudyStats.estimatedFinish(item, state.data) {
                        Text("~\(eta.dayMonth)").font(.caption2).foregroundStyle(.tertiary)
                    } else {
                        Text(item.done ? "Done" : "\(Int(item.progress * 100))%")
                            .font(.caption2.bold()).foregroundStyle(item.done ? .green : .secondary)
                    }
                }
            }
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(10).contentShape(Rectangle())
        .background(.sbSurface, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct CoverThumb: View {
    let coverPath: String
    var size: CGSize
    var body: some View {
        Group {
            if let img = CoverStore.image(coverPath) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(colors: [.indigo.opacity(0.5), .purple.opacity(0.35)], startPoint: .top, endPoint: .bottom))
                    .overlay(Image(systemName: "book.closed").foregroundStyle(.white.opacity(0.8)))
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.black.opacity(0.15)))
        .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
    }
}

// MARK: - Book detail

struct ReadingDetailView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let itemID: UUID
    @State private var editing = false
    @State private var pageField = ""
    @State private var hlPage = ""
    @State private var hlText = ""
    @State private var chapterText = ""
    @State private var bulkCount = ""
    // PDF content layer: attach a PDF → extract text on-device → search inside the book.
    @State private var pdfBusy = false
    @State private var pdfError: String?
    @State private var bookQuery = ""
    @State private var bookHits: [BookText.Hit] = []
    // Ask-the-book (grounded AI Q&A over retrieved pages) — a persistent thread w/ follow-ups
    @State private var askQuery = ""
    @State private var askThread: [BookQA] = []
    @State private var askLoading = false
    @State private var askTask: Task<Void, Never>?
    @State private var tab = BookTab.overview

    // Highlights → flashcards (propose→accept, nothing persists until Accept)
    @State private var cardDrafts: [CardDraft] = []
    @State private var cardsLoading = false
    @State private var cardTask: Task<Void, Never>?
    // OCR (scanned PDFs)
    @State private var ocrURL: URL?
    @State private var ocrProgress: Double = 0
    @State private var ocrBox: CancelBox?

    private var idx: Int? { state.data.reading.firstIndex { $0.id == itemID } }
    private var item: ReadingItem? { idx.map { state.data.reading[$0] } }

    var body: some View {
        VStack(spacing: 0) {
            SubHeader(item?.title ?? "Book") {
                if let item {
                    let inList = state.data.readingList.contains {
                        (!item.url.isEmpty && $0.url == item.url)
                        || $0.title.caseInsensitiveCompare(item.title) == .orderedSame
                    }
                    Button { state.addToReadingList(item) } label: {
                        Image(systemName: inList ? "bookmark.fill" : "bookmark")
                    }
                    .buttonStyle(.borderless).disabled(inList)
                    .help(inList ? "Already in Reading List" : "Add to Reading List")
                }
                Button { editing = true } label: { Image(systemName: "pencil") }.buttonStyle(.borderless)
                Button(role: .destructive) { deleteBook() } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).foregroundStyle(.red)
            }
            Divider()
            if let item {
                ScrollView {
                    VStack(spacing: 14) {
                        compactHeader(item)
                        Picker("", selection: $tab) {
                            ForEach(BookTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented).labelsHidden()
                        switch tab {
                        case .overview:
                            pageControls(item)
                            chaptersBlock(item)
                            if item.done { finishedBlock(item) }
                            if !item.notes.isEmpty { notesBlock(item) }
                        case .highlights:
                            highlightsBlock(item)
                        case .ask:
                            pdfBlock(item)
                        }
                    }.padding(16)
                }
            } else {
                EmptyState(symbol: "book", title: "Book removed", subtitle: "")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("").toolbar(.hidden, for: .windowToolbar)
        .navigationDestination(isPresented: $editing) { ReadingEditor(item: item ?? ReadingItem()) }
    }

    private func compactHeader(_ item: ReadingItem) -> some View {
        HStack(alignment: .top, spacing: 14) {
            CoverThumb(coverPath: item.coverPath, size: CGSize(width: 54, height: 78))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.headline).lineLimit(2)
                let meta = [item.author, item.publisher, item.year].filter { !$0.isEmpty }.joined(separator: " · ")
                if !meta.isEmpty { Text(meta).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                HStack(spacing: 8) {
                    ProgressView(value: item.progress).tint(item.done ? .green : .accentColor).frame(maxWidth: 190)
                    Text(item.usesUnits ? "\(item.unitsDone)/\(item.units.count)"
                         : (item.totalPages > 0 ? "p\(item.currentPage)/\(item.totalPages)" : "p\(item.currentPage)"))
                        .font(.caption).foregroundStyle(.secondary)
                    Button { state.toggleReadingDone(itemID) } label: {
                        Label(item.done ? "Undo" : "Mark done", systemImage: item.done ? "arrow.uturn.left" : "checkmark.circle")
                    }.buttonStyle(.borderless).font(.caption)
                }.padding(.top, 2)
                HStack(spacing: 6) {
                    if let p = item.pdfPages { metaChip("doc.text", "PDF · \(p) pp") }
                    if !item.highlights.isEmpty { metaChip("quote.opening", "\(item.highlights.count) highlights") }
                    CourseChip(course: state.course(item.courseID))
                    if !item.url.isEmpty {
                        Button { open(item.url) } label: { Image(systemName: "arrow.up.right.square") }
                            .buttonStyle(.borderless).font(.caption)
                    }
                }
                if !item.tags.isEmpty {
                    HStack(spacing: DS.Space.xs) { ForEach(item.tags, id: \.self) { Chip($0, .tag) } }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12).frame(maxWidth: .infinity)
        .background(.sbSurface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func metaChip(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon).font(.caption2)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.tint.opacity(0.12), in: Capsule()).foregroundStyle(.tint)
    }

    private func pageControls(_ item: ReadingItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !item.usesUnits {
                HStack(spacing: 10) {
                    Button { state.bumpReading(itemID, by: -10) } label: { Text("−10").frame(width: 38) }.buttonStyle(.bordered)
                    Button { state.bumpReading(itemID, by: -1) } label: { Image(systemName: "minus") }.buttonStyle(.bordered)
                    Button { state.bumpReading(itemID, by: 1) } label: { Image(systemName: "plus") }.buttonStyle(.borderedProminent)
                    Button { state.bumpReading(itemID, by: 10) } label: { Text("+10").frame(width: 38) }.buttonStyle(.bordered)
                    Spacer()
                    Text("Page").font(.caption).foregroundStyle(.secondary)
                    TextField("\(item.currentPage)", text: $pageField).textFieldStyle(.roundedBorder).frame(width: 64)
                        .onSubmit { if let p = Int(pageField) { state.setReadingPage(itemID, to: p) }; pageField = "" }
                    if item.totalPages > 0 { Text("of \(item.totalPages)").font(.caption).foregroundStyle(.secondary) }
                }
            }
            if let pace = paceHint(item) {
                Label(pace, systemImage: "calendar").font(.caption).foregroundStyle(.orange)
            } else if let eta = StudyStats.estimatedFinish(item, state.data) {
                Label("At your pace, done ~\(eta.dayMonth)", systemImage: "gauge.medium").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14).frame(maxWidth: .infinity)
        .background(.sbSurface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func notesBlock(_ item: ReadingItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("NOTES").font(.caption2.bold()).foregroundStyle(.secondary)
            SwiftMathContent(text: item.notes).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(12).background(.sbSurface, in: RoundedRectangle(cornerRadius: 10))
    }

    private func chaptersBlock(_ item: ReadingItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("CHAPTERS / TOPICS").font(.caption2.bold()).foregroundStyle(.secondary)
                Spacer()
                if item.usesUnits { Text("\(item.unitsDone)/\(item.units.count)").font(.caption2).foregroundStyle(.tint) }
            }
            if item.usesUnits {
                Text("Progress is tracked by chapters.").font(.caption2).foregroundStyle(.tertiary)
                ForEach(item.units) { u in
                    HStack(spacing: 8) {
                        Button { state.toggleReadingUnit(itemID, unitID: u.id) } label: {
                            Image(systemName: u.done ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(u.done ? .green : .secondary)
                        }.buttonStyle(.plain)
                        Text(u.title).strikethrough(u.done)
                            .foregroundStyle(u.done ? .secondary : .primary)
                        Spacer()
                        Button { deleteUnit(u) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary).font(.caption2)
                    }
                    .padding(8).background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                }
            } else {
                Text("Reading by chapter or topic? Add them here to track progress instead of pages.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            HStack {
                TextField("Add a chapter or topic…", text: $chapterText).textFieldStyle(.roundedBorder)
                    .onSubmit { addChapter() }
                Button("Add", action: addChapter).disabled(chapterText.isEmpty)
            }
            HStack {
                TextField("N", text: $bulkCount).textFieldStyle(.roundedBorder).frame(width: 44)
                Button("Add Chapters 1–N") { bulkAdd() }.disabled(Int(bulkCount) == nil)
                Spacer()
            }
        }
        .padding(12).background(.sbSurface.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
    }

    private func addChapter() {
        let t = chapterText.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        state.addReadingUnits(itemID, titles: [t]); chapterText = ""
    }
    private func bulkAdd() {
        guard let n = Int(bulkCount), n > 0, n <= 200 else { return }
        state.addReadingUnits(itemID, titles: (1...n).map { "Chapter \($0)" }); bulkCount = ""
    }
    private func deleteUnit(_ u: ReadingUnit) {
        guard let i = idx else { return }
        state.withUndo("Deleted chapter") { state.data.reading[i].units.removeAll { $0.id == u.id } }
    }

    private func finishedBlock(_ item: ReadingItem) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Text("Rating").font(.caption).foregroundStyle(.secondary)
                ForEach(1...5, id: \.self) { n in
                    Button { setRating(n == item.rating ? 0 : n) } label: {
                        Image(systemName: n <= item.rating ? "star.fill" : "star").foregroundStyle(.yellow)
                    }.buttonStyle(.plain)
                }
                Spacer()
                if let f = item.finishedAt {
                    Text("Finished \(f.dayMonth)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Button { state.rereadBook(itemID) } label: {
                Label("Read again", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity)
            }.buttonStyle(.bordered)
        }.padding(12).background(.sbSurface, in: RoundedRectangle(cornerRadius: 10))
    }

    private func highlightsBlock(_ item: ReadingItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("HIGHLIGHTS").font(.caption2.bold()).foregroundStyle(.secondary)
                Spacer()
                if !item.highlights.isEmpty {
                    Button { generateCards(item) } label: {
                        Label(cardsLoading ? "Thinking…" : "Make flashcards", systemImage: "sparkles")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless).disabled(cardsLoading)
                }
            }
            ForEach(item.highlights.sorted { $0.page < $1.page }) { h in
                HStack(alignment: .top, spacing: 8) {
                    Text("p\(h.page)").font(.caption2.monospacedDigit()).foregroundStyle(.tint)
                        .frame(width: 34, alignment: .leading)
                    Text(h.text).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    Button { deleteHighlight(h) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).font(.caption2)
                }
                .padding(8).background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            }
            if cardsLoading || !cardDrafts.isEmpty { draftsPanel(item) }
            HStack(spacing: 6) {
                TextField("p#", text: $hlPage).textFieldStyle(.roundedBorder).frame(width: 44)
                TextField("Add a quote or highlight…", text: $hlText).textFieldStyle(.roundedBorder)
                    .onSubmit { addHighlight() }
                Button("Add", action: addHighlight).disabled(hlText.isEmpty)
            }
        }
    }

    /// Proposed cards, editable inline, accepted onto a deck named after the book.
    @ViewBuilder private func draftsPanel(_ item: ReadingItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(cardsLoading ? "GENERATING…" : "PROPOSED CARDS")
                    .font(.caption2.bold()).foregroundStyle(.secondary)
                Spacer()
                if !cardDrafts.isEmpty && !cardsLoading {
                    Button("Add all \(cardDrafts.count)") { commitCards(cardDrafts); cardDrafts = [] }
                        .buttonStyle(.borderless).font(.caption.bold())
                    Button("Discard") { cardDrafts = [] }
                        .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
                }
            }
            if cardsLoading {
                ProgressView().controlSize(.small)
            }
            ForEach($cardDrafts) { $d in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("p\(d.page)").font(.caption2.monospacedDigit()).foregroundStyle(.tint)
                        Spacer()
                        Button { commitCards([d]); cardDrafts.removeAll { $0.id == d.id } } label: {
                            Image(systemName: "checkmark.circle.fill")
                        }.buttonStyle(.borderless).foregroundStyle(.green).help("Add this card")
                        Button { cardDrafts.removeAll { $0.id == d.id } } label: {
                            Image(systemName: "xmark")
                        }.buttonStyle(.borderless).foregroundStyle(.secondary).help("Skip")
                    }
                    TextField("Front", text: $d.front, axis: .vertical).textFieldStyle(.roundedBorder)
                    TextField("Back", text: $d.back, axis: .vertical).textFieldStyle(.roundedBorder)
                }
                .padding(8)
                .background(.sbSurface2, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            }
        }
        .padding(10)
        .background(.tint.opacity(0.06), in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }

    // MARK: PDF content layer (P1: attach → extract → search inside the book)

    private func pdfBlock(_ item: ReadingItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("CONTENT").font(.caption2.bold()).foregroundStyle(.secondary)
                Spacer()
                if item.pdfPages != nil {
                    Menu {
                        Button(role: .destructive) { removePDF() } label: { Label("Remove PDF", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis.circle") }.buttonStyle(.borderless)
                }
            }
            if pdfBusy {
                if ocrBox != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Reading pages with OCR — \(Int(ocrProgress * 100))%").font(.caption.weight(.medium))
                        ProgressView(value: ocrProgress).frame(maxWidth: 280)
                        Button("Cancel") { ocrBox?.cancel() }.buttonStyle(.bordered).controlSize(.small)
                    }
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Extracting text from the PDF…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if let pages = item.pdfPages {
                Label("PDF attached · \(pages) pages · searchable, on-device", systemImage: "doc.text.magnifyingglass")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search inside the book…", text: $bookQuery)
                        .textFieldStyle(.plain).onSubmit { runSearch() }
                    if !bookQuery.isEmpty {
                        Button { bookQuery = ""; bookHits = [] } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(8).background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                ForEach(bookHits) { h in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("p\(h.page)").font(.caption2.monospacedDigit()).foregroundStyle(.tint)
                        Text(h.snippet).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(8).background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                }
                if !bookQuery.trimmingCharacters(in: .whitespaces).isEmpty && bookHits.isEmpty {
                    Text("No matches on any page.").font(.caption).foregroundStyle(.secondary)
                }
                if AIConfig.isReady {
                    Divider().padding(.vertical, 2)
                    ForEach(askThread) { qa in
                        qaCard(qa, streaming: askLoading && qa.id == askThread.last?.id)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles").foregroundStyle(.tint)
                        TextField(askThread.isEmpty ? "Ask about the book…" : "Ask a follow-up…", text: $askQuery)
                            .textFieldStyle(.plain).onSubmit { askBook() }.disabled(askLoading)
                        if askLoading { ProgressView().controlSize(.small) }
                    }
                    .padding(8).background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                    if !askThread.isEmpty {
                        HStack {
                            Button { saveThread() } label: { Label("Save Q&A to notes", systemImage: "text.append") }
                                .buttonStyle(.borderless).controlSize(.small)
                            Spacer()
                            Button("Clear") { clearAsk() }.buttonStyle(.borderless).controlSize(.small)
                        }.font(.caption)
                    }
                }
            } else if let url = ocrURL {
                Label("No text layer — this PDF looks scanned.", systemImage: "doc.viewfinder")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button { runOCR(url) } label: { Label("Extract with OCR", systemImage: "text.viewfinder") }
                        .buttonStyle(.borderedProminent)
                    Button("Choose a different PDF") { attachPDF() }.buttonStyle(.bordered)
                }
                if let e = pdfError { Text(e).font(.caption).foregroundStyle(.orange) }
                Text("OCR reads the page images on-device with the system text recognizer — accurate but slow on big books (you can cancel).")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                Button { attachPDF() } label: { Label("Attach PDF to search inside", systemImage: "doc.badge.plus") }
                    .buttonStyle(.bordered)
                if let e = pdfError { Text(e).font(.caption).foregroundStyle(.orange) }
                Text("Adds a private, on-device text layer so you can search the book — and ask AI about it. Scanned PDFs are handled with OCR.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func qaCard(_ qa: BookQA, streaming: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(.tint).font(.caption)
                Text(qa.question).font(.callout.weight(.semibold))
                Spacer()
                if !qa.pages.isEmpty {
                    Text("from " + qa.pages.map { "p\($0)" }.joined(separator: ", "))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if qa.answer.isEmpty {
                Text("Thinking…").font(.callout).foregroundStyle(.secondary)
            } else if streaming {
                // Plain text while tokens arrive (cheap); math renders once the turn settles.
                Text(qa.answer).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                SwiftMathContent(text: qa.answer).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(.tint.opacity(0.06), in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(.tint.opacity(0.22)))
    }

    private func attachPDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pdfBusy = true; pdfError = nil; ocrURL = nil
        let id = itemID
        Task {
            let pages = await Task.detached { BookText.attach(url, to: id) }.value
            await MainActor.run {
                pdfBusy = false
                if let pages, let i = idx { state.data.reading[i].pdfPages = pages }
                else { ocrURL = url; pdfError = nil }   // no text layer → offer OCR
            }
        }
    }

    private func runOCR(_ url: URL) {
        let box = CancelBox()
        ocrBox = box; pdfBusy = true; ocrProgress = 0; pdfError = nil
        let id = itemID
        Task {
            let pages = await Task.detached {
                BookText.ocr(url, to: id, cancel: box) { p in Task { @MainActor in ocrProgress = p } }
            }.value
            await MainActor.run {
                pdfBusy = false; ocrBox = nil
                if let pages, let i = idx { state.data.reading[i].pdfPages = pages; ocrURL = nil }
                else if box.isCancelled { /* left as-is, user can retry */ }
                else { pdfError = "OCR couldn't read any text from this PDF." }
            }
        }
    }

    private func runSearch() {
        let q = bookQuery.trimmingCharacters(in: .whitespaces)
        bookHits = q.count >= 2 ? BookText.search(itemID, query: q) : []
    }

    private func askBook() {
        guard AIConfig.isReady, let provider = AIService.makeProvider(), !askLoading else { return }
        let q = askQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 3 else { return }
        askQuery = ""
        // qwen reasons well over more context, so retrieve deeper than a weak model could take.
        let chunks = BookText.topChunks(itemID, query: q, k: 8)
        guard !chunks.isEmpty else {
            askThread.append(BookQA(question: q, answer: "Not found in the book — try different wording.", pages: []))
            return
        }
        // Prior turns give the follow-up its context; only the NEW question carries fresh
        // excerpts, so history stays compact and within the model's window.
        var msgs: [AIMessage] = []
        for prior in askThread {
            msgs.append(AIMessage(role: .user, text: "Question: \(prior.question)"))
            msgs.append(AIMessage(role: .assistant, text: prior.answer))
        }
        let excerpts = chunks.map { "[p\($0.page)] \($0.text.prefix(2000))" }.joined(separator: "\n\n")
        msgs.append(AIMessage(role: .user, text: "Question: \(q)\n\nExcerpts:\n\(excerpts)"))

        askThread.append(BookQA(question: q, answer: "", pages: chunks.map(\.page)))
        let turnIdx = askThread.count - 1
        askLoading = true
        let sys = "You answer a student's question about their book using ONLY the excerpts provided in the latest turn (earlier turns are conversation context). Cite the page(s) you used inline like (p42). Write ALL mathematics as LaTeX between single dollar signs — e.g. $y' = y$, $\\int_0^1 x\\,dx$, $e^{x}$ — never as plain text. If the answer is not in the excerpts, reply exactly: Not found in the retrieved pages — try rephrasing. Do not use outside knowledge. Be concise; you may build on earlier answers for follow-ups."
        askTask?.cancel()
        askTask = Task {
            let out: String?
            if let ollama = provider as? OllamaProvider {
                out = try? await ollama.completePlainStreaming(system: sys, messages: msgs, numCtx: 16384) { p in
                    if askThread.indices.contains(turnIdx) { askThread[turnIdx].answer = p }
                }
            } else {
                out = try? await provider.completePlain(system: sys, messages: msgs)
            }
            await MainActor.run {
                askLoading = false
                if askThread.indices.contains(turnIdx) {
                    let final = (out ?? askThread[turnIdx].answer).trimmingCharacters(in: .whitespacesAndNewlines)
                    askThread[turnIdx].answer = final.isEmpty ? "No answer — try rephrasing, or a stronger engine." : mathify(final)
                }
            }
        }
    }

    /// Weak local models ignore the "use LaTeX" instruction and write equations as plain text.
    /// If the answer has no math delimiters, wrap standalone equation-looking lines in $$…$$ so
    /// SwiftMath (or the KaTeX fallback) typesets them. Conservative: prose lines — many words
    /// or ending in sentence punctuation — are left untouched.
    private func mathify(_ raw: String) -> String {
        // Normalize the \[ \] and \( \) delimiters many models emit (qwen does) to StudyBar's
        // $$ / $, which SwiftMath understands.
        let text = raw
            .replacingOccurrences(of: "\\[", with: "$$").replacingOccurrences(of: "\\]", with: "$$")
            .replacingOccurrences(of: "\\(", with: "$").replacingOccurrences(of: "\\)", with: "$")
        if text.contains("$") { return text }
        return text.components(separatedBy: "\n").map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.contains("="), !t.hasSuffix("."), !t.hasSuffix(":"), !t.hasSuffix(",") else { return line }
            let words = t.split(separator: " ").count
            let mathish = t.contains { "+-/*^_(){}".contains($0) }
            guard words <= 10, mathish else { return line }
            return "$$\(t)$$"
        }.joined(separator: "\n")
    }

    private func saveThread() {
        guard let i = idx, !askThread.isEmpty else { return }
        let text = askThread.map { "Q: \($0.question)\n\($0.answer)" }.joined(separator: "\n\n")
        let existing = state.data.reading[i].notes
        state.data.reading[i].notes = existing.isEmpty ? text : existing + "\n\n" + text
    }
    private func clearAsk() {
        askTask?.cancel(); askTask = nil
        askQuery = ""; askThread = []; askLoading = false
    }

    private func removePDF() {
        BookText.remove(itemID)
        if let i = idx { state.data.reading[i].pdfPages = nil }
        bookQuery = ""; bookHits = []; pdfError = nil; ocrURL = nil; clearAsk()
    }

    private func paceHint(_ item: ReadingItem) -> String? {
        guard !item.done, let target = item.targetDate, item.totalPages > 0, item.pagesLeft > 0 else { return nil }
        let rawDays = Calendar.current.dateComponents([.day], from: .now, to: target).day ?? 0
        if rawDays < 0 { return "Target date passed" }
        let perDay = Int(ceil(Double(item.pagesLeft) / Double(max(1, rawDays))))
        return "~\(perDay) pages/day to finish by \(target.dayMonth)"
    }

    private func deleteBook() {
        state.withUndo("Deleted book") { state.data.reading.removeAll { $0.id == itemID } }
        dismiss()
    }
    private func setRating(_ n: Int) { guard let i = idx else { return }; state.data.reading[i].rating = n }
    private func addHighlight() {
        guard let i = idx, !hlText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        state.data.reading[i].highlights.append(Highlight(page: Int(hlPage) ?? 0, text: hlText.trimmingCharacters(in: .whitespaces)))
        hlPage = ""; hlText = ""
    }
    private func deleteHighlight(_ h: Highlight) {
        guard let i = idx else { return }
        state.withUndo("Deleted highlight") { state.data.reading[i].highlights.removeAll { $0.id == h.id } }
    }

    private func generateCards(_ item: ReadingItem) {
        guard !cardsLoading else { return }
        cardsLoading = true
        cardDrafts = []
        cardTask?.cancel()
        let provider = AIConfig.isReady ? AIService.makeProvider() : nil
        cardTask = Task {
            let drafts = await HighlightCards.drafts(for: item, provider: provider)
            await MainActor.run {
                cardsLoading = false
                cardDrafts = drafts
            }
        }
    }

    /// Accept drafts onto a deck named after the book (reuse-or-create), then into SM-2.
    private func commitCards(_ drafts: [CardDraft]) {
        guard let i = idx else { return }
        let valid = drafts.filter {
            !$0.front.trimmingCharacters(in: .whitespaces).isEmpty &&
            !$0.back.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard !valid.isEmpty else { return }
        let name = state.data.reading[i].title.isEmpty ? "Highlights" : state.data.reading[i].title
        let courseID = state.data.reading[i].courseID
        state.withUndo("Made \(valid.count) flashcard\(valid.count == 1 ? "" : "s")") {
            let deck: Deck
            if let existing = state.data.decks.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                deck = existing
            } else {
                deck = Deck(name: name, courseID: courseID)
                state.data.decks.append(deck)
            }
            for d in valid {
                state.data.flashcards.append(Flashcard(deckID: deck.id, front: d.front, back: d.back))
            }
        }
    }
    private func open(_ s: String) {
        let u = s.contains("://") ? s : "https://\(s)"
        if let url = URL(string: u) { NSWorkspace.shared.open(url) }
    }
}

// MARK: - Add a book (search by title or ISBN)

struct BookLookupView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var loading = false
    @State private var results: [BookInfo] = []
    @State private var error = ""
    @State private var scanning = false
    @State private var added = false

    var body: some View {
        VStack(spacing: 0) {
            SubHeader("Add a Book")
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search by title or ISBN…", text: $query).textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await run() } }
                    if BarcodeScanner.isAvailable {
                        Button { scanning.toggle() } label: { Image(systemName: "camera") }.help("Scan barcode")
                    }
                    Button("Search") { Task { await run() } }
                        .buttonStyle(.borderedProminent).disabled(query.count < 2 || loading)
                }
                if scanning {
                    BarcodeScannerView { code in query = code; scanning = false; Task { await run() } }
                        .frame(height: 190).clipShape(RoundedRectangle(cornerRadius: 10))
                    Button("Stop camera") { scanning = false }.font(.caption)
                }
                if loading { HStack { ProgressView().controlSize(.small); Text("Searching…").font(.caption).foregroundStyle(.secondary) } }
                if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
                if added { Label("Added to your shelf", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }

                if results.isEmpty && error.isEmpty && !loading {
                    Text("Type a book title (or an ISBN) and hit Search. Tap a result to add it — cover, author and page count come along.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(results.enumerated()), id: \.offset) { _, info in
                            resultRow(info)
                        }
                    }
                }
            }.padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("").toolbar(.hidden, for: .windowToolbar)
    }

    private func resultRow(_ info: BookInfo) -> some View {
        Button { addBook(info) } label: {
            HStack(spacing: 10) {
                RemoteThumb(url: info.coverURL, size: CGSize(width: 40, height: 58))
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.title).fontWeight(.medium).lineLimit(2)
                    if !info.author.isEmpty { Text(info.author).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    Text([info.year, info.pageCount > 0 ? "\(info.pageCount) p" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                Image(systemName: "plus.circle.fill").foregroundStyle(.tint)
            }
            .padding(8).contentShape(Rectangle())
            .background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        }.buttonStyle(.plain)
    }

    private func run() async {
        error = ""; results = []; added = false; loading = true
        defer { loading = false }
        let digits = query.filter { $0.isNumber }
        let looksISBN = (digits.count == 10 || digits.count == 13)
            && query.allSatisfy { $0.isNumber || $0 == "-" || $0.isWhitespace || $0 == "X" || $0 == "x" }
        if looksISBN {
            if let info = await BookLookup.fetch(isbn: query) { results = [info] }
            else { error = "No match for that ISBN — try searching the title instead." }
        } else {
            results = await BookLookup.search(title: query)
            if results.isEmpty { error = "No books found. Check spelling, or add it manually with the title field." }
        }
    }

    private func addBook(_ info: BookInfo) {
        let item = ReadingItem(title: info.title, author: info.author, isbn: info.isbn,
                               publisher: info.publisher, year: info.year, totalPages: info.pageCount)
        let id = item.id
        state.data.reading.append(item)
        let coverURL = info.coverURL
        Task { @MainActor in
            if let name = await CoverStore.download(from: coverURL, id: id),
               let i = state.data.reading.firstIndex(where: { $0.id == id }) {
                state.data.reading[i].coverPath = name
            }
        }
        added = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { dismiss() }
    }
}

/// Async-loading cover thumbnail from a URL (for search results / previews).
struct RemoteThumb: View {
    let url: String
    var size: CGSize
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                    .overlay(Image(systemName: "book.closed").font(.caption2).foregroundStyle(.secondary))
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task {
            guard image == nil, let u = URL(string: url),
                  let data = try? await URLSession.sb.data(from: u).0 else { return }
            image = NSImage(data: data)
        }
    }
}

// MARK: - Goodreads CSV import

struct GoodreadsImportView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var summary = ""

    var body: some View {
        VStack(spacing: 0) {
            SubHeader("Import Goodreads")
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("Export your library from Goodreads (My Books ▸ Import/Export ▸ Export Library), then choose the CSV here.")
                    .font(.caption).foregroundStyle(.secondary)
                Button { importing = true } label: { Label("Choose CSV…", systemImage: "doc") }.buttonStyle(.borderedProminent)
                if !summary.isEmpty { Text(summary).font(.callout).foregroundStyle(.green) }
                Spacer()
            }.padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("").toolbar(.hidden, for: .windowToolbar)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            if case .success(let url) = result { runImport(url) }
        }
    }

    private func runImport(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { summary = "Couldn't read file."; return }
        let rows = CSV.parse(text)
        guard let header = rows.first else { summary = "Empty file."; return }
        func col(_ name: String) -> Int? { header.firstIndex { $0.caseInsensitiveCompare(name) == .orderedSame } }
        let ti = col("Title"), ai = col("Author"), pi = col("Number of Pages")
        let ri = col("My Rating"), si = col("Exclusive Shelf")
        let i13 = col("ISBN13"), i10 = col("ISBN")
        var added = 0
        for row in rows.dropFirst() {
            guard let ti, ti < row.count, !row[ti].isEmpty else { continue }
            func clean(_ i: Int?) -> String { guard let i, i < row.count else { return "" }
                return row[i].replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces) }
            let shelf = clean(si).lowercased()
            var item = ReadingItem(title: clean(ti), author: clean(ai),
                                   isbn: clean(i13).isEmpty ? clean(i10) : clean(i13),
                                   totalPages: Int(clean(pi)) ?? 0)
            item.rating = Int(clean(ri)) ?? 0
            if shelf == "read" { item.done = true; item.finishedAt = .now; item.currentPage = item.totalPages; item.timesRead = 1 }
            else if shelf == "currently-reading" { item.currentPage = max(1, item.totalPages / 4) }
            state.data.reading.append(item)
            added += 1
        }
        summary = "Imported \(added) books."
    }
}

/// Minimal RFC-4180-ish CSV parser (handles quoted fields with commas/newlines).
enum CSV {
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []; var row: [String] = []; var field = ""; var inQuotes = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" { if i + 1 < chars.count && chars[i+1] == "\"" { field.append("\""); i += 1 } else { inQuotes = false } }
                else { field.append(c) }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\r": break
                case "\n": row.append(field); rows.append(row); row = []; field = ""
                default: field.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }
}

// MARK: - Metadata editor

struct ReadingEditor: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ReadingItem
    @State private var tagText: String
    init(item: ReadingItem) {
        _draft = State(initialValue: item)
        _tagText = State(initialValue: item.tags.joined(separator: ", "))
    }

    var body: some View {
        VStack(spacing: 0) {
            SubHeader("Edit Book") {
                Button("Delete", role: .destructive) { state.withUndo("Deleted book") { state.data.reading.removeAll { $0.id == draft.id } }; dismiss() }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    field("Title") { TextField("", text: $draft.title).textFieldStyle(.roundedBorder) }
                    field("Author") { TextField("", text: $draft.author).textFieldStyle(.roundedBorder) }
                    HStack {
                        field("Current page") { TextField("", value: $draft.currentPage, format: .number).textFieldStyle(.roundedBorder) }
                        field("Total pages") { TextField("", value: $draft.totalPages, format: .number).textFieldStyle(.roundedBorder) }
                    }
                    HStack {
                        field("Publisher") { TextField("", text: $draft.publisher).textFieldStyle(.roundedBorder) }
                        field("Year") { TextField("", text: $draft.year).textFieldStyle(.roundedBorder) }
                    }
                    field("Tags") { TextField("fiction, favorites…", text: $tagText).textFieldStyle(.roundedBorder) }
                    field("Link") { TextField("https://…", text: $draft.url).textFieldStyle(.roundedBorder) }
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Finish-by date", isOn: Binding(
                            get: { draft.targetDate != nil },
                            set: { draft.targetDate = $0 ? (draft.targetDate ?? Calendar.current.date(byAdding: .day, value: 7, to: .now)) : nil }))
                        if draft.targetDate != nil {
                            DatePicker("Target", selection: Binding(get: { draft.targetDate ?? .now }, set: { draft.targetDate = $0 }),
                                       displayedComponents: .date)
                        }
                    }
                    field("Notes") {
                        TextEditor(text: $draft.notes).frame(height: 70).font(.callout)
                            .overlay(alignment: .topTrailing) { AITextMenu(text: $draft.notes, context: draft.title).padding(6) }
                            .scrollContentBackground(.hidden)
                            .background(.sbSurface, in: RoundedRectangle(cornerRadius: 6))
                    }
                    HStack {
                        Text("Course").font(.caption).foregroundStyle(.secondary)
                        CoursePicker(courseID: $draft.courseID)
                        Spacer()
                        Toggle("Done", isOn: $draft.done)
                    }
                }.padding(14)
            }
            Divider()
            HStack { Spacer(); Button("Cancel") { dismiss() }
                Button("Save") { save() }.keyboardShortcut(.defaultAction) }.padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("").toolbar(.hidden, for: .windowToolbar)
    }

    @ViewBuilder private func field<C: View>(_ l: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(l).font(.caption).foregroundStyle(.secondary); c() }
    }
    private func save() {
        draft.tags = tagText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        draft.updatedAt = .now
        // Update-only: never append here (this editor only edits existing books).
        if let i = state.data.reading.firstIndex(where: { $0.id == draft.id }) {
            if draft.title.trimmingCharacters(in: .whitespaces).isEmpty {
                state.data.reading.remove(at: i)
            } else {
                state.data.reading[i] = draft
            }
        }
        dismiss()
    }
}
