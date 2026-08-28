import SwiftUI
import WebKit

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
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
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
        if s.range(of: #"(?<!\\)\$[^$\n]+?\$"#, options: .regularExpression) != nil { return true }
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
        </style></head><body><div id="c">\(body)</div>
        <script>
          function post(){try{if(window.webkit&&webkit.messageHandlers.h){webkit.messageHandlers.h.postMessage(document.body.scrollHeight);}}catch(e){}}
          try{renderMathInElement(document.getElementById('c'),{delimiters:[
            {left:'$$',right:'$$',display:true},
            {left:'\\\\[',right:'\\\\]',display:true},
            {left:'$',right:'$',display:false},
            {left:'\\\\(',right:'\\\\)',display:false}],throwOnError:false});}catch(e){}
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
        for rawLine in md.components(separatedBy: "\n") {
            let t = rawLine.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { closeList(); continue }
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

    /// Protect math spans, HTML-escape the rest, apply inline Markdown, restore math.
    private static func inlineHTML(_ s: String) -> String {
        var work = s
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
