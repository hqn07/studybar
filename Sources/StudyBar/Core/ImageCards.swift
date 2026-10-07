import AppKit
import ImageIO
import UniformTypeIdentifiers
import Vision

// MARK: - Image occlusion (benchmark 4.3)

/// One part of a picture to hide, in fractions of the picture's width and height from its top-left.
struct OcclusionBox: Codable, Hashable {
    var x: Double, y: Double, w: Double, h: Double

    init(_ r: CGRect) {
        let r = r.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        x = r.isNull ? 0 : r.minX; y = r.isNull ? 0 : r.minY
        w = r.isNull ? 0 : r.width; h = r.isNull ? 0 : r.height
    }
    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

/// A card that hides one part of a picture — a diagram's label, a region of a map — and asks
/// what it is: the picture, every part marked on it (all covered, so no label gives another
/// away), and the one this card asks about.
struct Occlusion: Codable, Hashable {
    var imageID: UUID
    var boxes: [OcclusionBox]
    var ask: Int
}

/// A picture image cards are made from, once however many cards hide parts of it. In the store,
/// not a folder beside it, so it syncs, backs up, and comes back from the Trash with its cards.
struct CardImage: Identifiable, Codable, Equatable {
    var id = UUID()
    var jpeg: Data
}

enum ImageCards {
    /// Long side of a stored picture: a full-page diagram stays legible, at ~150–300 KB.
    static let maxSide = 1600

    /// The picture drawn on white, at most `maxSide` on its long side. Transparent pixels read
    /// as black — to a JPEG, and to Vision, which then sees black labels on black.
    static func flattened(_ cg: CGImage, maxSide: Int = maxSide) -> CGImage? {
        let scale = min(1, Double(maxSide) / Double(max(cg.width, cg.height)))
        let w = max(1, Int((Double(cg.width) * scale).rounded())), h = max(1, Int((Double(cg.height) * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// A picture as it's stored: flattened, at JPEG quality 0.8.
    static func jpeg(_ cg: CGImage, maxSide: Int = maxSide) -> Data? {
        guard let out = flattened(cg, maxSide: maxSide) else { return nil }
        let data = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, out, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(dst) ? data as Data : nil
    }

    static func cgImage(_ image: NSImage) -> CGImage? {
        var r = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &r, context: nil, hints: nil)
    }

    private static let cache = NSCache<NSUUID, NSImage>()
    /// The stored picture, decoded once.
    static func image(_ id: UUID, in data: AppData) -> NSImage? {
        if let hit = cache.object(forKey: id as NSUUID) { return hit }
        guard let stored = data.cardImages?.first(where: { $0.id == id }), let img = NSImage(data: stored.jpeg) else { return nil }
        cache.setObject(img, forKey: id as NSUUID)
        return img
    }

    /// One card per part, all on the same picture. The front names the picture and which part,
    /// never the answer; the back is the part's label (or its number, when it has none).
    static func cards(title: String, imageID: UUID, boxes: [OcclusionBox], labels: [String], deckID: UUID) -> [Flashcard] {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines), name = t.isEmpty ? "Picture" : t
        // ponytail: every card repeats its picture's boxes (n² for n parts, ~70 KB at 30 parts);
        // move them onto CardImage if 50-part pictures make the store heavy.
        return boxes.indices.map { i in
            let label = i < labels.count ? labels[i].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            var card = Flashcard(deckID: deckID, front: "🖼 \(name) — part \(i + 1) of \(boxes.count)",
                                 back: label.isEmpty ? "Part \(i + 1)" : label)
            card.occlusion = Occlusion(imageID: imageID, boxes: boxes, ask: i)
            return card
        }
    }

    /// The text in a picture — a diagram's labels — as parts to hide, each with what it says,
    /// so a labelled figure becomes cards in one step. Vision, on the device.
    static func labels(in cg: CGImage) async -> [(box: OcclusionBox, text: String)] {
        await Task.detached(priority: .userInitiated) {
            guard let cg = flattened(cg) else { return [] }
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = false        // labels are terms, not sentences
            try? VNImageRequestHandler(cgImage: cg).perform([req])
            return (req.results ?? []).prefix(80).compactMap { o -> (box: OcclusionBox, text: String)? in
                guard let top = o.topCandidates(1).first, top.confidence >= 0.3 else { return nil }
                let text = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.contains(where: \.isLetter) || text.contains(where: \.isNumber) else { return nil }
                // Vision's box is bottom-left based; padded so the cover hides the whole word.
                let b = o.boundingBox
                let r = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
                    .insetBy(dx: -0.006, dy: -(b.height * 0.25 + 0.004))
                return (OcclusionBox(r), text)
            }
        }.value
    }

    /// The pictures still in use — by a card, or by a card in the Trash, so putting it back
    /// brings its picture. Nil when none are left.
    static func inUse(_ d: AppData) -> [CardImage]? {
        guard let images = d.cardImages else { return nil }
        var used = Set(d.flashcards.compactMap { $0.occlusion?.imageID })
        for t in d.trash ?? [] where t.collection == "flashcards" {
            if let id = (try? JSONDecoder.studybar.decode(Flashcard.self, from: t.payload))?.occlusion?.imageID { used.insert(id) }
        }
        let kept = images.filter { used.contains($0.id) }
        return kept.isEmpty ? nil : kept
    }
}

// MARK: - Self-test (StudyBar --imagecards-selftest)

@MainActor
enum ImageCardsSelfTest {
    /// A labelled diagram, drawn — and where each label is, as the parts to cover.
    static func diagram() -> (image: CGImage, labels: [(box: OcclusionBox, text: String)])? {
        let size = NSSize(width: 1200, height: 800)
        let labels: [(String, NSPoint, NSPoint)] = [("Right atrium", NSPoint(x: 60, y: 210), NSPoint(x: 470, y: 300)),
                                                    ("Left atrium", NSPoint(x: 900, y: 190), NSPoint(x: 720, y: 290)),
                                                    ("Right ventricle", NSPoint(x: 40, y: 560), NSPoint(x: 500, y: 500)),
                                                    ("Left ventricle", NSPoint(x: 880, y: 600), NSPoint(x: 700, y: 540)),
                                                    ("Aorta", NSPoint(x: 700, y: 50), NSPoint(x: 640, y: 160))]
        let font = NSFont.systemFont(ofSize: 34, weight: .medium)
        var boxes: [(box: OcclusionBox, text: String)] = []
        let pic = NSImage(size: size, flipped: true) { _ in
            NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
            NSColor(calibratedRed: 0.85, green: 0.3, blue: 0.32, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 420, y: 220, width: 380, height: 420)).fill()
            NSColor(calibratedRed: 0.75, green: 0.2, blue: 0.25, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 600, y: 110, width: 80, height: 180), xRadius: 30, yRadius: 30).fill()
            for (text, at, to) in labels {
                let sz = (text as NSString).size(withAttributes: [.font: font])
                NSColor.darkGray.setStroke()
                let line = NSBezierPath(); line.move(to: NSPoint(x: at.x < 600 ? at.x + sz.width + 6 : at.x - 6, y: at.y + sz.height / 2)); line.line(to: to); line.lineWidth = 2; line.stroke()
                (text as NSString).draw(at: at, withAttributes: [.font: font, .foregroundColor: NSColor.black])
            }
            return true
        }
        for (text, at, _) in labels {
            let sz = (text as NSString).size(withAttributes: [.font: font])
            boxes.append((OcclusionBox(CGRect(x: (at.x - 6) / size.width, y: (at.y - 4) / size.height,
                                              width: (sz.width + 12) / size.width, height: (sz.height + 8) / size.height)), text))
        }
        return ImageCards.cgImage(pic).map { ($0, boxes) }
    }

    static func run() async -> Int32 {
        var fail = 0
        func check(_ n: String, _ ok: Bool, _ d: String = "") { print("  \(ok ? "ok  " : "FAIL") \(n) \(d)"); if !ok { fail += 1 } }

        // A labelled diagram, drawn: two words at known places on a transparent canvas.
        let size = NSSize(width: 2400, height: 1200)
        let pic = NSImage(size: size, flipped: true) { _ in
            NSColor.systemRed.setFill(); NSBezierPath(ovalIn: NSRect(x: 900, y: 300, width: 600, height: 600)).fill()
            let font = NSFont.systemFont(ofSize: 72, weight: .medium)
            ("Left ventricle" as NSString).draw(at: NSPoint(x: 120, y: 160), withAttributes: [.font: font, .foregroundColor: NSColor.black])
            ("Aorta" as NSString).draw(at: NSPoint(x: 1800, y: 900), withAttributes: [.font: font, .foregroundColor: NSColor.black])
            return true
        }
        guard let cg = ImageCards.cgImage(pic) else { check("draws the test picture", false); return 1 }

        // Stored small, on white.
        if let data = ImageCards.jpeg(cg), let back = NSBitmapImageRep(data: data) {
            check("stored at most 1600 px on its long side", back.pixelsWide == 1600 && back.pixelsHigh == 800, "\(back.pixelsWide)×\(back.pixelsHigh)")
            let corner = back.colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB)
            check("transparent becomes white, not black", (corner?.brightnessComponent ?? 0) > 0.95, "\(String(describing: corner))")
            check("small enough to keep in the store", data.count < 400_000, "\(data.count) bytes")
        } else { check("encodes as JPEG", false) }

        // Its labels found where they are.
        let found = await ImageCards.labels(in: cg)
        let lv = found.first { $0.text.localizedCaseInsensitiveContains("ventricle") }
        let ao = found.first { $0.text.localizedCaseInsensitiveContains("aorta") }
        check("finds both labels", lv != nil && ao != nil, found.map(\.text).description)
        if let lv { check("a label's box covers it (top-left based)", lv.box.rect.contains(CGPoint(x: 0.15, y: 0.17)) && lv.box.y < 0.2, "\(lv.box)") }
        if let ao { check("the other is bottom-right", ao.box.x > 0.7 && ao.box.y > 0.7, "\(ao.box)") }

        // One card per part; the front never gives the answer away.
        let deck = UUID(), img = UUID()
        let boxes = [OcclusionBox(CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1)), OcclusionBox(CGRect(x: 0.7, y: 0.7, width: 0.2, height: 0.1)),
                     OcclusionBox(CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1))]
        let cards = ImageCards.cards(title: " Heart ", imageID: img, boxes: boxes, labels: ["Left ventricle", "Aorta"], deckID: deck)
        check("a card per part", cards.count == 3 && cards.map { $0.occlusion?.ask } == [0, 1, 2])
        check("the back is the label, or its number", cards.map(\.back) == ["Left ventricle", "Aorta", "Part 3"], cards.map(\.back).description)
        check("the front names the picture, not the answer", cards[0].front == "🖼 Heart — part 1 of 3" && !cards.contains { $0.front.contains($0.back) })
        check("parts kept in place", cards[1].occlusion?.boxes == boxes)

        // Old cards still decode; new ones round-trip.
        let old = #"{"id":"\#(UUID().uuidString)","deckID":"\#(deck.uuidString)","front":"Q","back":"A","tags":[],"ease":2.5,"interval":0,"reps":0,"due":"2026-10-01T00:00:00Z","reviews":0,"lapses":0,"stability":0,"difficulty":0}"#
        check("a card from before decodes", (try? JSONDecoder.studybar.decode(Flashcard.self, from: Data(old.utf8)))?.occlusion == nil
              && (try? JSONDecoder.studybar.decode(Flashcard.self, from: Data(old.utf8))) != nil)
        let round = try? JSONDecoder.studybar.decode(Flashcard.self, from: JSONEncoder.studybar.encode(cards[2]))
        check("an image card round-trips", round?.occlusion == cards[2].occlusion && round?.front == cards[2].front && round?.back == cards[2].back)

        // Pictures nothing uses are dropped — but not one a card in the Trash still needs.
        var d = AppData()
        let used = CardImage(jpeg: Data([1])), trashed = CardImage(jpeg: Data([2])), unused = CardImage(jpeg: Data([3]))
        d.cardImages = [used, trashed, unused]
        var c1 = cards[0]; c1.occlusion?.imageID = used.id
        var c2 = cards[1]; c2.occlusion?.imageID = trashed.id
        d.flashcards = [c1]
        d.trash = [TrashedItem(collection: "flashcards", itemID: c2.id, label: "Card", symbol: "rectangle", payload: try! JSONEncoder.studybar.encode(c2))]
        check("unused pictures dropped, trashed cards' kept", ImageCards.inUse(d)?.map(\.id) == [used.id, trashed.id])
        d.flashcards = []; d.trash = nil
        check("none left → nil", ImageCards.inUse(d) == nil)

        // A picture added on the other Mac arrives with its cards.
        var mine = AppData(), theirs = AppData()
        theirs.cardImages = [used]; theirs.flashcards = [c1]
        let merged = AppData.merged(base: AppData(), mine: mine, theirs: theirs)
        check("merge keeps a picture from the other side", merged.cardImages?.map(\.id) == [used.id] && merged.flashcards.count == 1)
        mine.cardImages = [used]
        check("…and doesn't double it", AppData.merged(base: AppData(), mine: mine, theirs: theirs).cardImages?.count == 1)

        print(fail == 0 ? "imagecards: all passed" : "imagecards: \(fail) failed")
        return fail == 0 ? 0 : 1
    }
}
