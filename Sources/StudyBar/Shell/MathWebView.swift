import SwiftUI
import WebKit
import PDFKit

/// (E1) System-wide LaTeX. `RichText` renders Markdown + math: if the string
/// contains `$…$` / `$$…$$` / `\(…\)` / `\[…\]` it renders through a KaTeX
/// WebView; otherwise it uses the fast native `MarkdownText`. KaTeX (CSS/JS +
/// woff2 fonts) is bundled and inlined, so rendering is fully offline.
struct RichText: View {
    let text: String

    var body: some View {
        if MathMarkdown.hasMath(text) {
            // Native SwiftMath (matches the editor); SwiftMathContent falls back to the
            // bundled KaTeX web view only for expressions SwiftMath can't parse.
            SwiftMathContent(text: text)
        } else {
            MarkdownText(text: text)
        }
    }
}

// MARK: - Note preview with collapsible sections

/// Renders a note's plaintext with `[[fold: Title]] … [[/fold]]` blocks shown as
/// native expandable sections; everything else goes through `RichText`
/// (Markdown + LaTeX). Isolated here so MarkdownText/RichText stay untouched.
struct NotePreview: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(FoldParser.parse(text)) { seg in
                if seg.isFold {
                    FoldBlock(title: seg.title, content: seg.content)
                } else {
                    RichText(text: seg.content)
                }
            }
        }
    }
}

private struct FoldBlock: View {
    let title: String
    let content: String
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            RichText(text: content).padding(.leading, 6).padding(.top, 4)
        } label: {
            Label(title, systemImage: "chevron.right.circle.fill")
                .font(.callout.weight(.semibold)).foregroundStyle(.tint)
        }
        .padding(8)
        .background(.sbSurface, in: RoundedRectangle(cornerRadius: 8))
    }
}

enum FoldParser {
    struct Segment: Identifiable { let id = UUID(); let isFold: Bool; let title: String; let content: String }

    static func parse(_ text: String) -> [Segment] {
        var out: [Segment] = []
        var buffer: [String] = []
        func flushText() {
            let joined = buffer.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty { out.append(Segment(isFold: false, title: "", content: joined)) }
            buffer.removeAll()
        }
        var i = 0
        let lines = text.components(separatedBy: "\n")
        while i < lines.count {
            let line = lines[i]
            if let title = foldTitle(line) {
                flushText()
                var inner: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("[[/fold]]") {
                    inner.append(lines[i]); i += 1
                }
                out.append(Segment(isFold: true, title: title, content: inner.joined(separator: "\n")))
                i += 1   // skip the [[/fold]]
            } else {
                buffer.append(line); i += 1
            }
        }
        flushText()
        return out
    }

    private static func foldTitle(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("[[fold:"), t.hasSuffix("]]") else { return nil }
        let inner = t.dropFirst("[[fold:".count).dropLast(2)
        return inner.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - KaTeX assets (bundled, inlined once)

/// Builds a self-contained `<style>…</style><script>…</script>` prelude from the
/// bundled KaTeX resources, with woff2 fonts embedded as data URIs so nothing is
/// fetched from disk or network at render time. Computed once and cached.
enum KatexAssets {
    static let prelude: String = build()

    private static func build() -> String {
        guard let dir = Bundle.main.url(forResource: "katex", withExtension: nil),
              var css = try? String(contentsOf: dir.appendingPathComponent("katex.min.css"), encoding: .utf8)
        else { return "" }

        let fontsDir = dir.appendingPathComponent("fonts")
        if let files = try? FileManager.default.contentsOfDirectory(at: fontsDir, includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension == "woff2" {
                guard let data = try? Data(contentsOf: f) else { continue }
                let base = f.deletingPathExtension().lastPathComponent   // KaTeX_Main-Regular
                // Replace the whole woff2,woff,ttf src list with a single inlined woff2.
                let triple = "url(fonts/\(base).woff2) format(\"woff2\"),url(fonts/\(base).woff) format(\"woff\"),url(fonts/\(base).ttf) format(\"truetype\")"
                let inlined = "url(data:font/woff2;base64,\(data.base64EncodedString())) format(\"woff2\")"
                css = css.replacingOccurrences(of: triple, with: inlined)
            }
        }
        let js = (try? String(contentsOf: dir.appendingPathComponent("katex.min.js"), encoding: .utf8)) ?? ""
        let auto = (try? String(contentsOf: dir.appendingPathComponent("contrib/auto-render.min.js"), encoding: .utf8)) ?? ""
        return "<style>\(css)</style><script>\(js)</script><script>\(auto)</script>"
    }
}

// MARK: - WebView host (auto-sizes to content)

struct MathWebView: NSViewRepresentable {
    let html: String
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(context.coordinator, name: "h")
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")     // transparent over the popover
        if #available(macOS 12.0, *) { web.underPageBackgroundColor = .clear }
        web.loadHTMLString(html, baseURL: nil)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            web.loadHTMLString(html, baseURL: nil)
        }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: MathWebView
        var lastHTML: String
        init(_ p: MathWebView) { parent = p; lastHTML = p.html }

        func userContentController(_ ucc: WKUserContentController, didReceive msg: WKScriptMessage) {
            guard msg.name == "h", let h = (msg.body as? NSNumber)?.doubleValue else { return }
            let newH = CGFloat(h)
            DispatchQueue.main.async {
                if abs(self.parent.height - newH) > 1 { self.parent.height = newH }
            }
        }

        // Open tapped links in the browser; never navigate inside the popover WebView.
        func webView(_ web: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                NSWorkspace.shared.open(url); decisionHandler(.cancel); return
            }
            decisionHandler(.allow)
        }
    }
}

// MARK: - Markdown (+ math) → HTML

enum MathMarkdown {
    static func hasMath(_ s: String) -> Bool {
        if s.range(of: #"\$\$[\s\S]+?\$\$"#, options: .regularExpression) != nil { return true }
        if s.range(of: #"(?<![\\\d])\$\S[^$\n]*?\$(?!\d)"#, options: .regularExpression) != nil { return true }   // money-safe
        return s.contains("\\(") || s.contains("\\[")
    }

    static func html(_ md: String, dark: Bool) -> String {
        page(body: convert(md), dark: dark)
    }

    private static func page(body: String, dark: Bool) -> String {
        let fg = dark ? "#e6e6e8" : "#1d1d20"
        let codeBG = dark ? "#2a2a2e" : "#f1f1f4"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        \(KatexAssets.prelude)
        <style>
          html,body{margin:0;padding:0;background:transparent;}
          body{color:\(fg);font:13px -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;line-height:1.45;-webkit-text-size-adjust:100%;overflow:hidden;word-wrap:break-word;}
          p{margin:0 0 6px;} h1{font-size:1.5em;margin:.25em 0;} h2{font-size:1.25em;margin:.25em 0;} h3{font-size:1.08em;margin:.25em 0;}
          ul{margin:.2em 0;padding-left:1.3em;} li{margin:1px 0;}
          code{background:\(codeBG);padding:1px 4px;border-radius:4px;font-family:ui-monospace,Menlo,monospace;font-size:.92em;}
          blockquote{margin:.3em 0;padding-left:.6em;border-left:2px solid currentColor;opacity:.7;}
          a{color:#0a84ff;text-decoration:none;}
          .katex{font-size:1.05em;} .katex-display{margin:.4em 0;overflow-x:auto;overflow-y:hidden;}
          table{border-collapse:collapse;margin:.5em 0;font-size:.94em;display:block;overflow-x:auto;}
          th,td{border:1px solid currentColor;border-color:color-mix(in srgb,currentColor 25%,transparent);padding:3px 7px;text-align:left;}
          th{font-weight:600;background:color-mix(in srgb,currentColor 8%,transparent);}
        </style></head><body><div id="c">\(body)</div>
        <script>
          function post(){try{if(window.webkit&&webkit.messageHandlers.h){webkit.messageHandlers.h.postMessage(document.body.scrollHeight);}}catch(e){}}
          try{renderMathInElement(document.getElementById('c'),{delimiters:[
            {left:'$$',right:'$$',display:true},
            {left:'\\\\[',right:'\\\\]',display:true},
            {left:'$',right:'$',display:false},
            {left:'\\\\(',right:'\\\\)',display:false}],
            throwOnError:false,errorColor:'\(fg)80'});}catch(e){}
          post(); window.addEventListener('load',post);
          if(window.ResizeObserver){new ResizeObserver(post).observe(document.body);}
          if(document.fonts&&document.fonts.ready){document.fonts.ready.then(post);}
          setTimeout(post,60); setTimeout(post,300);
        </script></body></html>
        """
    }

    private static func convert(_ md: String) -> String {
        var html = ""
        var inList = false
        func closeList() { if inList { html += "</ul>"; inList = false } }
        let lines = md.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let rawLine = lines[i]
            i += 1
            let t = rawLine.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { closeList(); continue }
            // A pipe table: a row followed by a |---|---| rule. Models reach for these
            // constantly (amortization schedules, comparisons), and without this they came
            // out as a wall of pipes in the reading view and in print.
            if t.hasPrefix("|"), i < lines.count, isTableRule(lines[i]) {
                closeList()
                var rows = [cells(t)]
                var j = i + 1
                while j < lines.count {
                    let row = lines[j].trimmingCharacters(in: .whitespaces)
                    guard row.hasPrefix("|") else { break }
                    rows.append(cells(row)); j += 1
                }
                html += tableHTML(rows)
                i = j
                continue
            }
            if t.hasPrefix("### ") { closeList(); html += "<h3>\(inlineHTML(String(t.dropFirst(4))))</h3>"; continue }
            if t.hasPrefix("## ")  { closeList(); html += "<h2>\(inlineHTML(String(t.dropFirst(3))))</h2>"; continue }
            if t.hasPrefix("# ")   { closeList(); html += "<h1>\(inlineHTML(String(t.dropFirst(2))))</h1>"; continue }
            if t.hasPrefix("> ")   { closeList(); html += "<blockquote>\(inlineHTML(String(t.dropFirst(2))))</blockquote>"; continue }
            if t.lowercased().hasPrefix("- [x] ") {
                if !inList { html += "<ul>"; inList = true }
                html += "<li>☑︎ \(inlineHTML(String(t.dropFirst(6))))</li>"; continue
            }
            if t.hasPrefix("- [ ] ") || t.hasPrefix("- [] ") {
                if !inList { html += "<ul>"; inList = true }
                html += "<li>☐ \(inlineHTML(String(t.drop(while: { $0 != "]" }).dropFirst(2))))</li>"; continue
            }
            if t.hasPrefix("- ") || t.hasPrefix("* ") {
                if !inList { html += "<ul>"; inList = true }
                html += "<li>\(inlineHTML(String(t.dropFirst(2))))</li>"; continue
            }
            closeList(); html += "<p>\(inlineHTML(rawLine))</p>"
        }
        closeList()
        return html
    }

    /// `|---|:--:|` — the rule that turns the line above it into a header row.
    private static func isTableRule(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("|"), t.contains("-") else { return false }
        return t.allSatisfy { "|-: \t".contains($0) }
    }

    private static func cells(_ row: String) -> [String] {
        var parts = row.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        if parts.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { parts.removeFirst() }
        if parts.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { parts.removeLast() }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func tableHTML(_ rows: [[String]]) -> String {
        guard let header = rows.first else { return "" }
        var html = "<table><thead><tr>"
        html += header.map { "<th>\(inlineHTML($0))</th>" }.joined()
        html += "</tr></thead><tbody>"
        for row in rows.dropFirst() {
            html += "<tr>" + row.map { "<td>\(inlineHTML($0))</td>" }.joined() + "</tr>"
        }
        return html + "</tbody></table>"
    }

    /// The note laid out for paper: the same Markdown conversion the reading view renders,
    /// imported through the HTML reader, with `$…$` spans drawn as math attachments. Export
    /// and Print used the plaintext mirror, so a PDF of an AI-written note was a page of
    /// `##` and `**` and raw LaTeX — the source, not the note.
    @MainActor
    static func printable(_ md: String) -> NSAttributedString? {
        let body = convert(MathSupport.normalized(md))
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><style>
          body{font:11pt -apple-system,"SF Pro Text",system-ui,sans-serif;line-height:1.45;color:#000;}
          h1{font-size:17pt;margin:0 0 8pt;} h2{font-size:14pt;margin:12pt 0 4pt;} h3{font-size:12pt;margin:10pt 0 3pt;}
          p{margin:0 0 5pt;} ul{margin:2pt 0 5pt 0;} li{margin:1pt 0;}
          table{border-collapse:collapse;margin:6pt 0;width:100%;}
          th,td{border:1px solid #999;padding:3pt 6pt;font-size:10pt;text-align:left;}
          th{background:#f0f0f0;font-weight:600;}
          code{font-family:ui-monospace,Menlo,monospace;font-size:10pt;}
          blockquote{margin:4pt 0 4pt 10pt;color:#444;}
        </style></head><body>\(body)</body></html>
        """
        guard let data = html.data(using: .utf8),
              let attr = try? NSMutableAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html,
                          .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil)
        else { return nil }
        return attr.installingMath(defaultColor: .black)
    }

    /// Balance a line's `\(…\)` so a common typo (a bare `)` meant as `\)`, or a stray extra
    /// `\)`) still renders instead of showing as raw error text.
    private static func repairDelims(_ line: String) -> String {
        let opens = line.components(separatedBy: "\\(").count - 1
        let closes = line.components(separatedBy: "\\)").count - 1
        guard opens != closes else { return line }
        var out = line
        if opens > closes {
            // Dangling open: a trailing bare `)` was almost certainly meant to be `\)`.
            if out.hasSuffix(")") && !out.hasSuffix("\\)") { out = String(out.dropLast()) + "\\)" }
            else { out += String(repeating: "\\)", count: opens - closes) }
        } else {
            var extra = closes - opens                       // strip stray trailing closers
            while extra > 0, out.hasSuffix("\\)") { out = String(out.dropLast(2)); extra -= 1 }
        }
        return out
    }

    /// Protect math spans, HTML-escape the rest, apply inline Markdown, restore math.
    private static func inlineHTML(_ s: String) -> String {
        var work = repairDelims(s)
        var math: [String] = []
        let mathPatterns = [#"\$\$[\s\S]+?\$\$"#, #"\\\[[\s\S]+?\\\]"#,
                            #"(?<!\\)\$[^$\n]+?\$"#, #"\\\([\s\S]+?\\\)"#]
        for p in mathPatterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            while let m = re.firstMatch(in: work, range: NSRange(work.startIndex..., in: work)),
                  let r = Range(m.range, in: work) {
                let token = "\u{E000}\(math.count)\u{E001}"
                math.append(String(work[r]))
                work.replaceSubrange(r, with: token)
            }
        }
        work = escape(work)
        work = rx(work, #"\*\*(.+?)\*\*"#, "<strong>$1</strong>")
        work = rx(work, #"(?<!\*)\*(?!\s)(.+?)(?<!\s)\*(?!\*)"#, "<em>$1</em>")
        work = rx(work, "`(.+?)`", "<code>$1</code>")
        work = rx(work, #"\[(.+?)\]\((https?://[^)\s]+)\)"#, "<a href=\"$2\">$1</a>")
        for (i, m) in math.enumerated() {
            work = work.replacingOccurrences(of: "\u{E000}\(i)\u{E001}", with: escape(m))
        }
        return work
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
    private static func rx(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}

// MARK: - A note as a printable document (PDF / print)

/// Export as Rich Text carries LaTeX as source and Markdown carries no formatting at all, so
/// neither is what you hand a classmate. This lays the note out for paper with its math
/// *rendered* — `installingMath()` turns every `$…$` span into the same drawn attachment the
/// editor shows — and prints it or writes a paginated PDF.
///
/// It deliberately does NOT print the KaTeX web view. WebKit's print pagination did not
/// terminate on a long note: it produced a 2.7 GB PDF and was still growing when it was
/// killed. The text system paginates the same way Print in the editor already does.
@MainActor
enum NoteDocument {

    static func writePDF(title: String, attributed: NSAttributedString, to url: URL) -> Bool {
        let info = printInfo()
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let op = NSPrintOperation(view: page(title: title, attributed: attributed, info: info), printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        return op.run()
    }

    static func print(title: String, attributed: NSAttributedString) {
        let info = printInfo()
        let op = NSPrintOperation(view: page(title: title, attributed: attributed, info: info), printInfo: info)
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.run()
    }

    private static func printInfo() -> NSPrintInfo {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.topMargin = 54; info.bottomMargin = 54; info.leftMargin = 54; info.rightMargin = 54
        info.isHorizontallyCentered = false; info.isVerticallyCentered = false
        return info
    }

    /// Math attachments carry an image that redraws its glyphs when asked, rather than a
    /// bitmap — printed equations came out mirrored while the same attachment is upright in
    /// the editor. (Measured, not guessed: a plain bitmap attachment through this same print
    /// path lands upright, so the print context isn't flipping anything.) Rasterizing each
    /// math image once, at print resolution, locks in what it looks like on screen.
    static func rasterizingMath(_ s: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: s)
        m.enumerateAttribute(.attachment, in: NSRange(location: 0, length: m.length)) { val, range, _ in
            guard let att = val as? NSTextAttachment, let img = att.image,
                  img.size.width > 0, img.size.height > 0 else { return }
            let scale: CGFloat = 3                      // print resolution, not screen
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(ceil(img.size.width * scale)),
                pixelsHigh: Int(ceil(img.size.height * scale)),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            else { return }
            rep.size = img.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            img.draw(in: NSRect(origin: .zero, size: img.size))
            NSGraphicsContext.restoreGraphicsState()

            let flat = NSImage(size: img.size)
            flat.addRepresentation(rep)
            let copy = NSTextAttachment()
            copy.image = flat
            copy.bounds = att.bounds
            m.addAttribute(.attachment, value: copy, range: range)
        }
        return m
    }

    /// Is this note's text Markdown source (AI-written, pasted) rather than text the user
    /// styled in the editor? Those two want opposite treatment on paper: the first has to be
    /// rendered, the second already carries its formatting (and its images) in the RTFD.
    private static func isMarkdown(_ s: String) -> Bool {
        s.range(of: #"(?m)^\s{0,3}#{1,3}\s"#, options: .regularExpression) != nil
            || s.range(of: #"(?m)^\s{0,3}[-*]\s"#, options: .regularExpression) != nil
            || s.range(of: #"(?m)^\s*\|.*\|"#, options: .regularExpression) != nil
            || s.contains("**")
    }

    /// The note as a text view sized to the printable column.
    private static func page(title: String, attributed: NSAttributedString, info: NSPrintInfo) -> NSTextView {
        let width = max(200, info.paperSize.width - info.leftMargin - info.rightMargin)
        let doc = NSMutableAttributedString()
        if !title.trimmingCharacters(in: .whitespaces).isEmpty {
            doc.append(NSAttributedString(string: title + "\n\n",
                                          attributes: [.font: NSFont.boldSystemFont(ofSize: 20),
                                                       .foregroundColor: NSColor.black]))
        }
        let plain = attributed.string
        if isMarkdown(plain), let rendered = MathMarkdown.printable(plain) {
            doc.append(rendered)
        } else {
            // .black, not .labelColor: on paper a dark-mode label color is white on white.
            doc.append(attributed.installingMath(defaultColor: .black))
        }
        let printable = rasterizingMath(doc)

        // An explicit TextKit 1 stack, for the same reason the editor builds one: text tables
        // (what a Markdown table imports as) and attachment cells are TextKit 1 only. A
        // default NSTextView is TextKit 2, which flattened every table cell onto its own
        // line — that was the difference between Export as PDF and Print, which reached the
        // print pipeline through different stacks.
        let storage = NSTextStorage(attributedString: printable)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = false
        layout.addTextContainer(container)

        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10), textContainer: container)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainerInset = .zero
        tv.backgroundColor = .white
        tv.drawsBackground = true
        layout.ensureLayout(for: container)
        tv.frame.size.height = max(10, ceil(layout.usedRect(for: container).height))
        return tv
    }
}

// MARK: - PDF export self-test (StudyBar --pdf-selftest)

/// Guards the export against the failure that WebKit printing produced: a PDF that never
/// stops growing. Asserts a bounded page count and file size for a long note with math.
@MainActor
enum PDFSelfTest {
    static func run() -> Int32 {
        var pass = 0, fail = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { Swift.print("  ok   \(name) \(detail)"); pass += 1 }
            else { Swift.print("  FAIL \(name) \(detail)"); fail += 1 }
        }

        // Shaped like a real AI-written note: Markdown source, LaTeX padded against its
        // delimiters, and a pipe table — the three things that came out as raw source.
        var body = "# Module Three: Present Value\n\n## Introduction\n"
        body += "- **Key Concepts**: the time value of money.\n"
        body += "- **Present Value (PV)**: \\( PV = \\frac{FV}{(1 + i)^N} \\)\n\n"
        body += "| Year | Total Due | Payment |\n|------|----------|---------|\n"
        body += "| 0 | $1,000 | $0 |\n| 1 | $1,080 | $580 |\n\n"
        for i in 1...100 { body += "Line \(i): flux is $\\Phi_E = \\oint \\vec{E}\\cdot d\\vec{A}$ through the surface.\n" }
        let attr = NSAttributedString(string: body, attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sb-pdf-selftest.pdf")
        try? FileManager.default.removeItem(at: url)

        let ok = NoteDocument.writePDF(title: "Weeks 3 — Gauss's Law", attributed: attr, to: url)
        check("writePDF returns true", ok)
        let bytes = (try? Data(contentsOf: url).count) ?? 0
        check("file is written", bytes > 1_000, "(\(bytes) bytes)")
        check("file is bounded", bytes < 20_000_000, "(\(bytes) bytes < 20MB)")
        if let doc = PDFDocument(url: url) {
            check("pages are bounded", doc.pageCount >= 1 && doc.pageCount <= 40, "(\(doc.pageCount) pages)")
            let text = doc.string ?? ""
            check("text is present", text.contains("flux is"))
            check("title is present", text.contains("Gauss"))
            check("no LaTeX source left", !text.contains("\\oint") && !text.contains("\\frac") && !text.contains("$$"))
            check("Markdown is rendered, not printed", !text.contains("##") && !text.contains("**"))
            check("table cells survive", text.contains("Total") && text.contains("$1,080") && text.contains("$580"))
        } else {
            check("PDF is readable", false)
        }
        // The equations printed mirrored until every math attachment was rasterized: the
        // image SwiftMath hands back redraws its glyphs on demand, and that redraw lands in
        // the print context's coordinate space. Bitmap-backed means "looks like it does on
        // screen", so assert it rather than the pixels.
        let mathy = NSAttributedString(string: "flux is $\\oint E$ here").installingMath(defaultColor: .black)
        let printable = NoteDocument.rasterizingMath(mathy)
        var attachments = 0, bitmaps = 0
        printable.enumerateAttribute(.attachment, in: NSRange(location: 0, length: printable.length)) { v, _, _ in
            guard let a = v as? NSTextAttachment, let img = a.image else { return }
            attachments += 1
            if img.representations.allSatisfy({ $0 is NSBitmapImageRep }) { bitmaps += 1 }
        }
        check("math is rasterized for print", attachments > 0 && attachments == bitmaps,
              "(\(bitmaps)/\(attachments) attachments)")

        // SB_KEEP_PDF=1 leaves the file behind for eyeballing (orientation, tables).
        if ProcessInfo.processInfo.environment["SB_KEEP_PDF"] == "1" { Swift.print("  kept \(url.path)") }
        else { try? FileManager.default.removeItem(at: url) }

        Swift.print(fail == 0 ? "PDF SELFTEST: ALL PASS (\(pass))" : "PDF SELFTEST: \(fail) FAILED")
        return fail == 0 ? 0 : 1
    }
}
