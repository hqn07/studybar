import PDFKit
import SwiftUI

/// A lecture's slides beside its note, turned to the slide the section you're in is about —
/// `## Slide 7 — …`, the headings study notes made with the slides are written under. A PDF deck
/// shows its pages; a PowerPoint, which macOS can't draw, its slides' text.
struct SlidesPane: View {
    let file: StudyFile
    @Binding var page: Int

    private var url: URL { StudyMaterial.fileURL(file) }
    private var isPDF: Bool { url.pathExtension.lowercased() == "pdf" }
    private var outline: [(number: Int, text: String)] { StudyMaterial.slideOutline(file) }
    private var count: Int { isPDF ? (PDFDocument(url: url)?.pageCount ?? 1) : max(1, outline.map(\.number).max() ?? 1) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.on.rectangle").foregroundStyle(.secondary)
                Text(file.name).font(.caption).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button { page = max(1, page - 1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless).accessibilityLabel("Previous slide")
                Text("\(page) / \(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button { page = min(count, page + 1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless).accessibilityLabel("Next slide")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            if isPDF {
                SlidePDFView(url: url, page: $page)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(outline, id: \.number) { s in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Slide \(s.number)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    Text(s.text).font(.callout).textSelection(.enabled)
                                }
                                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(s.number == page ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                                .id(s.number)
                            }
                        }.padding(10)
                    }
                    .onChange(of: page) { _, p in withAnimation { proxy.scrollTo(p, anchor: .top) } }
                    .onAppear { proxy.scrollTo(page, anchor: .top) }
                }
            }
        }
        .background(.sbSurface.opacity(0.35))
    }
}

/// One page at a time; paging in the view itself moves the number above it too.
private struct SlidePDFView: NSViewRepresentable {
    let url: URL
    @Binding var page: Int

    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.document = PDFDocument(url: url)
        v.autoScales = true
        v.displayMode = .singlePage
        v.displaysPageBreaks = false
        v.backgroundColor = .clear
        context.coordinator.observe(v)
        return v
    }

    func updateNSView(_ v: PDFView, context: Context) {
        context.coordinator.page = $page
        if let p = v.document?.page(at: max(0, page - 1)), v.currentPage != p { v.go(to: p) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(page: $page) }

    final class Coordinator: NSObject {
        var page: Binding<Int>
        init(page: Binding<Int>) { self.page = page }
        func observe(_ v: PDFView) {
            NotificationCenter.default.addObserver(self, selector: #selector(changed(_:)), name: .PDFViewPageChanged, object: v)
        }
        @objc func changed(_ n: Notification) {
            guard let v = n.object as? PDFView, let p = v.currentPage, let i = v.document?.index(for: p) else { return }
            if page.wrappedValue != i + 1 { page.wrappedValue = i + 1 }
        }
    }
}
