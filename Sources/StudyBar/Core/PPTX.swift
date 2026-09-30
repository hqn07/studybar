import AppKit

/// A PowerPoint file written by hand: the smallest Office Open XML package PowerPoint, Keynote
/// and Quick Look all open — one master, one blank layout, a theme, and the slides. A slide is
/// either a picture filling it (a PDF page) or a title and bullets (a note outlined).
///
/// No dependency: the XML is text, and the zip is `/usr/bin/zip`, which ships with macOS.
enum PPTX {
    enum Slide {
        case image(Data, ext: String, size: CGSize)       // png/jpeg bytes, pixel size
        case text(title: String, bullets: [String])
    }

    // 16:9, in EMU (914,400 to the inch).
    static let width = 12_192_000, height = 6_858_000

    static func write(_ slides: [Slide], title: String, to url: URL) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pptx-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        func put(_ path: String, _ text: String) throws {
            let u = root.appendingPathComponent(path)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: u)
        }
        let ns = #"xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main""#
        let head = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let emptyTree = #"<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>"#

        let n = slides.count
        try put("[Content_Types].xml", head + """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Default Extension="png" ContentType="image/png"/>\
        <Default Extension="jpeg" ContentType="image/jpeg"/>\
        <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>\
        <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>\
        <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>\
        <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>\
        <Override PartName="/ppt/presProps.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presProps+xml"/>\
        <Override PartName="/ppt/viewProps.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.viewProps+xml"/>\
        <Override PartName="/ppt/tableStyles.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.tableStyles+xml"/>\
        <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
        <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>\
        \((0..<n).map { #"<Override PartName="/ppt/slides/slide\#($0 + 1).xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>"# }.joined())\
        </Types>
        """)
        try put("_rels/.rels", head + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="\(rel)/officeDocument" Target="ppt/presentation.xml"/>\
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
        <Relationship Id="rId3" Type="\(rel)/extended-properties" Target="docProps/app.xml"/>\
        </Relationships>
        """)
        try put("docProps/core.xml", head + """
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>\(esc(title))</dc:title><dc:creator>StudyBar</dc:creator></cp:coreProperties>
        """)
        try put("docProps/app.xml", head + #"<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>StudyBar</Application></Properties>"#)

        // presentation: master rId1, slides rId2…, then the shared parts.
        let slideIDs = (0..<n).map { #"<p:sldId id="\#(256 + $0)" r:id="rId\#($0 + 2)"/>"# }.joined()
        try put("ppt/presentation.xml", head + """
        <p:presentation \(ns) saveSubsetFonts="1"><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>\
        <p:sldIdLst>\(slideIDs)</p:sldIdLst><p:sldSz cx="\(width)" cy="\(height)"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>
        """)
        let k = n + 2
        try put("ppt/_rels/presentation.xml.rels", head + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="\(rel)/slideMaster" Target="slideMasters/slideMaster1.xml"/>\
        \((0..<n).map { #"<Relationship Id="rId\#($0 + 2)" Type="\#(rel)/slide" Target="slides/slide\#($0 + 1).xml"/>"# }.joined())\
        <Relationship Id="rId\(k)" Type="\(rel)/presProps" Target="presProps.xml"/>\
        <Relationship Id="rId\(k + 1)" Type="\(rel)/viewProps" Target="viewProps.xml"/>\
        <Relationship Id="rId\(k + 2)" Type="\(rel)/theme" Target="theme/theme1.xml"/>\
        <Relationship Id="rId\(k + 3)" Type="\(rel)/tableStyles" Target="tableStyles.xml"/>\
        </Relationships>
        """)
        try put("ppt/presProps.xml", head + "<p:presentationPr \(ns)/>")
        try put("ppt/viewProps.xml", head + "<p:viewPr \(ns)/>")
        try put("ppt/tableStyles.xml", head + #"<a:tblStyleLst xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" def="{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}"/>"#)

        try put("ppt/slideMasters/slideMaster1.xml", head + """
        <p:sldMaster \(ns)><p:cSld><p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg><p:spTree>\(emptyTree)</p:spTree></p:cSld>\
        <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>\
        <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>\
        <p:txStyles><p:titleStyle><a:lvl1pPr><a:defRPr sz="4000"/></a:lvl1pPr></p:titleStyle><p:bodyStyle><a:lvl1pPr><a:defRPr sz="2000"/></a:lvl1pPr></p:bodyStyle><p:otherStyle><a:lvl1pPr><a:defRPr sz="1800"/></a:lvl1pPr></p:otherStyle></p:txStyles></p:sldMaster>
        """)
        try put("ppt/slideMasters/_rels/slideMaster1.xml.rels", head + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="\(rel)/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>\
        <Relationship Id="rId2" Type="\(rel)/theme" Target="../theme/theme1.xml"/></Relationships>
        """)
        try put("ppt/slideLayouts/slideLayout1.xml", head + """
        <p:sldLayout \(ns) type="blank" preserve="1"><p:cSld name="Blank"><p:spTree>\(emptyTree)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>
        """)
        try put("ppt/slideLayouts/_rels/slideLayout1.xml.rels", head + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="\(rel)/slideMaster" Target="../slideMasters/slideMaster1.xml"/></Relationships>
        """)
        try put("ppt/theme/theme1.xml", head + theme)

        for (i, slide) in slides.enumerated() {
            var rels = #"<Relationship Id="rId1" Type="\#(rel)/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>"#
            let shapes: String
            switch slide {
            case .image(let data, let ext, let size):
                let name = "image\(i + 1).\(ext)"
                try fm.createDirectory(at: root.appendingPathComponent("ppt/media"), withIntermediateDirectories: true)
                try data.write(to: root.appendingPathComponent("ppt/media/\(name)"))
                rels += #"<Relationship Id="rId2" Type="\#(rel)/image" Target="../media/\#(name)"/>"#
                // Fit the page to the slide, centred, keeping its shape.
                let s = min(Double(width) / max(1, size.width), Double(height) / max(1, size.height))
                let cx = Int(size.width * s), cy = Int(size.height * s)
                shapes = """
                <p:pic><p:nvPicPr><p:cNvPr id="2" name="Page \(i + 1)"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>\
                <p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>\
                <p:spPr><a:xfrm><a:off x="\((width - cx) / 2)" y="\((height - cy) / 2)"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>
                """
            case .text(let title, let bullets):
                let body = bullets.map {
                    #"<a:p><a:pPr marL="342900" indent="-342900"><a:buFont typeface="Arial"/><a:buChar char="•"/></a:pPr><a:r><a:rPr lang="en-US" sz="2000" dirty="0"/><a:t>\#(esc($0))</a:t></a:r></a:p>"#
                }.joined()
                shapes = textBox(id: 2, name: "Title", y: 457_200, cy: 1_143_000,
                                 paras: #"<a:p><a:r><a:rPr lang="en-US" sz="3600" b="1" dirty="0"/><a:t>\#(esc(title))</a:t></a:r></a:p>"#)
                    + textBox(id: 3, name: "Body", y: 1_714_500, cy: 4_686_300, paras: body.isEmpty ? "<a:p/>" : body)
            }
            try put("ppt/slides/slide\(i + 1).xml", head + """
            <p:sld \(ns)><p:cSld><p:spTree>\(emptyTree)\(shapes)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
            """)
            try put("ppt/slides/_rels/slide\(i + 1).xml.rels", head + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\#(rels)</Relationships>"#)
        }

        try? fm.removeItem(at: url)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = root
        zip.arguments = ["-q", "-X", "-r", url.path, "[Content_Types].xml", "_rels", "docProps", "ppt"]
        try zip.run(); zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func textBox(id: Int, name: String, y: Int, cy: Int, paras: String) -> String {
        """
        <p:sp><p:nvSpPr><p:cNvPr id="\(id)" name="\(name)"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>\
        <p:spPr><a:xfrm><a:off x="609600" y="\(y)"/><a:ext cx="\(width - 1_219_200)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>\
        <p:txBody><a:bodyPr wrap="square" rtlCol="0"><a:normAutofit/></a:bodyPr><a:lstStyle/>\(paras)</p:txBody></p:sp>
        """
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The Office theme, cut to what a file must have: twelve colours, two fonts, and three of
    /// each fill, line, effect and background style.
    private static let theme = """
    <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Office Theme"><a:themeElements>\
    <a:clrScheme name="Office"><a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1><a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1>\
    <a:dk2><a:srgbClr val="1F2937"/></a:dk2><a:lt2><a:srgbClr val="F3F4F6"/></a:lt2><a:accent1><a:srgbClr val="4F8DFD"/></a:accent1>\
    <a:accent2><a:srgbClr val="F59E0B"/></a:accent2><a:accent3><a:srgbClr val="10B981"/></a:accent3><a:accent4><a:srgbClr val="EF4444"/></a:accent4>\
    <a:accent5><a:srgbClr val="8B5CF6"/></a:accent5><a:accent6><a:srgbClr val="06B6D4"/></a:accent6><a:hlink><a:srgbClr val="2563EB"/></a:hlink>\
    <a:folHlink><a:srgbClr val="7C3AED"/></a:folHlink></a:clrScheme>\
    <a:fontScheme name="Office"><a:majorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>\
    <a:minorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme>\
    <a:fmtScheme name="Office"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst>\
    <a:lnStyleLst><a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="19050"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst>\
    <a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>\
    <a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme>\
    </a:themeElements></a:theme>
    """
}

// MARK: - A note as slides

extension PPTX {
    /// The note's own structure as slides: a title slide, then a slide per `##`/`###` heading
    /// with its points as bullets — six to a slide, continued when there are more. Faithful and
    /// instant; `condensed` is the AI's shorter version when an engine is set.
    static func outline(_ md: String, title: String) -> [Slide] {
        var slides: [Slide] = [.text(title: title, bullets: [])]
        var current: (title: String, bullets: [String])?
        func flush() {
            guard let c = current else { return }
            let chunks = stride(from: 0, to: max(1, c.bullets.count), by: 6).map { Array(c.bullets.dropFirst($0).prefix(6)) }
            for (i, b) in chunks.enumerated() { slides.append(.text(title: i == 0 ? c.title : c.title + " (cont.)", bullets: b)) }
            current = nil
        }
        for raw in md.components(separatedBy: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || MathMarkdown.isTableRule(t) { continue }
            if t.hasPrefix("# ") {
                if slides.count == 1, current == nil { slides[0] = .text(title: plain(String(t.dropFirst(2))), bullets: []) }
                continue
            }
            if t.hasPrefix("## ") || t.hasPrefix("### ") {
                flush(); current = (plain(String(t.drop(while: { $0 == "#" }))), []); continue
            }
            var line = t
            for p in ["- [ ] ", "- [x] ", "- ", "* ", "• ", "◦ ", "> "] where line.hasPrefix(p) { line = String(line.dropFirst(p.count)); break }
            if line.hasPrefix("|") {
                line = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " — ")
            }
            let text = plain(line)
            guard !text.isEmpty else { continue }
            if current == nil { current = (title, []) }
            current?.bullets.append(text.count > 220 ? String(text.prefix(217)) + "…" : text)
        }
        flush()
        return slides
    }

    /// Markdown marks off and LaTeX as the symbols it stands for, for a slide that shows text as
    /// text: `$\Phi_E = \frac{Q}{\varepsilon_0}$` → "Φ_E = Q/ε_0".
    static func plain(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        for m in ["**Added:**", "Added: ", "💡 ", "**", "__", "`", "$$", "$", "[[", "]]"] { t = t.replacingOccurrences(of: m, with: "") }
        t = t.replacingOccurrences(of: #"(?<![A-Za-z])\*(?!\s)"#, with: "", options: .regularExpression)
        guard t.contains("\\") || t.contains("^") else { return t.trimmingCharacters(in: .whitespaces) }
        func rx(_ p: String, _ w: String) { t = t.replacingOccurrences(of: p, with: w, options: .regularExpression) }
        var prev = ""
        while prev != t { prev = t; rx(#"\\[dt]?frac\s*\{([^{}]*)\}\s*\{([^{}]*)\}"#, "$1/$2") }
        rx(#"\\sqrt\s*\{([^{}]*)\}"#, "√($1)")
        rx(#"\\(?:vec|mathbf|mathrm|text|hat|bar|operatorname)\s*\{([^{}]*)\}"#, "$1")
        let symbols: [String: String] = [
            "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε", "theta": "θ", "lambda": "λ",
            "mu": "μ", "pi": "π", "rho": "ρ", "sigma": "σ", "tau": "τ", "phi": "φ", "varphi": "φ", "omega": "ω",
            "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Sigma": "Σ", "Phi": "Φ", "Omega": "Ω",
            "cdot": "·", "times": "×", "pm": "±", "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠",
            "approx": "≈", "infty": "∞", "int": "∫", "oint": "∮", "sum": "Σ", "partial": "∂", "nabla": "∇",
            "rightarrow": "→", "to": "→", "Rightarrow": "⇒", "propto": "∝", "degree": "°", "circ": "°",
            "left": "", "right": "", ",": " ", ";": " ", "quad": " "]
        for (name, sym) in symbols.sorted(by: { $0.key.count > $1.key.count }) {
            rx("\\\\" + NSRegularExpression.escapedPattern(for: name) + "(?![A-Za-z])", sym)
        }
        for (d, sup) in zip("0123456789", "⁰¹²³⁴⁵⁶⁷⁸⁹") { rx("\\^\\{?\(d)\\}?(?![0-9])", String(sup)) }
        t = t.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// The AI's version: fewer, shorter slides. nil if the engine returns nothing usable.
    static func condensed(_ md: String, title: String, provider: AIProvider) async -> [Slide]? {
        let sys = """
        You turn a student's study note into a slide deck for presenting it. 6–12 slides, each a short \
        title and 3–6 bullets of at most about 12 words, in the note's order, covering its key points. \
        Write any math as plain text a slide can show (E = kq/r², not LaTeX). Reply with ONLY a JSON \
        object: {"slides":[{"title":"…","bullets":["…","…"]}]}
        """
        guard let raw = try? await provider.complete(system: sys, messages: [AIMessage(role: .user, text: "NOTE:\n\"\"\"\n\(md)\n\"\"\"")]),
              let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let d = try? JSONSerialization.jsonObject(with: Data(AIProtocol.sanitizeJSON(Quiz.latexSafeJSON(String(raw[start...end]))).utf8)) as? [String: Any],
              let list = d["slides"] as? [[String: Any]] else { return nil }
        let slides: [Slide] = list.compactMap { s in
            guard let t = s["title"] as? String else { return nil }
            return .text(title: plain(t), bullets: ((s["bullets"] as? [Any]) ?? []).map { plain("\($0)") }.filter { !$0.isEmpty })
        }
        return slides.count >= 2 ? [.text(title: title, bullets: [])] + slides : nil
    }
}
