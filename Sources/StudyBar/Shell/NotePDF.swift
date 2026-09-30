import AppKit
import PDFKit
import SwiftUI
import WebKit

// MARK: - A note as a PDF

/// Paper settings for an exported note. Remembered between exports.
struct PDFOptions: Equatable {
    enum Paper: String, CaseIterable { case letter = "Letter", a4 = "A4" }
    enum Margins: String, CaseIterable { case narrow = "Narrow", normal = "Normal", wide = "Wide" }
    enum TextSize: String, CaseIterable { case small = "Small", normal = "Normal", large = "Large" }

    var paper: Paper
    var margins: Margins
    var textSize: TextSize
    var header: Bool
    var pageNumbers: Bool

    var paperSize: CGSize { paper == .letter ? CGSize(width: 612, height: 792) : CGSize(width: 595.28, height: 841.89) }
    var margin: CGFloat { switch margins { case .narrow: 36; case .normal: 54; case .wide: 72 } }
    /// Body text is laid out at 11 pt and the page is drawn at this scale, so Large reflows
    /// like a bigger font rather than a zoomed picture of the Normal page.
    var scale: CGFloat { switch textSize { case .small: 0.9; case .normal: 1; case .large: 1.15 } }

    private static let d = UserDefaults.standard
    static var saved: PDFOptions {
        PDFOptions(paper: Paper(rawValue: d.string(forKey: "pdfPaper") ?? "")
                       ?? (Locale.current.measurementSystem == .us ? .letter : .a4),
                   margins: Margins(rawValue: d.string(forKey: "pdfMargins") ?? "") ?? .normal,
                   textSize: TextSize(rawValue: d.string(forKey: "pdfTextSize") ?? "") ?? .normal,
                   header: d.object(forKey: "pdfHeader") as? Bool ?? true,
                   pageNumbers: d.object(forKey: "pdfPageNumbers") as? Bool ?? true)
    }
    func save() {
        Self.d.set(paper.rawValue, forKey: "pdfPaper"); Self.d.set(margins.rawValue, forKey: "pdfMargins")
        Self.d.set(textSize.rawValue, forKey: "pdfTextSize")
        Self.d.set(header, forKey: "pdfHeader"); Self.d.set(pageNumbers, forKey: "pdfPageNumbers")
    }
}

/// The note laid out by the same Markdown → HTML → KaTeX renderer the reading view falls back
/// to, then cut into pages *between* blocks and placed on paper with a header and page numbers.
///
/// This replaced a print of an `NSAttributedString` imported from HTML. That importer ignores
/// most CSS, and `NSTextView` pagination breaks wherever the page ends — so a heading sat alone
/// at the foot of a page, and tables and equations were split across two.
///
/// WebKit's own print pagination is still avoided: it produced a 2.7 GB PDF on a long note and
/// never finished. Here each page is a bounded `createPDF` of one slice, so the work is one
/// page of rendering per page.
@MainActor
enum NotePDF {
    struct Meta { var title: String; var subtitle: String }

    /// Pages past this are refused rather than rendered — a runaway layout fails, it doesn't fill the disk.
    static let maxPages = 300

    static func render(body: String, meta: Meta, options: PDFOptions) async -> Data? {
        let paper = options.paperSize, m = options.margin, s = options.scale
        let cssWidth = (paper.width - 2 * m) / s
        let pageHeight = (paper.height - 2 * m) / s

        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: cssWidth, height: pageHeight))
        let loader = Loader()
        web.navigationDelegate = loader
        web.loadHTMLString(page(body: body, meta: meta, width: cssWidth), baseURL: nil)
        guard await loader.finished() else { return nil }

        // Fonts are data URIs and decode asynchronously; measuring before they land cuts the
        // pages against metrics the PDF won't have.
        guard let raw = try? await web.callAsyncJavaScript(
                "await document.fonts.ready; fit(); return cuts(pageH);",
                arguments: ["pageH": Double(pageHeight)], contentWorld: .page) as? [Double],
              raw.count >= 2, raw.count - 1 <= maxPages
        else { return nil }
        let cuts = raw.map { CGFloat($0) }

        // The whole document inside the view's bounds, so every slice is a region of the view.
        web.frame.size.height = ceil(cuts.last ?? pageHeight)
        var slices: [CGPDFPage] = []
        for i in 0..<(cuts.count - 1) {
            let cfg = WKPDFConfiguration()
            cfg.rect = CGRect(x: 0, y: cuts[i], width: cssWidth, height: max(1, cuts[i + 1] - cuts[i]))
            guard let data = try? await web.pdf(configuration: cfg),
                  let provider = CGDataProvider(data: data as CFData),
                  let doc = CGPDFDocument(provider), let pg = doc.page(at: 1) else { return nil }
            slices.append(pg)
        }
        return compose(slices, meta: meta, options: options)
    }

    /// Each slice drawn at the top of the text column, scaled, with the header and footer in
    /// the margins. Drawing a PDF page into a PDF context keeps it vector and selectable.
    private static func compose(_ slices: [CGPDFPage], meta: Meta, options: PDFOptions) -> Data? {
        let paper = options.paperSize, m = options.margin, s = options.scale
        let out = NSMutableData()
        var box = CGRect(origin: .zero, size: paper)
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor(white: 0.45, alpha: 1)]
        let headerLeft = [meta.subtitle, meta.title].filter { !$0.isEmpty }.joined(separator: " — ")

        for (i, slice) in slices.enumerated() {
            ctx.beginPDFPage(nil)
            let media = slice.getBoxRect(.mediaBox)
            ctx.saveGState()
            ctx.translateBy(x: m, y: paper.height - m - media.height * s)
            ctx.scaleBy(x: s, y: s)
            ctx.translateBy(x: -media.minX, y: -media.minY)
            // A glyph taller than its line (a KaTeX ∮) is painted by both neighbouring slices;
            // without the clip the next page showed its top half above the text column.
            ctx.clip(to: media)
            ctx.drawPDFPage(slice)
            ctx.restoreGState()

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            let top = paper.height - m / 2 - 4
            if options.header, !headerLeft.isEmpty, i > 0 || meta.title.isEmpty {   // page 1 has the title block
                NSAttributedString(string: headerLeft, attributes: small)
                    .draw(with: CGRect(x: m, y: top, width: paper.width - 2 * m, height: 12),
                          options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }
            if options.pageNumbers {
                let label = NSAttributedString(string: "Page \(i + 1) of \(slices.count)", attributes: small)
                label.draw(at: CGPoint(x: (paper.width - label.size().width) / 2, y: m / 2 - 4))
            }
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return out as Data
    }

    private final class Loader: NSObject, WKNavigationDelegate {
        private var done: CheckedContinuation<Bool, Never>?
        private var result: Bool?
        func finished() async -> Bool {
            if let result { return result }
            return await withCheckedContinuation { done = $0 }
        }
        private func finish(_ ok: Bool) {
            guard result == nil else { return }
            result = ok; done?.resume(returning: ok); done = nil
        }
        func webView(_ w: WKWebView, didFinish n: WKNavigation!) { finish(true) }
        func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { finish(false) }
        func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { finish(false) }
    }

    /// Print styles: the reading view's rules on white, in points (a CSS px is a PDF point here).
    static func page(body: String, meta: Meta, width: CGFloat) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        }
        let head = meta.title.isEmpty ? "" : "<h1 class=\"title\">\(esc(meta.title))</h1>"
            + (meta.subtitle.isEmpty ? "" : "<p class=\"meta\">\(esc(meta.subtitle))</p>")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        \(KatexAssets.prelude)
        <style>
          html,body{margin:0;padding:0;background:#fff;}
          body{width:\(Int(width))px;color:#1d1d20;font:11px/1.5 -apple-system,"SF Pro Text",system-ui,sans-serif;overflow-wrap:break-word;}
          #c{display:flow-root;}
          p{margin:0 0 5px;} h1{font-size:18px;margin:12px 0 5px;} h2{font-size:14.5px;margin:12px 0 4px;} h3{font-size:12.5px;margin:10px 0 3px;}
          .title{font-size:21px;margin:0 0 2px;} .meta{color:#777;font-size:9.5px;margin:0 0 12px;}
          ul{margin:2px 0 5px;padding-left:16px;} li{margin:1px 0;} ul ul{margin:0;list-style:circle;} ul ul ul{list-style:square;}
          code{background:#f1f1f4;padding:0 3px;border-radius:3px;font:10px ui-monospace,Menlo,monospace;}
          blockquote{margin:4px 0;padding-left:8px;border-left:2px solid #bbb;color:#444;}
          a{color:#0a58ca;text-decoration:none;} mark{padding:0 1px;border-radius:2px;}
          img{max-width:100%;height:auto;}
          .katex{font-size:1.05em;} .katex-display{margin:6px 0;}
          table{border-collapse:collapse;margin:6px 0;}
          th,td{border:1px solid #bbb;padding:3px 6px;text-align:left;vertical-align:top;}
          th{background:#f0f0f2;font-weight:600;}
        </style></head><body><div id="c">\(head)\(body)</div>
        <script>
          renderMathInElement(document.getElementById('c'),{delimiters:[
            {left:'$$',right:'$$',display:true},{left:'\\\\[',right:'\\\\]',display:true},
            {left:'$',right:'$',display:false},{left:'\\\\(',right:'\\\\)',display:false}],throwOnError:false});

          // Anything wider than the column (a long equation, a many-column table) is scaled to
          // fit — a slice is clipped at the column edge, so overflow would be lost ink.
          function fit(){
            var W=document.getElementById('c').clientWidth;
            document.querySelectorAll('.katex-display,table,pre').forEach(function(e){
              var w=e.scrollWidth; if(w>W+1){e.style.zoom=(W/w).toFixed(3);}
            });
          }

          // Where each page ends: the lowest point on the page that doesn't cut through a
          // block. Blocks are paragraphs, list items (their own line, not their sub-list),
          // table rows, equations, images and quotes. A heading is held to the first lines of
          // what follows it, so it is never the last thing on a page.
          function cuts(pageH){
            var c=document.getElementById('c'), top=c.getBoundingClientRect().top;
            function box(e){var r=e.getBoundingClientRect();return [r.top-top,r.bottom-top];}
            var atoms=[];
            c.querySelectorAll('p,h1,h2,h3,li,tr,blockquote,pre,img,.katex-display').forEach(function(e){
              var b=box(e);
              if(e.tagName==='LI'){var sub=e.querySelector(':scope>ul');if(sub)b[1]=box(sub)[0];}
              if(/^H[1-3]$/.test(e.tagName)&&e.nextElementSibling){
                b[1]=Math.max(b[1],Math.min(box(e.nextElementSibling)[1],b[1]+48));
              }
              if(b[1]>b[0])atoms.push(b);
            });
            var total=Math.ceil(c.getBoundingClientRect().height);
            function safe(y){return atoms.every(function(a){return y<=a[0]+0.5||y>=a[1]-0.5;});}
            var cand=[];atoms.forEach(function(a){cand.push(a[0],a[1]);});
            cand.sort(function(a,b){return a-b;});
            var out=[0],start=0;
            while(total-start>pageH){
              var limit=start+pageH,best=-1;
              for(var i=0;i<cand.length;i++){var y=cand[i];if(y>limit)break;if(y>start+pageH*0.25&&safe(y))best=y;}
              if(best<0){
                // One block taller than a page: cut it, but between two lines of text.
                best=limit;
                var r=document.caretRangeFromPoint(c.getBoundingClientRect().left+2,top+limit);
                if(r){var cr=r.getBoundingClientRect();if(cr.height>0&&cr.top-top>start+pageH*0.25&&cr.top-top<limit)best=cr.top-top;}
              }
              out.push(best);start=best;
            }
            out.push(Math.max(total,start+1));
            return out;
          }
        </script></body></html>
        """
    }
}

// MARK: - Styled note → Markdown the renderer understands

/// A note written in the editor carries its formatting as attributes, not as Markdown: a
/// heading is a bigger font with no `#`, bold is a trait with no `**`. The renderer reads
/// Markdown, so this writes the attributes back out as Markdown, with the few things Markdown
/// can't say (color, highlight, underline, images) carried as HTML the converter passes through.
///
/// The PDF used to guess instead — "does the plain text contain `**` or a `- ` line?" — and a
/// styled note that matched was printed from its plain text, dropping its colors and images.
enum NoteHTML {
    static func body(from attr: NSAttributedString) -> String {
        let (md, raw) = serialize(attr, asMarkdown: false)
        return MathMarkdown.bodyHTML(md, raw: raw)
    }

    /// The same reading of a styled document, as portable Markdown: headings, lists, tables,
    /// bold, italic, code and links. Color, highlight and images have no Markdown and are left out.
    static func markdown(from attr: NSAttributedString) -> String {
        serialize(attr, asMarkdown: true).0
    }

    private static func serialize(_ attr: NSAttributedString, asMarkdown: Bool) -> (String, [String]) {
        var raw: [String] = []
        func tok(_ html: String) -> String { raw.append(html); return "\u{E010}\(raw.count - 1)\u{E011}" }

        let ns = attr.string as NSString
        let base = bodySize(attr)
        let baseMono = (attr.length > 0 ? attr.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil)?.isFixedPitch ?? false

        func inline(_ p: NSAttributedString, heading: Bool) -> String {
            var out = ""
            p.enumerateAttributes(in: NSRange(location: 0, length: p.length)) { a, r, _ in
                if let att = a[.attachment] as? NSTextAttachment { if !asMarkdown { out += image(att).map(tok) ?? "" }; return }
                var text = (p.string as NSString).substring(with: r)
                if asMarkdown {
                    text = text.replacingOccurrences(of: "\u{2028}", with: " ")
                    guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { out += text; return }
                    var open = "", close = ""
                    if let f = a[.font] as? NSFont {
                        let t = f.fontDescriptor.symbolicTraits
                        if t.contains(.bold), !heading { open += "**"; close = "**" + close }
                        if t.contains(.italic) { open += "*"; close = "*" + close }
                        if f.isFixedPitch, !baseMono { open += "`"; close = "`" + close }
                    }
                    if (a[.strikethroughStyle] as? Int ?? 0) != 0 { open += "~~"; close = "~~" + close }
                    // Emphasis marks hug the words; the run's own edge spaces stay outside them.
                    let lead = String(text.prefix { $0 == " " }), trail = String(text.reversed().prefix { $0 == " " })
                    var core = open + text.trimmingCharacters(in: .whitespaces) + close
                    if let link = a[.link] { core = "[\(core)](\((link as? URL)?.absoluteString ?? "\(link)"))" }
                    out += lead + core + trail
                    return
                }
                text = text.replacingOccurrences(of: "\u{2028}", with: tok("<br>"))
                var open = "", close = ""
                func wrap(_ o: String, _ c: String) { open += o; close = c + close }
                if let link = a[.link] {
                    let url = (link as? URL)?.absoluteString ?? "\(link)"
                    wrap("<a href=\"\(url.replacingOccurrences(of: "\"", with: "%22"))\">", "</a>")
                }
                if let f = a[.font] as? NSFont {
                    let t = f.fontDescriptor.symbolicTraits
                    if t.contains(.bold), !heading { wrap("<strong>", "</strong>") }
                    if t.contains(.italic) { wrap("<em>", "</em>") }
                    if f.isFixedPitch, !baseMono { wrap("<code>", "</code>") }
                }
                if (a[.underlineStyle] as? Int ?? 0) != 0, a[.link] == nil { wrap("<u>", "</u>") }
                if (a[.strikethroughStyle] as? Int ?? 0) != 0 { wrap("<s>", "</s>") }
                if let c = a[.foregroundColor] as? NSColor, let hex = chosenColor(c) { wrap("<span style=\"color:\(hex)\">", "</span>") }
                if let c = a[.backgroundColor] as? NSColor, let hex = chosenColor(c) { wrap("<mark style=\"background:\(hex)\">", "</mark>") }
                out += (open.isEmpty || text.trimmingCharacters(in: .whitespaces).isEmpty) ? text : tok(open) + text + tok(close)
            }
            return out
        }

        func line(_ p: NSAttributedString) -> String {
            let text = p.string
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return "" }
            if trimmed.hasPrefix("[[fold:"), trimmed.hasSuffix("]]") {
                return "### " + trimmed.dropFirst(7).dropLast(2).trimmingCharacters(in: .whitespaces)
            }
            if trimmed == "[[/fold]]" { return "" }

            let size = p.attribute(.font, at: (text as NSString).range(of: trimmed).location, effectiveRange: nil)
                .flatMap { ($0 as? NSFont)?.pointSize } ?? base
            let level = size >= base + 8 ? 1 : size >= base + 4 ? 2 : size >= base + 1.5 ? 3 : 0
            if level > 0, !trimmed.hasPrefix("#") {
                return String(repeating: "#", count: level) + " " + inline(p, heading: true)
            }
            let ps = p.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            let indent = Int(((ps?.firstLineHeadIndent ?? 0) / 20).rounded())
            let markers = [("• ", "- "), ("◦ ", "- "), ("▪ ", "- "), ("☐ ", "- [ ] "), ("☑ ", "- [x] ")]
            if let mk = markers.first(where: { text.hasPrefix($0.0) }) {
                let (glyph, md) = mk
                let rest = p.attributedSubstring(from: NSRange(location: (glyph as NSString).length,
                                                               length: p.length - (glyph as NSString).length))
                return String(repeating: "  ", count: indent) + md + inline(rest, heading: false)
            }
            if indent > 0, !trimmed.hasPrefix("-"), !trimmed.hasPrefix("|") { return "> " + inline(p, heading: false) }
            return inline(p, heading: false)
        }

        var lines: [String] = []
        var table: (NSTextTable, [Int: [Int: String]])?
        func flushTable() {
            guard let tb = table else { return }
            let (t, rows) = tb
            for r in rows.keys.sorted() {
                let cells = (0..<t.numberOfColumns).map { rows[r]?[$0] ?? " " }
                lines.append("| " + cells.joined(separator: " | ") + " |")
                if r == rows.keys.min() { lines.append("|" + String(repeating: "---|", count: t.numberOfColumns)) }
            }
            lines.append("")
            table = nil
        }
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { _, r, _, _ in
            let p = attr.attributedSubstring(from: r)
            let ps = p.length > 0 ? p.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle : nil
            if let cell = ps?.textBlocks.first as? NSTextTableBlock {
                if table?.0 !== cell.table { flushTable(); table = (cell.table, [:]) }
                let text = inline(p, heading: false).replacingOccurrences(of: "|", with: asMarkdown ? "\\|" : tok("|"))
                table?.1[cell.startingRow, default: [:]][cell.startingColumn] = text.isEmpty ? " " : text
                return
            }
            flushTable()
            lines.append(line(p))
        }
        flushTable()

        // `[[Note title]]` links mean nothing on paper; keep their text.
        let md = lines.joined(separator: "\n")
            .replacingOccurrences(of: #"\[\[([^\]\n]+)\]\]"#, with: "$1", options: .regularExpression)
        return (md, raw)
    }

    /// The most common font size, by characters — the body size, whatever the editor setting was.
    private static func bodySize(_ attr: NSAttributedString) -> CGFloat {
        var counts: [CGFloat: Int] = [:]
        attr.enumerateAttribute(.font, in: NSRange(location: 0, length: attr.length)) { v, r, _ in
            if let f = v as? NSFont { counts[f.pointSize, default: 0] += r.length }
        }
        return counts.max { $0.value < $1.value }?.key ?? 13
    }

    /// A color the writer picked, as hex for paper — or nil for the default text color.
    /// RTF stores colors resolved, so a note written in dark mode carries its "label color"
    /// as near-white: any near-black or near-white gray is the default, not a choice.
    static func chosenColor(_ c: NSColor) -> String? {
        var hex: String?
        (NSAppearance(named: .aqua) ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            guard let s = c.usingColorSpace(.sRGB) else { return }
            let r = s.redComponent, g = s.greenComponent, b = s.blueComponent
            let hi = max(r, g, b), lo = min(r, g, b)
            if hi - lo < 0.08, hi < 0.3 || lo > 0.75 { return }
            hex = String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
        }
        return hex
    }

    private static func image(_ att: NSTextAttachment) -> String? {
        guard let img = att.image ?? att.fileWrapper?.regularFileContents.flatMap(NSImage.init(data:)),
              let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let w = att.bounds.width > 0 ? att.bounds.width : img.size.width
        return "<img src=\"data:image/png;base64,\(png.base64EncodedString())\" style=\"width:\(Int(w))px\">"
    }
}

// MARK: - Preview window

/// Export and Print both open this: the pages as they will come out, the paper settings beside
/// them, and Save or Print from the same PDF — so what prints is what was previewed.
@MainActor
enum PDFExportWindow {
    private static var window: NSWindow?

    static func show(body: String, meta: NotePDF.Meta) {
        window?.close()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 880),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Export — " + (meta.title.isEmpty ? "Note" : meta.title)
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: PDFExportView(body: body, meta: meta) { window?.close() })
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    static var host: NSWindow? { window }
}

private struct PDFExportView: View {
    let body_: String
    let meta: NotePDF.Meta
    let close: () -> Void
    @State private var options = PDFOptions.saved
    @State private var doc: PDFDocument?
    @State private var failed = false

    init(body: String, meta: NotePDF.Meta, close: @escaping () -> Void) {
        self.body_ = body; self.meta = meta; self.close = close
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Paper", selection: $options.paper) {
                    ForEach(PDFOptions.Paper.allCases, id: \.self) { Text($0.rawValue) }
                }.fixedSize()
                Picker("Margins", selection: $options.margins) {
                    ForEach(PDFOptions.Margins.allCases, id: \.self) { Text($0.rawValue) }
                }.fixedSize()
                Picker("Text", selection: $options.textSize) {
                    ForEach(PDFOptions.TextSize.allCases, id: \.self) { Text($0.rawValue) }
                }.fixedSize()
                Toggle("Header", isOn: $options.header)
                Toggle("Page numbers", isOn: $options.pageNumbers)
                Spacer()
            }
            .padding(10)
            Divider()
            ZStack {
                if let doc { PDFPreview(doc: doc) }
                else if failed { Text("This note couldn't be laid out as a PDF.").foregroundStyle(.secondary) }
                else { ProgressView() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Text(doc.map { "\($0.pageCount) page\($0.pageCount == 1 ? "" : "s")" } ?? " ")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Print…", action: printPDF).disabled(doc == nil)
                Button("Save PDF…", action: save).disabled(doc == nil).keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .frame(minWidth: 620, minHeight: 500)
        .task(id: options) {
            options.save()
            failed = false
            let data = await NotePDF.render(body: body_, meta: meta, options: options)
            guard !Task.isCancelled else { return }
            doc = data.flatMap(PDFDocument.init(data:))
            failed = doc == nil
            if failed { Diagnostics.log(.data, .error, "note PDF layout failed") }
        }
    }

    private func save() {
        guard let doc, let win = PDFExportWindow.host else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (meta.title.isEmpty ? "Note" : meta.title) + ".pdf"
        panel.allowedContentTypes = [.pdf]
        panel.beginSheetModal(for: win) { resp in
            guard resp == .OK, let url = panel.url else { return }
            if doc.write(to: url) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                close()
            } else {
                Diagnostics.log(.data, .error, "note PDF write failed")
            }
        }
    }

    private func printPDF() {
        guard let doc, let win = PDFExportWindow.host else { return }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.paperSize = options.paperSize
        info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
        doc.printOperation(for: info, scalingMode: .pageScaleNone, autoRotate: false)?
            .runModal(for: win, delegate: nil, didRun: nil, contextInfo: nil)
    }
}

private struct PDFPreview: NSViewRepresentable {
    let doc: PDFDocument
    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.backgroundColor = .underPageBackgroundColor
        return v
    }
    func updateNSView(_ v: PDFView, context: Context) { if v.document !== doc { v.document = doc } }
}

// MARK: - Self-test (StudyBar --pdf-selftest)

/// Renders real notes and reads the PDF back: bounded, rendered (not source), on the chosen
/// paper, numbered, and never ending a page on a heading. SB_KEEP_PDF=1 keeps the files.
@MainActor
enum PDFSelfTest {
    static func run() async -> Int32 {
        var pass = 0, fail = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { Swift.print("  ok   \(name) \(detail)"); pass += 1 }
            else { Swift.print("  FAIL \(name) \(detail)"); fail += 1 }
        }
        let keep = ProcessInfo.processInfo.environment["SB_KEEP_PDF"] == "1"
        func keepFile(_ data: Data, _ name: String) {
            guard keep else { return }
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
            try? data.write(to: url); Swift.print("  kept \(url.path)")
        }

        // Shaped like a real AI-written note: Markdown, padded LaTeX, a pipe table, and many
        // headings — each one a chance to strand a heading at the foot of a page.
        var md = "## Introduction\n- **Key Concepts**: the time value of money.\n"
        md += "- **Present Value (PV)**: \\( PV = \\frac{FV}{(1 + i)^N} \\)\n\n"
        md += "| Year | Total Due | Payment |\n|------|----------|---------|\n| 0 | $1,000 | $0 |\n| 1 | $1,080 | $580 |\n\n"
        for s in 1...18 {
            md += "## Section \(s) heading\n"
            for l in 1...6 { md += "Line \(s).\(l): flux is $\\Phi_E = \\oint \\vec{E}\\cdot d\\vec{A}$ through the surface, again and again.\n" }
            md += "$$\\oint \\vec{E}\\cdot d\\vec{A} = \\frac{Q}{\\varepsilon_0}$$\n\n"
        }
        let plain = NSAttributedString(string: md, attributes: [.font: NSFont.systemFont(ofSize: 15)])
        let meta = NotePDF.Meta(title: "Week 3 — Gauss's Law", subtitle: "PHY2049 · Sep 29, 2026")
        var opts = PDFOptions(paper: .letter, margins: .normal, textSize: .normal, header: true, pageNumbers: true)

        let data = await NotePDF.render(body: NoteHTML.body(from: plain), meta: meta, options: opts)
        check("renders", data != nil)
        if let data, let doc = PDFDocument(data: data) {
            keepFile(data, "sb-pdf-selftest.pdf")
            check("bounded", data.count < 20_000_000 && doc.pageCount >= 2 && doc.pageCount <= 40,
                  "(\(doc.pageCount) pages, \(data.count / 1024) KB)")
            let text = doc.string ?? ""
            check("text and title present", text.contains("flux is") && text.contains("Gauss"))
            check("no LaTeX source left", !text.contains("\\oint") && !text.contains("\\frac") && !text.contains("$$"))
            check("Markdown rendered, not printed", !text.contains("##") && !text.contains("**"))
            check("table cells survive", text.contains("Total") && text.contains("$1,080") && text.contains("$580"))
            let size = doc.page(at: 0)?.bounds(for: .mediaBox).size ?? .zero
            check("Letter paper", abs(size.width - 612) < 1 && abs(size.height - 792) < 1, "(\(size))")
            check("page numbers", text.contains("Page 1 of \(doc.pageCount)") && text.contains("Page \(doc.pageCount) of \(doc.pageCount)"))
            var stranded: [Int] = []
            for i in 0..<doc.pageCount {
                let lines = (doc.page(at: i)?.string ?? "").components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("Page ") }
                if lines.last?.hasSuffix("heading") == true { stranded.append(i + 1) }
            }
            check("no heading ends a page", stranded.isEmpty, stranded.isEmpty ? "" : "(pages \(stranded))")
        } else { check("PDF is readable", false) }

        opts.paper = .a4; opts.textSize = .large; opts.pageNumbers = false
        if let data = await NotePDF.render(body: NoteHTML.body(from: plain), meta: meta, options: opts),
           let doc = PDFDocument(data: data) {
            let size = doc.page(at: 0)?.bounds(for: .mediaBox).size ?? .zero
            check("A4 paper", abs(size.width - 595.28) < 1, "(\(size))")
            check("page numbers off", !(doc.string ?? "").contains("Page 1 of"))
        } else { check("A4 renders", false) }

        // A note styled in the editor: its formatting is attributes, not Markdown.
        let styled = NSMutableAttributedString()
        func add(_ s: String, _ a: [NSAttributedString.Key: Any]) { styled.append(NSAttributedString(string: s, attributes: a)) }
        let body = NSFont.systemFont(ofSize: 15)
        add("Heading typed in the editor\n", [.font: NSFont.systemFont(ofSize: 20, weight: .bold)])
        add("Some ", [.font: body]); add("bold", [.font: NSFont.boldSystemFont(ofSize: 15)])
        add(" and ", [.font: body]); add("red", [.font: body, .foregroundColor: NSColor.systemRed])
        add(" and white-in-dark-mode text.\n", [.font: body, .foregroundColor: NSColor(white: 0.92, alpha: 1)])
        add("• a bullet with **stars** kept\n", [.font: body])
        let img = NSImage(size: NSSize(width: 40, height: 20)); img.lockFocus(); NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: 40, height: 20).fill(); img.unlockFocus()
        let att = NSTextAttachment(); att.image = img
        styled.append(NSAttributedString(attachment: att))
        let html = NoteHTML.body(from: styled)
        check("editor heading becomes a heading", html.contains("<h2>Heading typed in the editor</h2>"))
        check("bold kept", html.contains("<strong>bold</strong>"))
        check("chosen color kept", html.contains("color:#"))
        check("default color dropped", html.components(separatedBy: "color:#").count == 2)
        check("bullet is a list item", html.contains("<li>"))
        check("image kept", html.contains("<img src=\"data:image/png;base64,"))

        Swift.print(fail == 0 ? "PDF SELFTEST: ALL PASS (\(pass))" : "PDF SELFTEST: \(fail) FAILED")
        return fail == 0 ? 0 : 1
    }
}
