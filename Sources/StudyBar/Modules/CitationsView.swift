import SwiftUI

struct CitationsView: View {
    @EnvironmentObject var state: AppState
    @AppStorage("citeStyle") private var styleRaw = CiteStyle.apa.rawValue
    @State private var editing: Reference?
    @State private var grabText = ""
    @State private var fetching = false
    @State private var error = ""
    @State private var notice = ""
    @State private var search = ""
    @State private var searchResults: [Reference] = []

    private var style: CiteStyle { CiteStyle(rawValue: styleRaw) ?? .apa }

    private var references: [Reference] {
        var list = state.data.references
        if !search.isEmpty {
            list = list.filter {
                $0.title.localizedCaseInsensitiveContains(search) ||
                $0.authors.joined(separator: " ").localizedCaseInsensitiveContains(search) ||
                $0.container.localizedCaseInsensitiveContains(search)
            }
        }
        return list.sorted { $0.addedAt > $1.addedAt }
    }

    var body: some View {
        NavigationStack {
            ModulePane(title: "Citations",
                       primary: ModuleAction(title: "New", systemImage: "plus", help: "Add a citation") { addManual() },
                       controls: {
                Picker("", selection: $styleRaw) {
                    ForEach(CiteStyle.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }.labelsHidden().fixedSize().help("Citation style")
            }, more: {
                Button { importFile() } label: {
                    Label("Import a library — BibTeX, RIS or CSL-JSON…", systemImage: "square.and.arrow.down")
                }
            }) {
                VStack(spacing: 0) {
                    grabBar
                    if state.data.references.count > 4 && searchResults.isEmpty {
                        SearchField(text: $search).padding(.horizontal, 10).padding(.bottom, 6)
                    }
                    Divider()
                    if !searchResults.isEmpty {
                        resultsPanel
                    } else if references.isEmpty {
                        EmptyState(symbol: "quote.opening",
                                   title: state.data.references.isEmpty ? "No citations" : "No matches",
                                   subtitle: state.data.references.isEmpty ? "Type a paper/book title above to search, or paste a DOI, URL or ISBN." : "Try a different search.")
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(references) { r in
                                    ReferenceRow(reference: r, style: style) { editing = r }
                                }
                            }.padding(10)
                        }
                        exportBar
                    }
                }
            }
            .navigationDestination(item: $editing) { ReferenceEditor(reference: $0).moduleColumn(DS.Width.form) }
        }
    }

    private var grabBar: some View {
        VStack(spacing: 4) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search by title, or paste a DOI / URL / ISBN…", text: $grabText, onCommit: grab)
                    .textFieldStyle(.plain)
                // Straight from the clipboard, so a pasted RIS record keeps the lines it needs.
                Button { if let s = NSPasteboard.general.string(forType: .string), !importText(s) { grabText = s; grab() } } label: {
                    Image(systemName: "doc.on.clipboard")
                    .accessibilityLabel("Paste and grab from the clipboard")
                }.buttonStyle(.borderless).help("Paste & grab from clipboard")
                if fetching {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Grab", action: grab).disabled(grabText.isEmpty)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            if !error.isEmpty {
                Text(error).font(.caption2).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
            }
            if !notice.isEmpty {
                Text(notice).font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
            }
        }
    }

    private var exportBar: some View {
        HStack {
            Text("\(state.data.references.count) references")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Menu {
                let all = state.data.references
                Button("Bibliography (\(style.rawValue))") {
                    copy(all.map { CitationFormatter.format($0, style: style).replacingOccurrences(of: "*", with: "") }.sorted().joined(separator: "\n\n"))
                }
                Divider()
                Button("BibTeX — LaTeX, Overleaf") { copy(all.map(CitationFormatter.bibtex).joined(separator: "\n\n")) }
                Button("RIS — EndNote, Mendeley, Zotero") { copy(all.map(CitationFormatter.ris).joined(separator: "\n")) }
                Button("CSL-JSON — Zotero, Pandoc") { copy(CitationFormatter.cslJSON(all)) }
            } label: { Label("Copy all as", systemImage: "doc.on.doc") }
                .menuStyle(.borderlessButton).fixedSize().font(.caption)
        }.padding(.horizontal, 12).padding(.vertical, 6)
    }

    /// BibTeX, RIS or CSL-JSON → straight into the library, skipping what's already there.
    /// False when the text is none of them.
    private func importText(_ text: String) -> Bool {
        let found = CitationFormatter.parse(text)
        guard !found.isEmpty else { return false }
        add(found)
        return true
    }

    private func add(_ found: [Reference]) {
        var added = 0
        for r in found where !CitationFormatter.isDuplicate(r, of: state.data.references) { state.data.references.append(r); added += 1 }
        error = ""; grabText = ""; searchResults = []
        notice = "Added \(added) reference\(added == 1 ? "" : "s")" + (found.count > added ? " — \(found.count - added) already in your library" : "") + "."
    }

    private func importFile() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.message = "A library exported from Zotero, Mendeley, EndNote or Google Scholar: .bib, .ris or CSL-JSON."
        guard p.runModal() == .OK else { return }
        // Each file in its own format: a .bib and a .ris can come in together.
        let found = p.urls.flatMap { u in
            CitationFormatter.parse((try? String(contentsOf: u, encoding: .utf8)) ?? (try? String(contentsOf: u, encoding: .isoLatin1)) ?? "")
        }
        if found.isEmpty { notice = ""; error = "No references found — the file should be BibTeX, RIS or CSL-JSON." } else { add(found) }
    }

    private func grab() {
        notice = ""
        if importText(grabText) { return }
        let q = grabText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        error = ""; searchResults = []; fetching = true
        let digits = q.filter { $0.isNumber }
        let looksISBN = (digits.count == 10 || digits.count == 13)
            && q.allSatisfy { $0.isNumber || $0 == "-" || $0.isWhitespace || $0 == "X" || $0 == "x" }
        let hasSpace = q.contains { $0.isWhitespace }
        Task {
            // ISBN → exact book lookup
            if looksISBN, let info = await BookLookup.fetch(isbn: q) {
                let ref = Reference(type: .book,
                                    authors: info.author.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
                                    title: info.title, year: info.year, container: info.publisher, doi: "")
                await MainActor.run { grabText = ""; fetching = false; editing = ref }
                return
            }
            // Multi-word → title search (list of candidates)
            if hasSpace {
                let results = await MetadataFetcher.search(title: q)
                await MainActor.run {
                    fetching = false
                    if results.isEmpty { error = "No results for that title. Try different words, or add manually." }
                    else { searchResults = results }
                }
                return
            }
            // Single token → treat as DOI / URL
            do {
                let r = try await MetadataFetcher.fetch(input: q)
                await MainActor.run { grabText = ""; fetching = false; editing = r }
            } catch {
                await MainActor.run {
                    // Distinguish "you're offline" from "that DOI didn't resolve".
                    let offline = (error as? URLError).map {
                        [.notConnectedToInternet, .timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost].contains($0.code)
                    } ?? false
                    self.error = offline
                        ? "Couldn't reach the citation service — check your connection and try again."
                        : "Couldn't fetch that. Try a title search instead."
                    fetching = false
                }
            }
        }
    }

    private var resultsPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SEARCH RESULTS (\(searchResults.count))").font(.caption2.bold()).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { searchResults = []; grabText = "" }.font(.caption).buttonStyle(.borderless)
            }.padding(.horizontal, 12).padding(.vertical, 6)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(searchResults) { r in
                        Button { editing = r; searchResults = []; grabText = "" } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.title).fontWeight(.medium).lineLimit(2)
                                    Text([r.authors.first, r.container.isEmpty ? nil : r.container, r.year.isEmpty ? nil : r.year]
                                        .compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "plus.circle.fill").foregroundStyle(.tint)
                            }
                            .padding(9).contentShape(Rectangle())
                            .sbRowSeparator(leading: DS.Space.m)
                        }.buttonStyle(.plain)
                    }
                }.padding(10)
            }
        }
    }

    private func addManual() { editing = Reference() }   // saved on confirm

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

struct ReferenceRow: View {
    @EnvironmentObject var state: AppState
    let reference: Reference
    let style: CiteStyle
    let onEdit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(rendered).font(.callout).textSelection(.enabled)
                HStack(spacing: DS.Space.s) {
                    Chip(reference.type.rawValue, .tag)
                    CourseChip(course: state.course(reference.courseID))
                }
            }
            Spacer()
            VStack(spacing: 6) {
                Button { copy(rendered) } label: { Image(systemName: "doc.on.doc").accessibilityLabel("Copy citation") }
                    .buttonStyle(.borderless).help("Copy full \(style.rawValue) citation")
                Button { copy(CitationFormatter.inText(reference)) } label: { Image(systemName: "text.quote").accessibilityLabel("Copy in-text citation") }
                    .buttonStyle(.borderless).help("Copy in-text \(CitationFormatter.inText(reference))")
                Button(action: onEdit) { Image(systemName: "pencil").accessibilityLabel("Edit citation") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                Button { state.withUndo("Deleted citation") { state.data.references.removeAll { $0.id == reference.id } } } label: {
                    Image(systemName: "trash")
                    .accessibilityLabel("Delete citation")
                }.buttonStyle(.borderless).foregroundStyle(.secondary).help("Delete — undo, or find it in the Trash")
            }.font(.caption)
        }
        .padding(DS.Space.m)
        .sbRowSeparator(leading: DS.Space.m)
    }

    // Strip markdown emphasis markers for plain display/copy.
    private var rendered: String {
        CitationFormatter.format(reference, style: style)
            .replacingOccurrences(of: "*", with: "")
    }
    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
