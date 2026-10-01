import AppKit

/// A note or document as a Word file. `NSAttributedString` writes Word's format natively but
/// drops every attachment, so a note's pictures and equations would vanish: each is swapped for
/// a marker before writing, and the file gets them back afterwards as inline pictures —
/// equations rendered the way the note shows them, in black for the page.
enum DOCX {
    static func write(_ text: NSAttributedString, to url: URL) throws {
        let doc = NSMutableAttributedString(attributedString: text.installingMath(defaultColor: .black))
        let full = NSRange(location: 0, length: doc.length)
        var found: [(range: NSRange, png: Data, size: CGSize)] = []
        doc.enumerateAttribute(.attachment, in: full) { v, r, _ in
            if let a = v as? NSTextAttachment, let p = picture(a) { found.append((r, p.png, p.size)) }
        }
        for (i, f) in found.enumerated().reversed() {
            let attrs = doc.attributes(at: f.range.location, effectiveRange: nil).filter { $0.key != .attachment }
            doc.replaceCharacters(in: f.range, with: NSAttributedString(string: marker(i), attributes: attrs))
        }
        let data = try doc.data(from: NSRange(location: 0, length: doc.length),
                                documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        guard !found.isEmpty else { try data.write(to: url); return }

        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("sb-docx-\(UUID().uuidString)")
        let root = tmp.appendingPathComponent("doc")
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let plain = tmp.appendingPathComponent("plain.docx")
        try data.write(to: plain)
        try run("/usr/bin/unzip", ["-q", plain.path, "-d", root.path], in: tmp)

        let media = root.appendingPathComponent("word/media")
        try fm.createDirectory(at: media, withIntermediateDirectories: true)
        let docURL = root.appendingPathComponent("word/document.xml")
        var xml = try String(contentsOf: docURL, encoding: .utf8)
        var rels = ""
        for (i, f) in found.enumerated() {
            try f.png.write(to: media.appendingPathComponent("sb\(i).png"))
            rels += #"<Relationship Id="rIdSB\#(i)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/sb\#(i).png"/>"#
            // A run holds text and pictures in sequence, so the marker's text element is split around it.
            xml = xml.replacingOccurrences(of: marker(i), with: #"</w:t>\#(drawing(i, f.size))<w:t xml:space="preserve">"#)
        }
        try xml.write(to: docURL, atomically: true, encoding: .utf8)

        let relsURL = root.appendingPathComponent("word/_rels/document.xml.rels")
        let oldRels = (try? String(contentsOf: relsURL, encoding: .utf8))
            ?? #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>"#
        try fm.createDirectory(at: relsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try oldRels.replacingOccurrences(of: "</Relationships>", with: rels + "</Relationships>")
            .write(to: relsURL, atomically: true, encoding: .utf8)

        let typesURL = root.appendingPathComponent("[Content_Types].xml")
        var types = try String(contentsOf: typesURL, encoding: .utf8)
        if !types.contains(#"Extension="png""#) {
            types = types.replacingOccurrences(of: "</Types>", with: #"<Default Extension="png" ContentType="image/png"/></Types>"#)
            try types.write(to: typesURL, atomically: true, encoding: .utf8)
        }

        let types0 = "[Content_Types].xml"   // first in the archive, where readers look for it
        let entries = [types0] + (try fm.contentsOfDirectory(atPath: root.path)).filter { $0 != types0 }
        let out = tmp.appendingPathComponent("out.docx")
        try run("/usr/bin/zip", ["-q", "-X", "-r", out.path] + entries, in: root)
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        try fm.moveItem(at: out, to: url)
    }

    /// Private-use characters: never in a note, and kept as they are in the XML.
    static func marker(_ i: Int) -> String { "\u{E000}SB\(i)\u{E001}" }

    /// The attachment as a PNG, and the size it takes in the text, at most a page's width.
    static func picture(_ a: NSTextAttachment) -> (png: Data, size: CGSize)? {
        guard let img = a.image ?? a.fileWrapper?.regularFileContents.flatMap(NSImage.init(data:)) else { return nil }
        var size = a.bounds.size == .zero ? img.size : a.bounds.size
        guard size.width > 0, size.height > 0 else { return nil }
        if size.width > 468 { size = CGSize(width: 468, height: size.height * 468 / size.width) }   // 6.5 in
        // Twice the size it's shown at, so an equation prints sharp.
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]).map { ($0, size) }
    }

    /// An inline picture, sized in EMU (12,700 to the point).
    static func drawing(_ i: Int, _ size: CGSize) -> String {
        let cx = Int(size.width * 12_700), cy = Int(size.height * 12_700), id = 1_000 + i
        return """
        <w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/>\
        <wp:docPr id="\(id)" name="Picture \(id)"/><a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">\
        <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">\
        <pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:nvPicPr><pic:cNvPr id="\(id)" name="sb\(i).png"/>\
        <pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="rIdSB\(i)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
        <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom>\
        </pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing>
        """
    }

    private static func run(_ tool: String, _ args: [String], in dir: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.currentDirectoryURL = dir
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
