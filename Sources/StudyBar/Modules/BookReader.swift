import PDFKit
import SwiftUI

/// A book's attached PDF, read inside StudyBar: it opens at your page and keeps your place, the
/// tutor beside it (⌘J) reads the page you're on, and Highlight saves the selection to the
/// book's highlights — where they can become flashcards.
///
/// Highlights aren't written into the PDF. Each is drawn when the book opens, found by its text
/// on its page, so deleting one (and undoing that) needs nothing done to the file, and one
/// typed into the Highlights list is drawn too when its text is there.
struct BookReader: View {
    @EnvironmentObject var state: AppState
    let itemID: UUID
    /// Open here instead of the page the student was on — a search hit's page.
    var startPage: Int? = nil
    @StateObject private var reader = ReaderModel()
    @State private var page = 1

    private var idx: Int? { state.data.reading.firstIndex { $0.id == itemID } }

    var body: some View {
        VStack(spacing: 0) {
            SubHeader(idx.map { state.data.reading[$0].title } ?? "Book") {
                Text(reader.label(page)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button { highlight() } label: { Label("Highlight", systemImage: "highlighter") }
                    .buttonStyle(.borderless).disabled(!reader.hasSelection)
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                    .help("Save the selected text to the book's highlights (⇧⌘H)")
            }
            Divider()
            BookPDFView(url: BookText.pdfURL(itemID), start: max(1, startPage ?? idx.map { state.data.reading[$0].currentPage } ?? 1),
                        reader: reader, page: $page)
        }
        .studyFocus(.reading(itemID, page: page))
        .onChange(of: reader.loaded) { _, ok in if ok { drawHighlights() } }
        .onChange(of: page) { _, p in
            guard let i = idx else { return }
            state.data.reading[i].currentPage = p
            if state.data.reading[i].totalPages == 0 { state.data.reading[i].totalPages = reader.pageCount }
        }
        .navigationTitle("").toolbar(.hidden, for: .windowToolbar).navigationBarBackButtonHidden()
    }

    private func highlight() {
        guard let i = idx, let h = reader.takeSelection() else { return }
        state.data.reading[i].highlights.append(h)
        reader.draw(h)
    }

    private func drawHighlights() {
        guard let i = idx else { return }
        for h in state.data.reading[i].highlights { reader.draw(h) }
    }
}

@MainActor
final class ReaderModel: ObservableObject {
    weak var view: PDFView?
    @Published var hasSelection = false
    @Published var loaded = false

    var pageCount: Int { view?.document?.pageCount ?? 0 }

    /// The page's printed number where the book has one ("p. 120 · 136 of 950"), else its place.
    func label(_ page: Int) -> String {
        guard let doc = view?.document, let p = doc.page(at: page - 1) else { return "" }
        let printed = p.label.flatMap { $0 == "\(page)" ? nil : "p. \($0) · " } ?? ""
        return "\(printed)\(page) of \(doc.pageCount)"
    }

    /// The selection as a highlight, and the selection cleared.
    func takeSelection() -> Highlight? {
        guard let v = view, let sel = v.currentSelection, let first = sel.pages.first, let doc = v.document else { return nil }
        let text = (sel.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        v.clearSelection()
        return Highlight(page: doc.index(for: first) + 1, text: text)
    }

    /// The highlight drawn where its text is on its page; nothing if the text isn't there.
    func draw(_ h: Highlight) {
        guard let page = view?.document?.page(at: h.page - 1), let all = page.string else { return }
        let r = (all as NSString).range(of: h.text)
        guard r.location != NSNotFound, let sel = page.selection(for: r) else { return }
        for line in sel.selectionsByLine() {
            let a = PDFAnnotation(bounds: line.bounds(for: page), forType: .highlight, withProperties: nil)
            a.color = NSColor.systemYellow.withAlphaComponent(0.45)
            a.userName = h.id.uuidString
            page.addAnnotation(a)
        }
    }
}

private struct BookPDFView: NSViewRepresentable {
    let url: URL
    let start: Int
    let reader: ReaderModel
    @Binding var page: Int

    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.document = PDFDocument(url: url)
        reader.view = v
        if let p = v.document?.page(at: start - 1) { v.go(to: p) }
        let nc = NotificationCenter.default
        nc.addObserver(context.coordinator, selector: #selector(Coordinator.pageChanged(_:)), name: .PDFViewPageChanged, object: v)
        nc.addObserver(context.coordinator, selector: #selector(Coordinator.selectionChanged(_:)), name: .PDFViewSelectionChanged, object: v)
        DispatchQueue.main.async { reader.loaded = v.document != nil }
        return v
    }

    func updateNSView(_ v: PDFView, context: Context) { context.coordinator.page = $page }

    func makeCoordinator() -> Coordinator { Coordinator(page: $page, reader: reader) }

    @MainActor
    final class Coordinator: NSObject {
        var page: Binding<Int>
        let reader: ReaderModel
        init(page: Binding<Int>, reader: ReaderModel) { self.page = page; self.reader = reader }
        @objc func pageChanged(_ n: Notification) {
            guard let v = n.object as? PDFView, let p = v.currentPage, let i = v.document?.index(for: p) else { return }
            if page.wrappedValue != i + 1 { page.wrappedValue = i + 1 }
        }
        @objc func selectionChanged(_ n: Notification) {
            let has = !((n.object as? PDFView)?.currentSelection?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if reader.hasSelection != has { reader.hasSelection = has }
        }
    }
}
