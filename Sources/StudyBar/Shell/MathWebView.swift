import SwiftUI
import WebKit

/// (E1) System-wide LaTeX. `RichText` renders Markdown + math: if the string
/// contains `$…$` / `$$…$$` / `\(…\)` / `\[…\]` it renders through a KaTeX
/// WebView; otherwise it uses the fast native `MarkdownText`. KaTeX (CSS/JS +
/// woff2 fonts) is bundled and inlined, so rendering is fully offline.
struct RichText: View {
    let text: String

    var body: some View {
        if MathMarkdown.hasMath(text) || MathMarkdown.hasTable(text) {
            // Native SwiftMath (matches the editor); SwiftMathContent falls back to the
            // bundled KaTeX web view for expressions SwiftMath can't parse — and for
            // tables, which only the web view lays out.
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
    /// A lecture note's board photos, shown where their `📷 Board photo N` lines are.
    var photos: [LectureTimeline.Photo] = []
    var note: Note? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(FoldParser.parse(text)) { seg in
                if seg.isFold {
                    FoldBlock(title: seg.title, content: seg.content)
                } else if photos.isEmpty {
                    RichText(text: seg.content)
                } else {
                    ForEach(Array(BoardPhotos.split(seg.content).enumerated()), id: \.offset) { _, piece in
                        switch piece {
                        case .text(let t): RichText(text: t)
                        case .photo(let n, let caption):
                            BoardPhotoView(number: n, photo: photos.indices.contains(n - 1) ? photos[n - 1] : nil, caption: caption, note: note)
                        }
                    }
                }
            }
        }
    }
}

/// A photo of the board, in the note where it was taken: click its time to hear the lecture
/// from then; right-click to open it, copy it, or cover its parts as image cards.
private struct BoardPhotoView: View {
    @EnvironmentObject var state: AppState
    let number: Int
    let photo: LectureTimeline.Photo?
    let caption: String
    let note: Note?

    var body: some View {
        if let photo, let img = BoardPhotos.image(photo) {
            VStack(alignment: .leading, spacing: 4) {
                Image(nsImage: img).resizable().scaledToFit()
                    .frame(maxWidth: 560, maxHeight: 340, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
                    .onTapGesture(count: 2) { NSWorkspace.shared.open(BoardPhotos.url(photo)) }
                    .accessibilityLabel("Board photo \(number)\(caption.isEmpty ? "" : ", \(caption)")")
                HStack(spacing: 8) {
                    if let note, note.audioPath != nil {
                        Button { state.pendingSeek = .init(note: note.id, at: photo.t) } label: {
                            Label("Board photo \(number) · \(Duration.seconds(photo.t).formatted(.time(pattern: .minuteSecond)))", systemImage: "play.circle")
                        }
                        .buttonStyle(.borderless).foregroundStyle(.tint).help("Play the lecture from when this was taken")
                    } else {
                        Label("Board photo \(number)", systemImage: "camera")
                    }
                    if !caption.isEmpty { Text(caption).foregroundStyle(.secondary) }
                }
                .font(.caption)
            }
            .padding(.vertical, 4)
            .contextMenu {
                Button("Open in Preview") { NSWorkspace.shared.open(BoardPhotos.url(photo)) }
                Button("Make Image Cards…") {
                    guard let cg = ImageCards.cgImage(img) else { return }
                    state.pendingImageCards = ImageCardsRequest(image: cg, title: caption.isEmpty ? "Board photo \(number)" : caption, course: note?.courseID)
                    AppActions.open(module: "flashcards")
                }
                Button("Copy Image") { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([img]) }
            }
        } else {
            // Recordings stay on the Mac that made them, and their photos with them.
            Label("Board photo \(number) — it's on the Mac that recorded this lecture", systemImage: "camera")
                .font(.caption).foregroundStyle(.secondary)
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

/// A web view that does not keep the scroll wheel to itself.
///
/// This view is laid out at its full measured content height inside a SwiftUI ScrollView, so it
/// has nothing of its own to scroll — but WKWebView still consumes every wheel event it is sent,
/// and the enclosing scroll view never hears about them. On a note that falls back to KaTeX (any
/// note with a table) the reading view became one tall web view and the whole note stopped
/// scrolling, while the same note scrolled fine in the editor. Forwarding to the next responder
/// hands the wheel back to the SwiftUI ScrollView's NSScrollView.
private final class PassThroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

/// The KaTeX reading surface.
///
/// The page used to be rebuilt and reloaded whole for every note and every re-render, and the
/// page includes the entire KaTeX bundle inlined — 631 KB of CSS, JS and base64 woff2. Measured
/// on this store (`StudyBar --perf-notes`): 15–28 ms to build the string, ~650 KB handed to
/// WebKit, and a full parse plus re-execution of 275 KB of JavaScript on every load. That is the
/// stall behind "lag when opening notes".
///
/// Now the shell — prelude, styles, an empty `#c` — is loaded once per web view, and a note is
/// pushed into it as a few KB of body HTML through `setBody`. Switching notes re-renders the
/// math; it no longer re-parses the engine.
struct MathWebView: NSViewRepresentable {
    /// Body HTML only (see `MathMarkdown.bodyHTML`), not a whole page.
    let body: String
    var dark: Bool
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(context.coordinator, name: "h")
        let web = PassThroughWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")     // transparent over the popover
        if #available(macOS 12.0, *) { web.underPageBackgroundColor = .clear }
        context.coordinator.pending = body
        context.coordinator.loadedDark = dark
        web.loadHTMLString(MathMarkdown.shell(dark: dark), baseURL: nil)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let c = context.coordinator
        // Only the appearance forces a reload — everything else is a body swap.
        if c.loadedDark != dark {
            c.loadedDark = dark
            c.ready = false
            c.pending = body
            c.lastBody = nil
            web.loadHTMLString(MathMarkdown.shell(dark: dark), baseURL: nil)
            return
        }
        guard c.lastBody != body else { return }
        c.lastBody = body
        if c.ready { c.push(body, into: web) } else { c.pending = body }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: MathWebView
        /// Body waiting for the shell to finish loading.
        var pending: String?
        var lastBody: String?
        var ready = false
        var loadedDark = false
        init(_ p: MathWebView) { parent = p }

        func push(_ body: String, into web: WKWebView) {
            let json = (try? JSONSerialization.data(withJSONObject: [body]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
            web.evaluateJavaScript("setBody(\(json)[0])")
        }

        func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            if let pending { push(pending, into: web); self.pending = nil }
        }

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
    /// Detection runs on the *normalized* text, deliberately: the renderers all normalize
    /// first, so anything this counts as math must be what they will then match. Answering
    /// on the raw string is what let a model's padded `$ \Phi_E = 0 $` spans route to a
    /// renderer that found no math in them and laid them out as prose.
    static func hasMath(_ raw: String) -> Bool {
        let s = MathSupport.normalized(raw)
        if s.range(of: #"\$\$[\s\S]+?\$\$"#, options: .regularExpression) != nil { return true }
        if s.range(of: #"(?<![\\\d])\$\S[^$\n]*?\$(?!\d)"#, options: .regularExpression) != nil { return true }   // money-safe
        return s.contains("\\(") || s.contains("\\[")
    }

    /// A Markdown table: a `|`-delimited row directly above a `|---|` rule. Only the web
    /// view lays these out — the native row builder renders line by line, which is why a
    /// table in a note showed as its pipes.
    static func hasTable(_ s: String) -> Bool {
        let lines = s.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() where line.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
            if i + 1 < lines.count, isTableRule(lines[i + 1]) { return true }
        }
        return false
    }

    /// Same pipeline as `printable`, deliberately: the reading view used to call `convert`
    /// with the raw note while print normalized and joined first, so the two disagreed about
    /// what a note looked like. Normalizing also folds `\[…\]` into `$$…$$`, which is what
    /// lets `joinDisplayBlocks` repair a model's multi-line display math in either delimiter.
    static func html(_ md: String, dark: Bool) -> String {
        page(body: bodyHTML(md), dark: dark)
    }

    /// Just the note as HTML — no page, no KaTeX bundle. This is what gets pushed into an
    /// already-loaded shell, and it is a few KB rather than 650.
    ///
    /// Memoized because the reading view calls it from `body`: a note that re-rendered for an
    /// unrelated reason (a recording meter ticking, a selection change) paid the full markdown
    /// conversion again every time.
    static func bodyHTML(_ md: String) -> String {
        if let hit = bodyCache.object(forKey: md as NSString) { return hit as String }
        let out = convert(joinDisplayBlocks(MathSupport.normalized(md)))
        bodyCache.setObject(out as NSString, forKey: md as NSString)
        return out
    }
    private static let bodyCache: NSCache<NSString, NSString> = {
        let c = NSCache<NSString, NSString>()
        c.countLimit = 40                 // a term of notes, not the whole store
        return c
    }()

    /// The page with an empty body: loaded once per web view, then filled through `setBody`.
    static func shell(dark: Bool) -> String { page(body: "", dark: dark) }

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
          ul ul{margin:0;list-style:circle;} ul ul ul{list-style:square;}
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
          function typeset(){
            try{renderMathInElement(document.getElementById('c'),{delimiters:[
              {left:'$$',right:'$$',display:true},
              {left:'\\\\[',right:'\\\\]',display:true},
              {left:'$',right:'$',display:false},
              {left:'\\\\(',right:'\\\\)',display:false}],
              throwOnError:false,errorColor:'\(fg)80'});}catch(e){}
          }
          // Swapping a note is a body swap plus a typeset — the engine above is parsed once.
          function setBody(html){
            var c=document.getElementById('c');
            c.innerHTML=html;
            typeset();
            post();
            if(document.fonts&&document.fonts.ready){document.fonts.ready.then(post);}
            setTimeout(post,60); setTimeout(post,300);
          }
          typeset();
          post(); window.addEventListener('load',post);
          if(window.ResizeObserver){new ResizeObserver(post).observe(document.body);}
          if(document.fonts&&document.fonts.ready){document.fonts.ready.then(post);}
          setTimeout(post,60); setTimeout(post,300);
        </script></body></html>
        """
    }

    /// Put a display-math block that was written across several lines back onto one line.
    ///
    /// `convert` is line-based, so
    ///
    ///     $$Q_{\text{enclosed}}
    ///
    ///     = \sigma_1 A+\sigma_2 A$$
    ///
    /// became three separate `<p>` elements, and KaTeX matches a delimiter pair only within a
    /// single element — so the raw LaTeX showed through while single-line `$$…$$` rendered
    /// fine. The native renderer never had this bug (`MathSupport.displayRE` sets
    /// `.dotMatchesLineSeparators`), which is why it only ever appeared on notes that fall
    /// back to KaTeX: the ones with tables. Models write display math this way constantly.
    ///
    /// A `$$` that never closes is left exactly as it was, so a stray delimiter can't swallow
    /// the rest of the note.
    static func joinDisplayBlocks(_ s: String) -> String {
        guard s.contains("$$") else { return s }
        let lines = s.components(separatedBy: "\n")
        var out: [String] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            // An odd number of delimiters opens a block that this line doesn't close.
            if line.components(separatedBy: "$$").count % 2 == 0 {
                var block = [line]
                var j = i + 1
                var closed = false
                while j < lines.count {
                    block.append(lines[j])
                    if lines[j].contains("$$") { closed = true; break }
                    j += 1
                }
                if closed {
                    // Blank lines inside the block collapse; a space keeps `\\` row breaks and
                    // adjacent tokens from running together.
                    out.append(block.map { $0.trimmingCharacters(in: .whitespaces) }
                                    .filter { !$0.isEmpty }
                                    .joined(separator: " "))
                    i = j + 1
                    continue
                }
            }
            out.append(line)
            i += 1
        }
        return out.joined(separator: "\n")
    }

    private static func convert(_ md: String) -> String {
        var html = ""
        // A stack, not a bool: a sub-list belongs *inside* the `<li>` above it, so the parent's
        // item stays open until the nested list closes. One entry per open `<ul>`, saying
        // whether that list's current `<li>` is still unclosed. `NoteFormat.indentLevel` is the
        // shared depth rule — before this, every line was trimmed before `- ` was matched, so a
        // model's indentation meant nothing and sub-points rendered as siblings.
        /// One entry per open `<ul>`: the indent level that opened it, and whether its current
        /// `<li>` is still unclosed. The level is stored rather than inferred from the stack
        /// depth — two bullets indented two spaces with nothing above them are siblings, and
        /// depth alone would make the second one a child of the first.
        var lists: [(level: Int, itemOpen: Bool)] = []
        func closeList() {
            // Innermost first: close its open item, close the list; the item that contained it
            // is the next entry down, closed on the following pass.
            while let last = lists.popLast() {
                if last.itemOpen { html += "</li>" }
                html += "</ul>"
            }
        }
        /// Emit one list item at `level`, opening or closing lists to get there.
        func item(_ level: Int, _ content: String) {
            while let last = lists.last, last.level > level {
                if last.itemOpen { html += "</li>" }
                html += "</ul>"
                lists.removeLast()
            }
            if let last = lists.last, last.level == level {
                if last.itemOpen { html += "</li>" }          // sibling
            } else {
                html += "<ul>"                                // deeper, or the first list
                lists.append((level, false))
            }
            html += "<li>\(content)"
            lists[lists.count - 1].itemOpen = true
        }
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
                item(NoteFormat.indentLevel(rawLine), "☑︎ \(inlineHTML(String(t.dropFirst(6))))"); continue
            }
            if t.hasPrefix("- [ ] ") || t.hasPrefix("- [] ") {
                item(NoteFormat.indentLevel(rawLine),
                     "☐ \(inlineHTML(String(t.drop(while: { $0 != "]" }).dropFirst(2))))"); continue
            }
            if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("• ") {
                item(NoteFormat.indentLevel(rawLine), inlineHTML(String(t.dropFirst(2)))); continue
            }
            closeList(); html += "<p>\(inlineHTML(rawLine))</p>"
        }
        closeList()
        return html
    }

    /// `|---|:--:|` — the rule that turns the line above it into a header row.
    static func isTableRule(_ line: String) -> Bool {
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

    /// Markdown plus HTML fragments the caller wants passed through untouched — the styled-note
    /// path (`NoteHTML`) carries color, highlight and images this way. Each fragment sits in the
    /// Markdown as a private-use token that the converter escapes as nothing and splits on nothing.
    static func bodyHTML(_ md: String, raw: [String]) -> String {
        var html = convert(joinDisplayBlocks(MathSupport.normalized(md)))
        for (i, r) in raw.enumerated().reversed() {
            html = html.replacingOccurrences(of: "\u{E010}\(i)\u{E011}", with: r)
        }
        return html
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
