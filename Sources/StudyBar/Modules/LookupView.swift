import SwiftUI

/// Free research lookups — Wikipedia summaries and arXiv paper search — with one-tap
/// save into Notes / Reading List / Citations. Discovery, not tutoring.
struct LookupView: View {
    @EnvironmentObject var state: AppState
    enum Source: String, CaseIterable, Identifiable { case wikipedia = "Wikipedia", arxiv = "arXiv", doi = "DOI → PDF"; var id: String { rawValue } }

    @State private var source = Source.wikipedia
    @State private var query = ""
    @State private var loading = false
    @State private var wiki: WikiSummary?
    @State private var papers: [Paper] = []
    @State private var oa: OAWork?
    @State private var status = ""
    @State private var searched = false

    var body: some View {
        NavigationStack {
            ModulePane(title: "Lookup") { EmptyView() } content: {
                VStack(spacing: 0) {
                    Picker("", selection: $source) {
                        ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().padding(8)
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(placeholder, text: $query)
                            .textFieldStyle(.plain).onSubmit(run)
                        if loading { ProgressView().controlSize(.small) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
                            switch source {
                            case .wikipedia: if let wiki { wikiCard(wiki) } else { empty }
                            case .arxiv:     if papers.isEmpty { empty } else { ForEach(papers) { paperCard($0) } }
                            case .doi:       if let oa { oaCard(oa) } else { empty }
                            }
                        }.padding(12)
                    }
                }
            }
        }
    }

    private var placeholder: String {
        switch source {
        case .wikipedia: return "Look up a term…"
        case .arxiv:     return "Search papers…"
        case .doi:       return "Paste a DOI (10.xxxx/…)…"
        }
    }
    private var empty: some View {
        let hint: String
        switch source {
        case .wikipedia: hint = "Search Wikipedia for a quick, citable summary."
        case .arxiv:     hint = "Search arXiv for papers to read or cite."
        case .doi:       hint = "Paste a DOI to find a free open-access PDF (via OpenAlex)."
        }
        return Text(searched ? "No results — try again." : hint)
            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
    }

    private func oaCard(_ w: OAWork) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(w.title).font(.subheadline.weight(.semibold))
            if !w.authors.isEmpty || !w.year.isEmpty {
                Text([w.authors.prefix(3).joined(separator: ", ") + (w.authors.count > 3 ? " et al." : ""), w.year]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Label(w.isOA ? "Open access available" : "No free full text found",
                  systemImage: w.isOA ? "lock.open" : "lock")
                .font(.caption).foregroundStyle(w.isOA ? .green : .secondary)
            HStack(spacing: 8) {
                if let pdf = w.pdfURL {
                    Button { open(pdf) } label: { Label("Open PDF", systemImage: "doc.text") }
                }
                if let landing = w.landingURL {
                    Button { open(landing) } label: { Label("Publisher page", systemImage: "safari") }
                }
                Button {
                    var ref = Reference(type: .article, title: w.title, year: w.year)
                    ref.authors = w.authors; ref.doi = w.doi
                    ref.url = w.pdfURL ?? w.landingURL ?? "https://doi.org/\(w.doi)"
                    state.data.references.append(ref)
                    status = "Added to Citations."
                } label: { Label("Cite", systemImage: "quote.opening") }
            }.buttonStyle(.bordered).controlSize(.small)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.sbSurface, in: RoundedRectangle(cornerRadius: 10))
    }

    private func wikiCard(_ w: WikiSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(w.title).font(.headline)
            Text(w.extract).font(.callout).foregroundStyle(.secondary)
            HStack {
                Button { open(w.url) } label: { Label("Open", systemImage: "safari") }
                Button {
                    state.data.notes.append(Note(title: w.title, body: "\(w.extract)\n\nSource: \(w.url)"))
                    status = "Saved “\(w.title)” to Notes."
                } label: { Label("Save as note", systemImage: "note.text.badge.plus") }
            }.buttonStyle(.bordered).controlSize(.small)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.sbSurface, in: RoundedRectangle(cornerRadius: 10))
    }

    private func paperCard(_ p: Paper) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(p.title).font(.subheadline.weight(.semibold))
            Text(authorLine(p)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(p.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            HStack(spacing: 8) {
                Button { open(p.pdfURL.isEmpty ? p.url : p.pdfURL) } label: { Label("Open", systemImage: "doc.text") }
                Button {
                    state.data.readingList.append(ReadingListItem(title: p.title, url: p.url))
                    status = "Added to Reading List."
                } label: { Label("Read later", systemImage: "books.vertical") }
                Button {
                    var ref = Reference(type: .article, title: p.title, year: p.year)
                    ref.authors = p.authors
                    ref.url = p.url
                    ref.container = "arXiv"
                    state.data.references.append(ref)
                    status = "Added to Citations."
                } label: { Label("Cite", systemImage: "quote.opening") }
            }.buttonStyle(.bordered).controlSize(.small)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.sbSurface, in: RoundedRectangle(cornerRadius: 10))
    }

    private func authorLine(_ p: Paper) -> String {
        let a = p.authors.prefix(3).joined(separator: ", ")
        let more = p.authors.count > 3 ? " et al." : ""
        return [a + more, p.year].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func run() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !loading else { return }
        loading = true; status = ""; searched = true
        Task {
            switch source {
            case .wikipedia: wiki = await ResearchLookup.wikipedia(q); papers = []; oa = nil
            case .arxiv:     papers = await ResearchLookup.arxiv(q); wiki = nil; oa = nil
            case .doi:       oa = await ResearchLookup.openAlex(doi: q); wiki = nil; papers = []
            }
            loading = false
        }
    }

    private func open(_ s: String) {
        guard let url = URL(string: s.contains("://") ? s : "https://\(s)") else { return }
        NSWorkspace.shared.open(url)
    }
}
