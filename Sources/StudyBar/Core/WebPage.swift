import WebKit

/// A web page read the way Safari's Reader reads it — the article, without the menus, ads and
/// footers — and kept as an .html file, which the Converter turns into a PDF, Markdown or Word
/// like any document, or into a note.
@MainActor
enum WebPage {
    /// Where fetched pages wait to be converted. What they become goes to Downloads instead
    /// (`Converter.destination`): "next to the original" would be in here.
    nonisolated static var dir: URL {
        let base = ProcessInfo.processInfo.environment["STUDYBAR_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("StudyBar")
        let d = base.appendingPathComponent("Web pages", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// The page's article, or failing that the block holding the most paragraph text, stripped
    /// of everything that isn't reading — with absolute links and pictures, so it reads offline.
    private static let reader = #"""
    (() => {
      const len = e => (e && e.innerText || '').length;
      let root = document.querySelector('article') || document.querySelector('main') || document.querySelector('[role=main]');
      if (len(root) < 400) {
        let best = null, most = 0;
        document.querySelectorAll('div, section').forEach(d => {
          let n = 0; d.querySelectorAll(':scope > p').forEach(p => n += len(p));
          if (n > most) { most = n; best = d; }
        });
        root = most > 400 ? best : document.body;
      }
      const c = root.cloneNode(true);
      // Equations as their TeX, which notes render: MathML's alttext (Wikipedia), KaTeX's annotation.
      c.querySelectorAll('math').forEach(m => {
        const a = m.querySelector('annotation[encoding="application/x-tex"]');
        const tex = m.getAttribute('alttext') || (a && a.textContent);
        if (!tex) return;
        const shown = m.closest('.mwe-math-element, .katex-display, .katex') || m;
        shown.replaceWith(document.createTextNode(m.getAttribute('display') === 'block' ? '$$' + tex + '$$' : '$' + tex + '$'));
      });
      c.querySelectorAll('script,style,noscript,nav,header,aside,footer,form,iframe,button,input,select,svg,canvas,video,audio,.mw-editsection,' +
        '[aria-hidden="true"],[role="navigation"],[role="complementary"],[role="banner"],[role="contentinfo"]').forEach(e => e.remove());
      c.querySelectorAll('img').forEach(i => {
        const s = i.currentSrc || i.src; if (s) i.setAttribute('src', s);
        ['srcset', 'sizes', 'loading', 'width', 'height'].forEach(a => i.removeAttribute(a));
      });
      c.querySelectorAll('a[href]').forEach(a => a.setAttribute('href', a.href));
      c.querySelectorAll('*').forEach(e => { e.removeAttribute('style'); e.removeAttribute('class'); });
      const og = document.querySelector('meta[property="og:title"]');
      return JSON.stringify({ title: ((og && og.content) || document.title || '').trim(), html: c.innerHTML, chars: len(c) });
    })()
    """#

    /// The page as a clean .html file in `dir`, named for its title.
    static func fetch(_ url: URL) async throws -> URL {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 900))
        let loader = NotePDF.Loader()
        web.navigationDelegate = loader
        if url.isFileURL { web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
        else { web.load(URLRequest(url: url, timeoutInterval: 30)) }
        guard await loader.finished() else { throw Converter.Failure.app("Couldn't open that page — check the address and your connection.") }
        try? await Task.sleep(for: .milliseconds(800))   // pages that draw their text in after loading
        guard let json = try? await web.evaluateJavaScript(reader) as? String,
              let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let article = obj["html"] as? String, (obj["chars"] as? Int ?? 0) > 200 else { throw Converter.Failure.nothingFound }
        let title = (obj["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url.host() ?? "Web page"
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "\"", with: "&quot;") }
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>\(esc(title))</title></head><body>
        <h1>\(esc(title))</h1><p><a href="\(esc(url.absoluteString))">\(esc(url.isFileURL ? url.lastPathComponent : url.host() ?? url.absoluteString))</a></p>
        \(await inlined(article))
        </body></html>
        """
        let name = String(title.replacingOccurrences(of: #"[/:\\]"#, with: "-", options: .regularExpression).prefix(100))
        let out = Converter.destination(for: dir.appendingPathComponent(name).appendingPathExtension("html"), ext: "html", in: dir)
        try html.write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    /// The pictures fetched into the file as data, so it reads — and converts — without the site:
    /// a PDF made from it showed a "?" where each figure was.
    private static func inlined(_ html: String) async -> String {
        let srcs = Set(html.matches(of: /src="(https?:\/\/[^"]+)"/).map { String($0.output.1) }).prefix(40)
        let found = await withTaskGroup(of: (String, String)?.self) { g in
            for src in srcs {
                g.addTask {
                    guard let u = URL(string: src.replacingOccurrences(of: "&amp;", with: "&")),
                          let (data, resp) = try? await URLSession.shared.data(from: u), data.count < 4_000_000,
                          let type = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first,
                          type.hasPrefix("image/") else { return nil }
                    return (src, "data:\(type);base64,\(data.base64EncodedString())")
                }
            }
            return await g.reduce(into: [(String, String)]()) { if let p = $1 { $0.append(p) } }
        }
        return found.reduce(html) { $0.replacingOccurrences(of: "src=\"\($1.0)\"", with: "src=\"\($1.1)\"") }
    }

    /// A web address in what was typed or pasted — with or without its https://.
    static func address(_ s: String) -> URL? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(" ") else { return nil }
        let u = URL(string: t.contains("://") ? t : "https://" + t)
        return u?.host()?.contains(".") == true && ["http", "https"].contains(u?.scheme ?? "") ? u : nil
    }
}
