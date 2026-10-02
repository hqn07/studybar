import AppKit
import AVFoundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

/// File conversion, done with what macOS already has: text documents through the text
/// system's own readers and writers, PDFs through PDFKit, images through ImageIO, audio and
/// video through AVFoundation, text recognition through Vision. Office layouts that the text
/// system can only approximate go through Pages, Keynote or Numbers when they're installed
/// (`IWork`), which open and export those formats faithfully.
@MainActor
enum Converter {
    enum Kind { case document, pages, pdf, image, slides, keynote, sheet, audio, video }

    enum Target: String, CaseIterable, Identifiable {
        case pdf, pdfExact, docx, rtf, odt, html, txt, md, epub
        case png, jpeg, heic, tiff, gif, imagePDF
        case searchablePDF, compressedPDF, slidesFromPDF
        case pptx, key, slideImages, xlsx, numbers, csv
        case ocrText, table
        case m4a, wav, aiff, audioOnly, mp4Small, mp4HD
        case speech
        var id: String { rawValue }

        var title: String {
            switch self {
            case .pdf: "PDF"; case .pdfExact: "PDF — exact layout (Pages)"; case .docx: "Word (.docx)"
            case .rtf: "Rich Text (.rtf)"; case .odt: "OpenDocument (.odt)"; case .html: "Web page (.html)"
            case .txt: "Plain text"; case .md: "Markdown"; case .epub: "EPUB (Pages)"
            case .png: "PNG"; case .jpeg: "JPEG"; case .heic: "HEIC"; case .tiff: "TIFF"; case .gif: "GIF"
            case .imagePDF: "PDF"
            case .searchablePDF: "Searchable PDF (read scanned text)"; case .compressedPDF: "Smaller PDF"
            case .slidesFromPDF: "PowerPoint — a slide per page"
            case .pptx: "PowerPoint (.pptx)"; case .key: "Keynote"; case .slideImages: "Slide images (PNG)"
            case .xlsx: "Excel (.xlsx)"; case .numbers: "Numbers"; case .csv: "CSV"
            case .ocrText: "Text (read from the image)"; case .table: "Markdown table (read from the image)"
            case .m4a: "M4A (AAC)"; case .wav: "WAV"; case .aiff: "AIFF"; case .audioOnly: "Audio only (M4A)"
            case .mp4Small: "Smaller video (720p MP4)"; case .mp4HD: "Video (1080p MP4)"; case .speech: "Spoken audio (M4A)"
            }
        }
        var ext: String {
            switch self {
            case .pdf, .pdfExact, .imagePDF, .searchablePDF, .compressedPDF: "pdf"
            case .docx: "docx"; case .rtf: "rtf"; case .odt: "odt"; case .html: "html"; case .txt, .ocrText: "txt"
            case .md, .table: "md"; case .epub: "epub"; case .png, .slideImages: "png"; case .jpeg: "jpg"
            case .heic: "heic"; case .tiff: "tiff"; case .gif: "gif"; case .slidesFromPDF, .pptx: "pptx"
            case .key: "key"; case .xlsx: "xlsx"; case .numbers: "numbers"; case .csv: "csv"
            case .m4a, .audioOnly, .speech: "m4a"; case .wav: "wav"; case .aiff: "aiff"; case .mp4Small, .mp4HD: "mp4"
            }
        }
        /// The app a format needs whatever it's made from. An exact-layout PDF has none of its
        /// own — it's whichever app reads the file (`Converter.app(_:for:)`).
        var app: IWork.App? {
            switch self {
            case .epub: .pages
            case .key, .slideImages: .keynote
            case .xlsx, .numbers, .csv: .numbers
            default: nil
            }
        }
    }

    static func kind(_ url: URL) -> Kind? {
        switch url.pathExtension.lowercased() {
        case "docx", "doc", "rtf", "rtfd", "odt", "html", "htm", "txt", "md", "markdown", "webarchive": .document
        case "pages": .pages
        case "pdf": .pdf
        case "png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp": .image
        case "pptx", "ppt": .slides
        case "key": .keynote
        case "xlsx", "xls", "csv", "numbers": .sheet
        case "m4a", "mp3", "wav", "aiff", "aif", "caf", "aac", "flac": .audio
        case "mp4", "mov", "m4v": .video
        default: nil
        }
    }

    /// What one file can become. The Pages/Keynote/Numbers routes appear only when that app is
    /// installed.
    static func targets(for url: URL) -> [Target] {
        let ext = url.pathExtension.lowercased()
        var t: [Target]
        switch kind(url) {
        case .document?:
            t = [.pdf, .pdfExact, .docx, .rtf, .odt, .html, .txt, .md, .epub, .speech]
            if !["docx", "doc", "rtf", "txt"].contains(ext) { t.removeAll { $0 == .pdfExact || $0 == .epub } }
        case .pages?: t = [.pdfExact, .docx, .epub, .txt]
        case .pdf?: t = [.docx, .rtf, .txt, .md, .png, .jpeg, .slidesFromPDF, .searchablePDF, .compressedPDF]
        case .image?:
            t = [.png, .jpeg, .heic, .tiff, .gif, .imagePDF, .ocrText]
            if #available(macOS 26, *) { t.append(.table) }
        case .slides?: t = [.pdfExact, .key, .slideImages]
        case .keynote?: t = [.pdfExact, .pptx, .slideImages]
        case .sheet?: t = ext == "csv" ? [.xlsx, .numbers, .pdfExact] : [.pdfExact, .xlsx, .numbers, .csv].filter { $0.ext != ext }
        case .audio?: t = [.m4a, .wav, .aiff].filter { $0.ext != ext }
        case .video?: t = [.audioOnly, .mp4Small, .mp4HD]
        case nil: t = []
        }
        // Converting to what it already is does nothing.
        t.removeAll { $0.ext == ext && ![.searchablePDF, .compressedPDF].contains($0) && $0.app == nil }
        return t.filter { app($0, for: url).map(IWork.installed) ?? true }
    }

    /// Which app does the work, when it isn't StudyBar itself. Pages, Keynote and Numbers files —
    /// and Office slides and sheets — only their own app reads faithfully, so every conversion of
    /// them goes through it; an exact-layout PDF goes through whichever app reads the file.
    static func app(_ t: Target, for url: URL) -> IWork.App? {
        let appKinds: [Kind] = [.pages, .keynote, .slides, .sheet]
        if t == .pdfExact || kind(url).map(appKinds.contains) == true { return appFor(url) }
        return t.app
    }

    /// Where a converted file goes: beside the original (or in `dir`), never over a file that's there.
    static func destination(for url: URL, ext: String, suffix: String = "", in dir: URL? = nil) -> URL {
        // A fetched web page has no folder of its own to be "next to".
        let web = url.deletingLastPathComponent().standardizedFileURL == WebPage.dir.standardizedFileURL
        let folder = dir ?? (web ? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] : url.deletingLastPathComponent())
        let base = url.deletingPathExtension().lastPathComponent + suffix
        var out = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: out.path) {
            out = folder.appendingPathComponent("\(base) (\(n))").appendingPathExtension(ext); n += 1
        }
        return out
    }

    enum Failure: LocalizedError {
        case unreadable, nothingFound, notSmaller, app(String)
        var errorDescription: String? {
            switch self {
            case .unreadable: "Couldn't read this file."
            case .nothingFound: "Found nothing to convert — no text, or no table."
            case .notSmaller: "It's already about as small as it gets; nothing was saved."
            case .app(let s): s
            }
        }
    }

    /// Convert one file. Returns what was written (several files for page and slide images).
    static func convert(_ url: URL, to t: Target, in dir: URL? = nil) async throws -> [URL] {
        let out = destination(for: url, ext: t.ext, suffix: t == .searchablePDF ? " (searchable)" : t == .compressedPDF ? " (smaller)" : "", in: dir)
        if let app = app(t, for: url) {
            if t == .slideImages {
                let folder = out.deletingPathExtension()
                try await IWork.export(url, with: app, as: t, to: folder)
                return [folder]
            }
            try await IWork.export(url, with: app, as: t, to: out)
            return [out]
        }
        switch kind(url) {
        case .document?:
            if t == .speech { try await speak(try readText(url), to: out); return [out] }
            try await writeDocument(try readDocument(url), as: t, to: out, title: url.deletingPathExtension().lastPathComponent)
            return [out]
        case .pdf?:
            return try await convertPDF(url, to: t, out: out)
        case .image?:
            switch t {
            case .ocrText:
                guard let img = cgImage(url) else { throw Failure.unreadable }
                let text = StudyMaterial.ocr(img)
                guard !text.isEmpty else { throw Failure.nothingFound }
                try text.write(to: out, atomically: true, encoding: .utf8)
            case .table:
                guard #available(macOS 26, *) else { throw Failure.nothingFound }
                let md = try await tableMarkdown(url)
                try md.write(to: out, atomically: true, encoding: .utf8)
            case .imagePDF:
                try imagesToPDF([url], to: out)
            default:
                try convertImage(url, to: t, out: out)
            }
            return [out]
        case .audio?, .video?:
            try await exportMedia(url, to: t, out: out)
            return [out]
        default:
            throw Failure.unreadable
        }
    }

    private static func appFor(_ url: URL) -> IWork.App? {
        switch kind(url) {
        case .document?, .pages?: .pages
        case .slides?, .keynote?: .keynote
        case .sheet?: .numbers
        default: nil
        }
    }

    // MARK: Documents

    static func readDocument(_ url: URL) throws -> NSAttributedString {
        switch url.pathExtension.lowercased() {
        case "md", "markdown":
            // The note renderer's own Markdown reading, so headings, lists and tables come across.
            let html = "<html><head><meta charset=\"utf-8\"></head><body>\(MathMarkdown.bodyHTML(try String(contentsOf: url, encoding: .utf8), raw: []))</body></html>"
            return try NSAttributedString(data: Data(html.utf8), options: [.documentType: NSAttributedString.DocumentType.html,
                                                                           .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
        case "txt":
            return NSAttributedString(string: try String(contentsOf: url, encoding: .utf8), attributes: [.font: NSFont.systemFont(ofSize: 12)])
        default:
            let types: [String: NSAttributedString.DocumentType] = ["docx": .officeOpenXML, "doc": .docFormat, "odt": .openDocument,
                                                                     "rtf": .rtf, "rtfd": .rtfd, "html": .html, "htm": .html, "webarchive": .webArchive]
            var opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
            if let t = types[url.pathExtension.lowercased()] { opts[.documentType] = t }
            return try NSAttributedString(url: url, options: opts, documentAttributes: nil)
        }
    }

    private static func readText(_ url: URL) throws -> String {
        ["txt", "md", "markdown"].contains(url.pathExtension.lowercased())
            ? try String(contentsOf: url, encoding: .utf8) : try readDocument(url).string
    }

    static func writeDocument(_ a: NSAttributedString, as t: Target, to out: URL, title: String) async throws {
        let full = NSRange(location: 0, length: a.length)
        switch t {
        case .pdf:
            // The note PDF engine: the same page layout, header and page numbers as a note.
            guard let data = await NotePDF.render(body: NoteHTML.body(from: a), meta: .init(title: "", subtitle: title),
                                                  options: PDFOptions.saved) else { throw Failure.unreadable }
            try data.write(to: out)
        case .md:
            try NoteHTML.markdown(from: a).write(to: out, atomically: true, encoding: .utf8)
        case .txt:
            try a.string.write(to: out, atomically: true, encoding: .utf8)
        case .docx:
            try DOCX.write(a, to: out)
        default:
            let type: NSAttributedString.DocumentType = t == .docx ? .officeOpenXML : t == .odt ? .openDocument : t == .html ? .html : .rtf
            try a.data(from: full, documentAttributes: [.documentType: type]).write(to: out)
        }
    }

    // MARK: PDF

    private static func convertPDF(_ url: URL, to t: Target, out: URL) async throws -> [URL] {
        guard let doc = PDFDocument(url: url) else { throw Failure.unreadable }
        switch t {
        case .docx, .rtf, .txt, .md:
            // The text layer, page by page — read off the page where there is none.
            let a = NSMutableAttributedString()
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                if let s = page.attributedString, s.string.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 { a.append(s) }
                else if let img = StudyMaterial.render(page) { a.append(NSAttributedString(string: StudyMaterial.ocr(img))) }
                a.append(NSAttributedString(string: "\n\n"))
            }
            guard !a.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.nothingFound }
            try await writeDocument(a, as: t, to: out, title: url.deletingPathExtension().lastPathComponent)
            return [out]
        case .png, .jpeg:
            // One image per page, at 150 dpi.
            let folder = out.deletingPathExtension()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var written: [URL] = []
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i), let img = StudyMaterial.render(page, scale: 150.0 / 72) else { continue }
                let u = folder.appendingPathComponent("Page \(i + 1)").appendingPathExtension(t.ext)
                try write(img, to: u, type: t == .png ? .png : .jpeg, quality: 0.9)
                written.append(u)
            }
            return [folder]
        case .slidesFromPDF:
            var slides: [PPTX.Slide] = []
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i), let img = StudyMaterial.render(page, scale: 2),
                      let data = encode(img, type: .jpeg, quality: 0.85) else { continue }
                slides.append(.image(data, ext: "jpeg", size: CGSize(width: img.width, height: img.height)))
            }
            try PPTX.write(slides, title: url.deletingPathExtension().lastPathComponent, to: out)
            return [out]
        case .searchablePDF:
            try await Task.detached { try SearchablePDF.write(from: url, to: out, rasterizeAll: false) }.value
            return [out]
        case .compressedPDF:
            try await Task.detached { try SearchablePDF.write(from: url, to: out, rasterizeAll: true, scale: 1.5, jpegQuality: 0.55) }.value
            let before = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            let after = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
            if after == 0 || Double(after) > Double(before) * 0.9 { try? FileManager.default.removeItem(at: out); throw Failure.notSmaller }
            return [out]
        default:
            throw Failure.unreadable
        }
    }

    /// Several PDFs into one, in the order given.
    static func merge(_ pdfs: [URL], to out: URL) throws {
        let merged = PDFDocument()
        for u in pdfs {
            guard let d = PDFDocument(url: u) else { throw Failure.unreadable }
            for i in 0..<d.pageCount { if let p = d.page(at: i) { merged.insert(p, at: merged.pageCount) } }
        }
        guard merged.write(to: out) else { throw Failure.unreadable }
    }

    /// Each page as its own PDF, in a folder beside the original.
    static func split(_ url: URL) throws -> URL {
        guard let d = PDFDocument(url: url) else { throw Failure.unreadable }
        let folder = destination(for: url, ext: "", suffix: " pages")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for i in 0..<d.pageCount {
            let one = PDFDocument()
            if let p = d.page(at: i) { one.insert(p, at: 0) }
            one.write(to: folder.appendingPathComponent("Page \(i + 1).pdf"))
        }
        return folder
    }

    /// "1-3, 5, 8-" → those pages (1-based) of a document with `count` pages.
    static func pages(_ spec: String, count: Int) -> [Int] {
        var out: [Int] = []
        for part in spec.split(separator: ",") {
            let bits = part.split(separator: "-", omittingEmptySubsequences: false).map { Int($0.trimmingCharacters(in: .whitespaces)) }
            if bits.count == 1, let n = bits[0] { out.append(n) }
            else if bits.count == 2 {
                let a = bits[0] ?? 1, b = bits[1] ?? count
                if a <= b { out += Array(a...b) }
            }
        }
        return out.filter { (1...max(1, count)).contains($0) }
    }

    static func extract(_ url: URL, pages spec: String) throws -> URL {
        guard let d = PDFDocument(url: url) else { throw Failure.unreadable }
        let wanted = pages(spec, count: d.pageCount)
        guard !wanted.isEmpty else { throw Failure.nothingFound }
        let out = destination(for: url, ext: "pdf", suffix: " (pages \(spec.replacingOccurrences(of: " ", with: "")))")
        let one = PDFDocument()
        for n in wanted { if let p = d.page(at: n - 1) { one.insert(p, at: one.pageCount) } }
        guard one.write(to: out) else { throw Failure.unreadable }
        return out
    }

    /// Every page turned a quarter to the right, saved as a copy.
    static func rotate(_ url: URL) throws -> URL {
        guard let d = PDFDocument(url: url) else { throw Failure.unreadable }
        for i in 0..<d.pageCount { if let p = d.page(at: i) { p.rotation = (p.rotation + 90) % 360 } }
        let out = destination(for: url, ext: "pdf", suffix: " (rotated)")
        guard d.write(to: out) else { throw Failure.unreadable }
        return out
    }

    // MARK: Images

    static func cgImage(_ url: URL, maxPixel: Int? = nil) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        // A thumbnail at full size is how ImageIO applies the photo's orientation.
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let longest = max(props?[kCGImagePropertyPixelWidth] as? Int ?? 4096, props?[kCGImagePropertyPixelHeight] as? Int ?? 4096)
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: min(maxPixel ?? longest, longest)]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    static func encode(_ img: CGImage, type: UTType, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dst) ? data as Data : nil
    }

    static func write(_ img: CGImage, to url: URL, type: UTType, quality: Double) throws {
        guard let d = encode(img, type: type, quality: quality) else { throw Failure.unreadable }
        try d.write(to: url)
    }

    private static func convertImage(_ url: URL, to t: Target, out: URL) throws {
        let type: UTType = switch t { case .png: .png; case .jpeg: .jpeg; case .heic: .heic; case .tiff: .tiff; default: .gif }
        guard let img = cgImage(url) else { throw Failure.unreadable }
        try write(img, to: out, type: type, quality: 0.85)
    }

    /// Photos and scans as pages of one PDF, each fitted to a Letter page the way it's turned.
    static func imagesToPDF(_ urls: [URL], to out: URL) throws {
        let doc = PDFDocument()
        for u in urls {
            guard let cg = cgImage(u, maxPixel: 3000) else { continue }
            let landscape = cg.width > cg.height
            let box = CGRect(x: 0, y: 0, width: landscape ? 792 : 612, height: landscape ? 612 : 792)
            let img = NSImage(cgImage: cg, size: .zero)
            if let page = PDFPage(image: img, options: [.mediaBox: box, .compressionQuality: 0.8, .upscaleIfSmaller: true]) {
                doc.insert(page, at: doc.pageCount)
            }
        }
        guard doc.pageCount > 0, doc.write(to: out) else { throw Failure.unreadable }
    }

    /// Images as frames of one looping GIF, half a second each.
    static func imagesToGIF(_ urls: [URL], to out: URL, delay: Double = 0.5) throws {
        guard let dst = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, urls.count, nil) else { throw Failure.unreadable }
        CGImageDestinationSetProperties(dst, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for u in urls {
            guard let img = cgImage(u, maxPixel: 800) else { continue }
            CGImageDestinationAddImage(dst, img, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dst) else { throw Failure.unreadable }
    }

    /// Every frame of a GIF (or page of a multi-page TIFF) as its own PNG.
    static func frames(_ url: URL) throws -> URL {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw Failure.unreadable }
        let folder = destination(for: url, ext: "", suffix: " frames")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for i in 0..<CGImageSourceGetCount(src) {
            if let img = CGImageSourceCreateImageAtIndex(src, i, nil) {
                try write(img, to: folder.appendingPathComponent("Frame \(i + 1).png"), type: .png, quality: 1)
            }
        }
        return folder
    }

    /// Tables in a photo or scan, as Markdown — Vision's document reader (macOS 26).
    @available(macOS 26, *)
    static func tableMarkdown(_ url: URL) async throws -> String {
        let docs = try await RecognizeDocumentsRequest().perform(on: url)
        let tables = docs.flatMap(\.document.tables)
        guard !tables.isEmpty else { throw Failure.nothingFound }
        return tables.map { table in
            let rows = table.rows.map { row in
                "| " + row.map { $0.content.text.transcript.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "\\|") }
                    .joined(separator: " | ") + " |"
            }
            guard let first = rows.first else { return "" }
            let cols = table.rows.first?.count ?? 1
            return ([first, "|" + String(repeating: "---|", count: cols)] + rows.dropFirst()).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    // MARK: Audio, video, speech

    static func exportMedia(_ url: URL, to t: Target, out: URL) async throws {
        let asset = AVURLAsset(url: url)
        if t == .wav || t == .aiff {
            try await Task.detached { try pcm(url, to: out, type: t == .wav ? .wav : .aiff) }.value
            return
        }
        let preset = t == .mp4Small ? AVAssetExportPreset1280x720 : t == .mp4HD ? AVAssetExportPreset1920x1080 : AVAssetExportPresetAppleM4A
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { throw Failure.unreadable }
        let type: AVFileType = t.ext == "mp4" ? .mp4 : .m4a
        if #available(macOS 15, *) {
            try await session.export(to: out, as: type)
        } else {
            session.outputURL = out; session.outputFileType = type
            await session.export()
            if session.status != .completed { throw session.error ?? Failure.unreadable }
        }
    }

    /// Uncompressed audio: decode whatever it is, write it back out as PCM.
    nonisolated private static func pcm(_ url: URL, to out: URL, type: AVFileType) throws {
        let input = try AVAudioFile(forReading: url)
        let fmt = input.processingFormat
        var settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: fmt.sampleRate,
                                       AVNumberOfChannelsKey: fmt.channelCount, AVLinearPCMBitDepthKey: 16,
                                       AVLinearPCMIsFloatKey: false]
        if type == .aiff { settings[AVLinearPCMIsBigEndianKey] = true }
        let output = try AVAudioFile(forWriting: out, settings: settings, commonFormat: fmt.commonFormat, interleaved: fmt.isInterleaved)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 65_536) else { throw Failure.unreadable }
        while input.framePosition < input.length {
            try input.read(into: buf)
            if buf.frameLength == 0 { break }
            try output.write(from: buf)
        }
    }

    /// The best installed voice in the Mac's language: a Premium or Enhanced one when the student
    /// has downloaded it (System Settings ▸ Accessibility ▸ Spoken Content), which sound far less
    /// robotic over ten minutes than the default compact voice.
    static func bestVoice() -> AVSpeechSynthesisVoice? {
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        let rank: [AVSpeechSynthesisVoiceQuality: Int] = [.premium: 3, .enhanced: 2, .default: 1]
        // Quality first; among equals, the voice the Mac uses for its language, then the Mac's own
        // variety of it (en-US over en-GB) — not "Grandpa", which is also a standard voice.
        let mine = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())?.identifier
        func score(_ v: AVSpeechSynthesisVoice) -> Int {
            (rank[v.quality] ?? 0) * 4 + (v.identifier == mine ? 2 : 0) + (v.language == AVSpeechSynthesisVoice.currentLanguageCode() ? 1 : 0)
        }
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(lang) && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .max { score($0) < score($1) }
            ?? AVSpeechSynthesisVoice(language: lang)
    }

    /// When the synthesizer is really done. An empty buffer used to be read as the end, and on a
    /// long text one comes every few sentences: ten minutes of review came out as twelve seconds.
    private final class SpeechEnd: NSObject, AVSpeechSynthesizerDelegate {
        var done: (() -> Void)?
        func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { done?(); done = nil }
        func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { done?(); done = nil }
    }

    /// Text read aloud into an audio file, with the system voice — notes to listen to.
    static func speak(_ text: String, to out: URL) async throws {
        let synth = AVSpeechSynthesizer()
        let end = SpeechEnd()
        synth.delegate = end
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = bestVoice()
        var file: AVAudioFile?
        var failed: Error?
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            end.done = { done.resume() }
            synth.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else { return }
                do {
                    if file == nil {
                        file = try AVAudioFile(forWriting: out, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                                                          AVSampleRateKey: pcm.format.sampleRate,
                                                                          AVNumberOfChannelsKey: pcm.format.channelCount],
                                               commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
                    }
                    try file?.write(from: pcm)
                } catch { failed = error }
            }
        }
        file = nil
        synth.delegate = nil
        if let failed { throw failed }
        guard FileManager.default.fileExists(atPath: out.path) else { throw Failure.nothingFound }
    }
}

// MARK: - Searchable and smaller PDFs

/// A PDF with a text layer: each page as it looks, and behind it the words Vision read off it,
/// drawn invisibly where they sit — so a scan can be searched, selected and copied from.
/// `rasterizeAll` redraws every page as a JPEG too, which is what makes a heavy scan smaller;
/// otherwise pages that already have text are copied through untouched.
enum SearchablePDF {
    static func write(from src: URL, to out: URL, rasterizeAll: Bool, scale: CGFloat = 2, jpegQuality: CGFloat = 0.8) throws {
        guard let doc = CGPDFDocument(src as CFURL), let pdfkit = PDFDocument(url: src) else { throw Converter.Failure.unreadable }
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(out as CFURL, mediaBox: &box, nil) else { throw Converter.Failure.unreadable }
        for i in 1...max(1, doc.numberOfPages) where doc.numberOfPages > 0 {
            guard let page = doc.page(at: i), let kitPage = pdfkit.page(at: i - 1) else { continue }
            var media = page.getBoxRect(.cropBox)
            let hasText = (kitPage.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).count > 20
            ctx.beginPage(mediaBox: &media)
            if hasText && !rasterizeAll {
                ctx.drawPDFPage(page)
            } else if let img = StudyMaterial.render(kitPage, scale: scale) {
                let drawn = rasterizeAll ? (Converter.encodeNonisolated(img, quality: jpegQuality).flatMap { d in
                    CGImageSourceCreateWithData(d as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } } ?? img) : img
                ctx.draw(drawn, in: media)
                overlayText(img, in: media, ctx: ctx)
            }
            ctx.endPage()
        }
        ctx.closePDF()
    }

    /// Recognised lines drawn in invisible text mode, each stretched to the box it was read from.
    private static func overlayText(_ img: CGImage, in media: CGRect, ctx: CGContext) {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: img).perform([req])
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        for obs in req.results ?? [] {
            guard let text = obs.topCandidates(1).first?.string, !text.isEmpty else { continue }
            let b = obs.boundingBox
            let rect = CGRect(x: media.minX + b.minX * media.width, y: media.minY + b.minY * media.height,
                              width: b.width * media.width, height: b.height * media.height)
            let font = CTFontCreateWithName("Helvetica" as CFString, max(1, rect.height * 0.85), nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
            let w = CTLineGetTypographicBounds(line, nil, nil, nil)
            ctx.textMatrix = CGAffineTransform(scaleX: rect.width / max(w, 1), y: 1)
            ctx.textPosition = CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.15)
            CTLineDraw(line, ctx)
        }
        ctx.restoreGState()
    }
}

extension Converter {
    nonisolated static func encodeNonisolated(_ img: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dst) ? data as Data : nil
    }
}

// MARK: - Pages, Keynote, Numbers

/// Faithful Office conversion by asking Apple's own apps: they open .docx/.pptx/.xlsx with
/// their layout and export PDF, Office, EPUB and images. Scripted through `osascript`, so the
/// first use asks for permission to control the app (System Settings ▸ Privacy & Security ▸
/// Automation).
enum IWork {
    enum App: String {
        case pages = "Pages", keynote = "Keynote", numbers = "Numbers"
        var bundleID: String { "com.apple.iWork.\(rawValue)" }
    }

    static func installed(_ app: App) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) != nil
    }

    static func export(_ src: URL, with app: App, as t: Converter.Target, to out: URL) async throws {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let format: String
        switch t {
        case .pdfExact: format = "PDF"
        case .docx: format = "Microsoft Word"
        case .epub: format = "EPUB"
        case .txt: format = "unformatted text"
        case .pptx: format = "Microsoft PowerPoint"
        case .slideImages: format = "slide images with properties {image format:PNG}"
        case .xlsx: format = "Microsoft Excel"
        case .csv: format = "CSV"
        case .key, .numbers: format = ""                 // a native document: save, not export
        default: throw Converter.Failure.unreadable
        }
        let action = format.isEmpty ? "save d in (POSIX file \(q(out.path)))" : "export d to (POSIX file \(q(out.path))) as \(format)"
        let script = """
        tell application id \(q(app.bundleID))
            set d to open (POSIX file \(q(src.path)))
            \(action)
            close d saving no
        end tell
        """
        let result: (status: Int32, err: String) = await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            let errPipe = Pipe()
            p.standardError = errPipe; p.standardOutput = FileHandle.nullDevice
            do { try p.run() } catch { return (-1, error.localizedDescription) }
            p.waitUntilExit()
            return (p.terminationStatus, String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        }.value
        guard result.status == 0 else {
            if result.err.contains("-1743") || result.err.localizedCaseInsensitiveContains("not authorized") {
                throw Converter.Failure.app("StudyBar isn't allowed to use \(app.rawValue) yet — allow it in System Settings ▸ Privacy & Security ▸ Automation, then try again.")
            }
            throw Converter.Failure.app("\(app.rawValue) couldn't convert it: \(result.err.trimmingCharacters(in: .whitespacesAndNewlines).suffix(160))")
        }
    }
}

// MARK: - Self-test (StudyBar --convert-selftest)

/// Real conversions on generated files, each output read back. Pages/Keynote/Numbers are not
/// driven here — that needs the user's Automation permission; the PPTX is checked by Quick Look.
enum ConvertSelfTest {
    @MainActor
    static func run() async -> Int32 {
        var fail = 0
        func check(_ n: String, _ ok: Bool, _ d: String = "") { print("  \(ok ? "ok  " : "FAIL") \(n) \(d)"); if !ok { fail += 1 } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-convert-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { if ProcessInfo.processInfo.environment["SB_KEEP"] != "1" { try? FileManager.default.removeItem(at: dir) } else { print("  kept \(dir.path)") } }
        func size(_ u: URL) -> Int { (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0 }
        func tryConvert(_ u: URL, _ t: Converter.Target) async -> URL? {
            do { return try await Converter.convert(u, to: t).first } catch { print("       \(t): \(error.localizedDescription)"); return nil }
        }

        // A Word document with a heading, bold and a list.
        let doc = NSMutableAttributedString()
        doc.append(NSAttributedString(string: "Gauss's Law\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 24)]))
        doc.append(NSAttributedString(string: "Flux is ", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        doc.append(NSAttributedString(string: "charge over epsilon", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)]))
        doc.append(NSAttributedString(string: ".\n• outside charges cancel\n", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        let docx = dir.appendingPathComponent("Lecture.docx")
        try? doc.data(from: NSRange(location: 0, length: doc.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]).write(to: docx)
        check("fixture docx", size(docx) > 1000)
        if let pdf = await tryConvert(docx, .pdf) { check("docx → pdf", PDFDocument(url: pdf)?.string?.contains("outside charges cancel") == true) }
        if let md = await tryConvert(docx, .md), let text = try? String(contentsOf: md, encoding: .utf8) {
            check("docx → markdown keeps heading and bold", text.contains("# Gauss's Law") && text.contains("**charge over epsilon**"), text.replacingOccurrences(of: "\n", with: "⏎"))
        } else { check("docx → markdown", false) }
        for t in [Converter.Target.odt, .rtf, .html, .txt] {
            if let u = await tryConvert(docx, t) { check("docx → \(t.ext)", ((try? Converter.readDocument(u).string) ?? "").contains("outside charges")) }
            else { check("docx → \(t.ext)", false) }
        }
        // A note to Word keeps its picture and its equation (NSAttributedString alone drops both).
        let pic = NSImage(size: NSSize(width: 60, height: 30), flipped: false) { r in NSColor.systemBlue.setFill(); r.fill(); return true }
        let withPics = NSMutableAttributedString(string: "Field: $E = \\frac{kq}{r^2}$ and a figure ", attributes: [.font: NSFont.systemFont(ofSize: 12)])
        let picAtt = NSTextAttachment(); picAtt.image = pic
        withPics.append(NSAttributedString(attachment: picAtt))
        withPics.append(NSAttributedString(string: " after it.\n", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        let wordOut = dir.appendingPathComponent("Pictures.docx")
        do {
            try DOCX.write(withPics, to: wordOut)
            let listing = shell("/usr/bin/unzip", ["-l", wordOut.path])
            let xml = shell("/usr/bin/unzip", ["-p", wordOut.path, "word/document.xml"])
            check("word: the equation and the picture are in the file", listing.contains("word/media/sb0.png") && listing.contains("word/media/sb1.png"))
            check("word: both drawn inline, no marker left", xml.components(separatedBy: "<w:drawing>").count == 3 && !xml.contains("\u{E000}"))
            check("word: document.xml is well-formed", (try? XMLDocument(xmlString: xml)) != nil)
            check("word: the text reads back", ((try? Converter.readDocument(wordOut).string) ?? "").contains("after it"))
        } catch { check("word with pictures", false, error.localizedDescription) }

        // An audio review: what the voice would read as symbols goes, then it's read into a file.
        check("audio review: marks, math signs and citations aren't read aloud",
              AudioReview.spoken("## Flux\n- **Flux** is $\\Phi$ [Notes, p. 3]\n1. Then `Gauss`") == "Flux\nFlux is Phi \nThen Gauss")
        // Paragraphs, several sentences each: the synthesizer pauses between stretches of a long
        // text, and stopping at the first pause made 12 s of a 10-minute review.
        struct Script: AIProvider {
            func complete(system: String, messages: [AIMessage]) async throws -> String {
                "## Review\n" + Array(repeating: String(repeating: "Electric flux is the field passing through a surface, and Gauss's law ties it to the charge inside. ", count: 4),
                                       count: 5).joined(separator: "\n\n")
            }
        }
        let review = dir.appendingPathComponent("Review.m4a")
        do {
            var steps: [String] = []
            try await AudioReview.make(from: [Note(title: "Week 3", body: "Flux and Gauss's law")], to: review,
                                       provider: Script(), mode: .openai) { steps.append($0) }
            let seconds = (try? AVAudioFile(forReading: review)).map { Double($0.length) / $0.fileFormat.sampleRate } ?? 0
            check("audio review: the whole script read into the file", seconds > 60 && steps == ["writing the script", "reading it aloud"],
                  "(\(Int(seconds)) s, voice: \(Converter.bestVoice()?.name ?? "none"))")
        } catch { check("audio review", false, error.localizedDescription) }

        let mdIn = dir.appendingPathComponent("Notes.md")
        try? "# Week 3\n\n- **Flux** — field through a surface\n\n| A | B |\n|---|---|\n| 1 | 2 |\n".write(to: mdIn, atomically: true, encoding: .utf8)
        if let u = await tryConvert(mdIn, .docx) {
            let back = (try? Converter.readDocument(u).string) ?? ""
            check("markdown → docx (no markup left)", back.contains("Flux") && !back.contains("**"))
        } else { check("markdown → docx", false) }
        if let u = await tryConvert(mdIn, .speech) {
            let secs = (try? AVAudioFile(forReading: u)).map { Double($0.length) / $0.fileFormat.sampleRate } ?? 0
            check("markdown → spoken audio", secs > 1, String(format: "(%.1f s)", secs))
        } else { check("markdown → speech", false) }

        // A three-page PDF with text, and a scanned one with none.
        let pdf3 = dir.appendingPathComponent("Three.pdf")
        let three = PDFDocument()
        for i in 1...3 {
            let img = textImage("Page \(i) electric flux", size: CGSize(width: 1275, height: 1650))
            if let p = PDFPage(image: NSImage(cgImage: img, size: .zero), options: [.mediaBox: CGRect(x: 0, y: 0, width: 612, height: 792)]) { three.insert(p, at: three.pageCount) }
        }
        three.write(to: pdf3)
        check("scanned fixture has no text layer", (PDFDocument(url: pdf3)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if let u = await tryConvert(pdf3, .searchablePDF) {
            let text = PDFDocument(url: u)?.string ?? ""
            check("scan → searchable PDF", text.localizedCaseInsensitiveContains("electric flux") && PDFDocument(url: u)?.pageCount == 3, "(\(text.prefix(40)))")
        } else { check("searchable PDF", false) }
        if let u = await tryConvert(pdf3, .docx) { check("scanned PDF → docx (read off the page)", ((try? Converter.readDocument(u).string) ?? "").localizedCaseInsensitiveContains("electric flux")) }
        else { check("pdf → docx", false) }
        if let folder = await tryConvert(pdf3, .png) {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            check("pdf → a PNG per page", files.count == 3, "\(files.sorted())")
        } else { check("pdf → png", false) }
        if let u = await tryConvert(pdf3, .slidesFromPDF) {
            let listing = shell("/usr/bin/unzip", ["-l", u.path])
            check("pdf → pptx has three slides", listing.contains("ppt/slides/slide3.xml") && !listing.contains("slide4.xml"))
            let ql = dir.appendingPathComponent("ql")
            try? FileManager.default.createDirectory(at: ql, withIntermediateDirectories: true)
            _ = shell("/usr/bin/qlmanage", ["-t", "-s", "400", "-o", ql.path, u.path])
            let thumbs = (try? FileManager.default.contentsOfDirectory(atPath: ql.path)) ?? []
            check("Quick Look opens the pptx", !thumbs.isEmpty, "\(thumbs)")
        } else { check("pdf → pptx", false) }
        let textSlides = dir.appendingPathComponent("Outline.pptx")
        do {
            try PPTX.write([.text(title: "Gauss's Law", bullets: ["Flux through a closed surface", "Q_enc / ε₀ & <symmetry>"])], title: "Outline", to: textSlides)
            let xml = shell("/usr/bin/unzip", ["-p", textSlides.path, "ppt/slides/slide1.xml"])
            check("text slide escapes XML", xml.contains("&amp; &lt;symmetry&gt;") && xml.contains("buChar"))
        } catch { check("text slides", false, error.localizedDescription) }

        // Which app does an exact conversion — a .pptx going to Pages is the bug this guards.
        func u(_ n: String) -> URL { dir.appendingPathComponent(n) }
        check("exact PDF of slides → Keynote", Converter.app(.pdfExact, for: u("a.pptx")) == .keynote)
        check("exact PDF of Word → Pages", Converter.app(.pdfExact, for: u("a.docx")) == .pages)
        check("any Excel conversion → Numbers", Converter.app(.csv, for: u("a.xlsx")) == .numbers)
        check("Word → Markdown stays in StudyBar", Converter.app(.md, for: u("a.docx")) == nil)

        // A note outlined as slides.
        let outline = PPTX.outline("# Gauss's Law\n## Flux\n- **Flux** is $\\Phi_E$\n- two\n- three\n- four\n- five\n- six\n- seven\n## Symmetry\n> 💡 **Added:** pick a surface\n| A | B |\n|---|---|\n| 1 | 2 |", title: "Note")
        let titles = outline.compactMap { if case .text(let t, _) = $0 { return t }; return nil }
        check("note → slides: title, sections, continuation", titles == ["Gauss's Law", "Flux", "Flux (cont.)", "Symmetry"], "\(titles)")
        if outline.count > 3, case .text(_, let b) = outline[3] { check("slide text has no Markdown marks; tables as rows", b == ["pick a surface", "A — B", "1 — 2"], "\(b)") }
        if outline.count > 1, case .text(_, let b) = outline[1] { check("bold and math marks gone", b.first == "Flux is Φ_E", "\(b.first ?? "")")
        check("LaTeX reads as symbols", PPTX.plain(#"$\oint \vec{E}\cdot d\vec{A} = \frac{Q}{\varepsilon_0}$, $r^2$, $\sqrt{2}$"#) == "∮ E· dA = Q/ε_0, r², √(2)",
              PPTX.plain(#"$\oint \vec{E}\cdot d\vec{A} = \frac{Q}{\varepsilon_0}$, $r^2$, $\sqrt{2}$"#)) }

        // PDF tools.
        let merged = dir.appendingPathComponent("Merged.pdf")
        try? Converter.merge([pdf3, pdf3], to: merged)
        check("merge", PDFDocument(url: merged)?.pageCount == 6)
        if let ex = try? Converter.extract(merged, pages: "2-3, 6") { check("extract pages 2-3, 6", PDFDocument(url: ex)?.pageCount == 3) } else { check("extract", false) }
        if let sp = try? Converter.split(pdf3) { check("split", ((try? FileManager.default.contentsOfDirectory(atPath: sp.path)) ?? []).count == 3) } else { check("split", false) }
        if let rot = try? Converter.rotate(pdf3) { check("rotate", PDFDocument(url: rot)?.page(at: 0)?.rotation == 90) } else { check("rotate", false) }
        check("page ranges", Converter.pages("1-3, 5, 8-", count: 9) == [1, 2, 3, 5, 8, 9] && Converter.pages("0, 12", count: 9).isEmpty)

        // A heavy scan gets smaller.
        let heavy = dir.appendingPathComponent("Heavy.pdf")
        let noisy = PDFDocument()
        for _ in 1...2 {
            let img = textImage("Noisy scan page", size: CGSize(width: 2550, height: 3300), noise: true)
            if let d = Converter.encode(img, type: .png, quality: 1), let src = CGImageSourceCreateWithData(d as CFData, nil),
               let back = CGImageSourceCreateImageAtIndex(src, 0, nil),
               let p = PDFPage(image: NSImage(cgImage: back, size: .zero), options: [.mediaBox: CGRect(x: 0, y: 0, width: 612, height: 792), .compressionQuality: 1.0]) {
                noisy.insert(p, at: noisy.pageCount)
            }
        }
        noisy.write(to: heavy)
        if let u = await tryConvert(heavy, .compressedPDF) {
            check("heavy scan → smaller PDF", size(u) < size(heavy), "(\(size(heavy) / 1024) KB → \(size(u) / 1024) KB)")
        } else { check("compress", false, "(\(size(heavy) / 1024) KB)") }

        // Images.
        let png = dir.appendingPathComponent("Photo.png")
        try? Converter.write(textImage("Mitochondria make ATP", size: CGSize(width: 1200, height: 400)), to: png, type: .png, quality: 1)
        for t in [Converter.Target.jpeg, .heic, .tiff, .gif] {
            if let u = await tryConvert(png, t) { check("png → \(t.ext)", Converter.cgImage(u)?.width == 1200) } else { check("png → \(t.ext)", false) }
        }
        if let u = await tryConvert(png, .ocrText) { check("image → text", ((try? String(contentsOf: u, encoding: .utf8)) ?? "").contains("Mitochondria")) } else { check("ocr", false) }
        let two = dir.appendingPathComponent("Two.pdf")
        try? Converter.imagesToPDF([png, png], to: two)
        check("images → one PDF", PDFDocument(url: two)?.pageCount == 2)
        let gif = dir.appendingPathComponent("Anim.gif")
        try? Converter.imagesToGIF([png, png, png], to: gif)
        check("images → animated GIF", CGImageSourceCreateWithURL(gif as CFURL, nil).map(CGImageSourceGetCount) == 3)
        if let f = try? Converter.frames(gif) { check("GIF → frames", ((try? FileManager.default.contentsOfDirectory(atPath: f.path)) ?? []).count == 3) } else { check("frames", false) }
        if #available(macOS 26, *) {
            let table = dir.appendingPathComponent("Table.png")
            try? Converter.write(tableImage(), to: table, type: .png, quality: 1)
            if let u = await tryConvert(table, .table) {
                let md = (try? String(contentsOf: u, encoding: .utf8)) ?? ""
                check("table photo → Markdown table", md.contains("|---|") && md.contains("Year") && md.contains("1080"), md.replacingOccurrences(of: "\n", with: "⏎"))
            } else { check("table photo → Markdown table", false) }
        }

        // Audio: a second of tone, both ways.
        let wav = dir.appendingPathComponent("Tone.wav")
        if let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
           let f = try? AVAudioFile(forWriting: wav, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16]),
           let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 44_100) {
            buf.frameLength = 44_100
            for i in 0..<44_100 { buf.floatChannelData![0][i] = 0.3 * sin(Float(i) * 0.0627) }
            try? f.write(from: buf)
        }
        for t in [Converter.Target.m4a, .aiff] {
            if let u = await tryConvert(wav, t), let f = try? AVAudioFile(forReading: u) {
                let secs = Double(f.length) / f.fileFormat.sampleRate
                check("wav → \(t.ext)", abs(secs - 1) < 0.1, String(format: "(%.2f s)", secs))
            } else { check("wav → \(t.ext)", false) }
        }

        // A web page: the article kept, the site around it dropped, then converted like any document.
        do {
            let para = String(repeating: "Electric flux through a closed surface equals the enclosed charge over epsilon zero. ", count: 4)
            let page = dir.appendingPathComponent("site.html")
            try? """
            <html><head><title>Gauss's law explained</title><script>var tracker = 'TRACKING-CODE';</script></head><body>
            <nav>SITE MENU Home About</nav><header>BANNER</header>
            <article><header><h1>Gauss's law explained</h1></header><p>\(para)</p><h2>Symmetry</h2><p>\(para)</p><img src="fig1.png"></article>
            <aside>SIDEBAR ADS</aside><footer>FOOTER Copyright</footer></body></html>
            """.write(to: page, atomically: true, encoding: .utf8)
            if let saved = try? await WebPage.fetch(page) {
                defer { try? FileManager.default.removeItem(at: saved) }
                let html = (try? String(contentsOf: saved, encoding: .utf8)) ?? ""
                check("web page: the article kept", html.contains("Electric flux through") && html.contains("<h2>Symmetry</h2>"))
                check("web page: menus, ads, footer and scripts dropped",
                      !["SITE MENU", "BANNER", "SIDEBAR ADS", "FOOTER", "TRACKING-CODE"].contains { html.contains($0) })
                check("web page: pictures keep a full address", html.contains("src=\"file://") && html.contains("fig1.png"))
                check("web page: what it becomes goes to Downloads", Converter.destination(for: saved, ext: "pdf").deletingLastPathComponent().lastPathComponent == "Downloads")
                if let md = try? await Converter.convert(saved, to: .md, in: dir).first, let text = try? String(contentsOf: md, encoding: .utf8) {
                    check("web page → Markdown", text.hasPrefix("# Gauss's law explained") && text.contains("## Symmetry"), String(text.prefix(80)))
                } else { check("web page → Markdown", false) }
            } else { check("web page: read", false) }
            check("web address: typed without https", WebPage.address("example.com/notes?id=3")?.absoluteString == "https://example.com/notes?id=3")
            check("web address: not words, not other schemes", WebPage.address("gauss law") == nil && WebPage.address("notes") == nil && WebPage.address("ftp://x.com") == nil)
        }

        print(fail == 0 ? "CONVERT SELFTEST: ALL PASS" : "CONVERT SELFTEST: \(fail) FAILED")
        return fail == 0 ? 0 : 1
    }

    private static func shell(_ path: String, _ args: [String]) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        try? p.run(); let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(data: d, encoding: .utf8) ?? ""
    }

    /// Black text on white — a page or a photo of one. `noise` adds grain, the way a scan has it.
    static func textImage(_ text: String, size: CGSize, noise: Bool = false) -> CGImage {
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(.white); ctx.fill(CGRect(origin: .zero, size: size))
        if noise {
            for _ in 0..<60_000 {
                ctx.setFillColor(CGColor(gray: .random(in: 0.7...1), alpha: 1))
                ctx.fill(CGRect(x: .random(in: 0..<size.width), y: .random(in: 0..<size.height), width: 3, height: 3))
            }
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        (text as NSString).draw(at: CGPoint(x: size.width * 0.08, y: size.height * 0.6),
                                withAttributes: [.font: NSFont.systemFont(ofSize: size.width / 22), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }

    /// A ruled table, as a photo of a handout would show one.
    static func tableImage() -> CGImage {
        let size = CGSize(width: 900, height: 360)
        let ctx = CGContext(data: nil, width: 900, height: 360, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(.white); ctx.fill(CGRect(origin: .zero, size: size))
        ctx.setStrokeColor(.black); ctx.setLineWidth(2)
        let rows = [["Year", "Total Due", "Payment"], ["0", "1000", "0"], ["1", "1080", "580"]]
        for r in 0...rows.count { ctx.move(to: CGPoint(x: 60, y: 300 - r * 80)); ctx.addLine(to: CGPoint(x: 840, y: 300 - r * 80)) }
        for c in 0...3 { ctx.move(to: CGPoint(x: 60 + c * 260, y: 300)); ctx.addLine(to: CGPoint(x: 60 + c * 260, y: 60)) }
        ctx.strokePath()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for (r, row) in rows.enumerated() {
            for (c, cell) in row.enumerated() {
                (cell as NSString).draw(at: CGPoint(x: 80 + c * 260, y: 245 - r * 80),
                                        withAttributes: [.font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.black])
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }
}
