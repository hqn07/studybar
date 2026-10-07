import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Image cards (benchmark 4.3): cover parts of a picture, a card for each

/// Image cards asked for from outside Flashcards — a screen grab, a slide, a board photo.
struct ImageCardsRequest: Identifiable, Equatable {
    let id = UUID()
    var image: CGImage? = nil
    var title = ""
    var deck: UUID? = nil
    var course: UUID? = nil
    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
}

/// A picture with its parts covered: the one asked about in orange with a "?", the rest grey
/// (or showing, when the card leaves them as context). Revealed, the asked part is outlined, so
/// the eye lands on the answer while the others stay covered.
struct OcclusionFace: View {
    let image: NSImage
    let occlusion: Occlusion
    var revealed = false

    var body: some View {
        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            .overlay {
                GeometryReader { g in
                    ForEach(Array(occlusion.boxes.enumerated()), id: \.offset) { i, b in
                        let r = CGRect(x: b.x * g.size.width, y: b.y * g.size.height, width: b.w * g.size.width, height: b.h * g.size.height)
                        if i == occlusion.ask {
                            if revealed {
                                RoundedRectangle(cornerRadius: 3).stroke(Color.orange, lineWidth: 2.5)
                                    .frame(width: r.width + 6, height: r.height + 6).position(x: r.midX, y: r.midY)
                            } else {
                                RoundedRectangle(cornerRadius: 3).fill(Color.orange)
                                    .overlay(Text("?").font(.system(size: max(9, min(r.height * 0.65, 26)), weight: .bold)).foregroundStyle(.white))
                                    .frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                            }
                        } else if occlusion.hideAll {
                            RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.6))
                                .frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                        }
                    }
                }
            }
            .accessibilityElement()
            .accessibilityLabel(revealed ? "Picture, with the part asked about outlined" : "Picture, with part \(occlusion.ask + 1) of \(occlusion.boxes.count) hidden")
    }
}

/// Where a picture comes from: a file, the clipboard, part of the screen — or, in the same menu,
/// "Take Photo" and "Scan Documents" from a nearby iPhone or iPad (Continuity Camera), which macOS
/// fills in itself for whichever devices it can reach.
struct PictureButton: NSViewRepresentable {
    var title: String
    var symbol = "photo.badge.plus"
    var prominent = false
    var onImage: (CGImage) -> Void

    func makeNSView(context: Context) -> PictureSourceButton {
        let b = PictureSourceButton(frame: .zero)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        b.imagePosition = .imageLeading
        b.bezelStyle = .push
        b.setAccessibilityLabel(title)
        update(b)
        return b
    }
    func updateNSView(_ b: PictureSourceButton, context: Context) { update(b) }
    private func update(_ b: PictureSourceButton) {
        b.title = " " + title          // the symbol otherwise touches the first letter
        b.onImage = onImage
        b.keyEquivalent = prominent ? "\r" : ""
        b.setContentHuggingPriority(.required, for: .horizontal)
    }
}

final class PictureSourceButton: NSButton, NSServicesMenuRequestor {
    var onImage: ((CGImage) -> Void)?

    override init(frame: NSRect) { super.init(frame: frame); target = self; action = #selector(showMenu) }
    required init?(coder: NSCoder) { super.init(coder: coder); target = self; action = #selector(showMenu) }
    override var acceptsFirstResponder: Bool { true }

    @objc private func showMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func item(_ t: String, _ sel: Selector, enabled: Bool = true) {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: ""); i.target = self; i.isEnabled = enabled; menu.addItem(i)
        }
        item("Choose a Picture…", #selector(choose))
        item("Paste Picture", #selector(paste), enabled: NSImage.canInit(with: .general))
        item("Capture Part of the Screen", #selector(capture))
        menu.addItem(.separator())
        // Continuity Camera: AppKit puts the nearby devices' Take Photo / Scan Documents here,
        // and hands the picture to `readSelection` — this button is the requestor.
        let device = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        device.identifier = NSMenuItem.importFromDeviceIdentifier
        menu.addItem(device)
        window?.makeFirstResponder(self)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: isFlipped ? bounds.maxY + 4 : -4), in: self)
    }

    @objc private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf]
        panel.prompt = "Use Picture"
        guard panel.runModal() == .OK, let url = panel.url, let cg = Self.picture(at: url) else { return }
        onImage?(cg)
    }
    @objc private func paste() {
        if let img = NSImage(pasteboard: .general), let cg = ImageCards.cgImage(img) { onImage?(cg) }
    }
    @objc private func capture() {
        Task { @MainActor in if let cg = await ScreenGrab.capture() { onImage?(cg) } }
    }

    /// A picture file, or a PDF's first page drawn at twice its size.
    static func picture(at url: URL) -> CGImage? {
        if url.pathExtension.lowercased() == "pdf" {
            guard let doc = CGPDFDocument(url as CFURL), let page = doc.page(at: 1) else { return nil }
            let box = page.getBoxRect(.cropBox)
            guard let ctx = CGContext(data: nil, width: Int(box.width * 2), height: Int(box.height * 2), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: box.width * 2, height: box.height * 2))
            ctx.scaleBy(x: 2, y: 2); ctx.translateBy(x: -box.minX, y: -box.minY)
            ctx.drawPDFPage(page)
            return ctx.makeImage()
        }
        return NSImage(contentsOf: url).flatMap(ImageCards.cgImage)
    }

    // NSServicesMenuRequestor — what Continuity Camera delivers.
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if let returnType, NSImage.imageTypes.contains(returnType.rawValue) { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }
    func readSelection(from pboard: NSPasteboard) -> Bool {
        guard let img = NSImage(pasteboard: pboard), let cg = ImageCards.cgImage(img) else { return false }
        onImage?(cg)
        return true
    }
    func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool { false }
}

/// Make image cards: a picture, its parts covered by dragging over them — or every label it
/// has, read off it in one click — each part a card that asks what's under it.
struct OcclusionEditor: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let request: ImageCardsRequest

    struct Part: Identifiable, Equatable { let id = UUID(); var box: OcclusionBox; var label = "" }

    @State private var image: CGImage?
    @State private var title: String
    @State private var parts: [Part] = []
    @State private var selected: UUID?
    @State private var drawing: CGRect?
    @State private var reading = false
    @State private var readNothing = false
    @State private var dropping = false
    @State private var deck: UUID?
    @AppStorage("occlusionHideAll") private var hideAll = true
    /// The picture takes the keyboard when a part is picked or drawn, so Delete removes it.
    @FocusState private var canvasFocused: Bool

    init(request: ImageCardsRequest, parts: [Part] = []) {
        self.request = request
        _parts = State(initialValue: parts)
        _image = State(initialValue: request.image)
        _title = State(initialValue: request.title)
        _deck = State(initialValue: request.deck)
    }

    private var course: UUID? { request.course ?? state.likelyCourseID }
    private var newDeckName: String { state.course(course).map { $0.code.isEmpty ? $0.name : $0.code } ?? "Image cards" }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Image cards").font(.headline)
                Spacer()
                if image != nil {
                    PictureButton(title: "Another Picture", symbol: "photo.on.rectangle") { use($0) }.fixedSize()
                }
            }.padding(14)
            Divider()
            if let image { editor(image) } else { pickPrompt }
            Divider()
            footer
        }
        .frame(minWidth: 760, idealWidth: 880, minHeight: 560, idealHeight: 640)
        .onAppear {
            if deck == nil { deck = state.data.decks.first { course != nil && $0.courseID == course }?.id }
        }
    }

    private func use(_ cg: CGImage) { image = cg; parts = []; selected = nil; readNothing = false }

    // MARK: No picture yet

    private var pickPrompt: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 40)).foregroundStyle(.tint)
            Text("A picture to learn from").font(.title3.weight(.semibold))
            Text("A labelled diagram, a map, a slide, a photo of the board. Cover the parts you want to learn — each one becomes a card that asks what's under it.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            PictureButton(title: "Choose a Picture", prominent: true) { use($0) }.fixedSize()
            Text("Or drop one here — from Finder, Preview or a web page. The menu also takes a photo with your iPhone.")
                .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dropping ? Color.accentColor.opacity(0.08) : .clear)
        .onDrop(of: [.image, .fileURL], isTargeted: $dropping) { drop($0) }
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard let p = providers.first else { return false }
        if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url, let cg = PictureSourceButton.picture(at: url) else { return }
                DispatchQueue.main.async { use(cg) }
            }
            return true
        }
        _ = p.loadObject(ofClass: NSImage.self) { img, _ in
            guard let img = img as? NSImage, let cg = ImageCards.cgImage(img) else { return }
            DispatchQueue.main.async { use(cg) }
        }
        return true
    }

    // MARK: Covering parts

    private func editor(_ cg: CGImage) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Button { coverLabels(cg) } label: {
                        Label(reading ? "Reading the labels…" : "Cover the Labels", systemImage: "text.viewfinder")
                    }
                    .disabled(reading)
                    .help("Find the words on the picture and cover each one — its text becomes the answer")
                    .modifier(Prominent(on: parts.isEmpty))
                    if !parts.isEmpty {
                        Button("Uncover All") { parts = []; selected = nil }.buttonStyle(.borderless)
                    }
                    Spacer()
                    Text(readNothing ? "No words found on it — drag over the parts instead." : "Drag over a part to cover it. Click one to select it; Delete removes it.")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                canvas(cg)
            }
            .padding(12)
            Divider()
            partsList.frame(width: 260)
        }
    }

    private func canvas(_ cg: CGImage) -> some View {
        GeometryReader { g in
            let fit = Self.fit(CGSize(width: cg.width, height: cg.height), in: g.size)
            ZStack(alignment: .topLeading) {
                Image(decorative: cg, scale: 1).resizable()
                    .frame(width: fit.width, height: fit.height).offset(x: fit.minX, y: fit.minY)
                ForEach(Array(parts.enumerated()), id: \.element.id) { i, p in
                    let r = Self.place(p.box.rect, in: fit)
                    // See-through while making, so you can check what's under each; numbered at the corner.
                    RoundedRectangle(cornerRadius: 3).fill(Color.orange.opacity(selected == p.id ? 0.6 : 0.4))
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(selected == p.id ? Color.primary : .orange, lineWidth: selected == p.id ? 2 : 1.5))
                        .overlay(alignment: .topLeading) {
                            Text("\(i + 1)").font(.system(size: 10, weight: .bold).monospacedDigit()).foregroundStyle(.white)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Color.orange, in: Capsule()).offset(x: -6, y: -8)
                        }
                        .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                        .onTapGesture { selected = p.id; canvasFocused = true }
                        .accessibilityLabel("Part \(i + 1)\(p.label.isEmpty ? "" : ", \(p.label)")")
                }
                if let d = drawing {
                    let r = Self.place(d, in: fit)
                    Rectangle().stroke(Color.orange, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                        .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                }
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 4).onChanged { v in
                drawing = Self.unplace(CGRect(x: min(v.startLocation.x, v.location.x), y: min(v.startLocation.y, v.location.y),
                                              width: abs(v.location.x - v.startLocation.x), height: abs(v.location.y - v.startLocation.y)), in: fit)
            }.onEnded { _ in
                if let d = drawing, d.width * fit.width >= 6, d.height * fit.height >= 6 {
                    let p = Part(box: OcclusionBox(d)); parts.append(p); selected = p.id; canvasFocused = true
                }
                drawing = nil
            })
        }
        .focusable()
        .focused($canvasFocused)
        .focusEffectDisabled()
        .onDeleteCommand { removeSelected() }
    }

    private var partsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(parts.isEmpty ? "Parts" : "\(parts.count) part\(parts.count == 1 ? "" : "s") — what each one is")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(12)
            if parts.isEmpty {
                Text("Nothing covered yet.").font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 12)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(Array(parts.indices), id: \.self) { i in
                                HStack(spacing: 6) {
                                    Text("\(i + 1)").font(.caption.bold().monospacedDigit()).foregroundStyle(.white)
                                        .frame(width: 22, height: 18).background(Color.orange, in: RoundedRectangle(cornerRadius: 4))
                                    TextField("What it is", text: $parts[i].label).textFieldStyle(.roundedBorder)
                                    Button { parts.remove(at: i); selected = nil } label: { Image(systemName: "xmark.circle.fill") }
                                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Uncover part \(i + 1)")
                                }
                                .padding(4)
                                .background(selected == parts[i].id ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .id(parts[i].id)
                                .onTapGesture { selected = parts[i].id }
                            }
                        }.padding(.horizontal, 8).padding(.bottom, 8)
                    }
                    .onChange(of: selected) { _, id in if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } } }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            TextField("Name it — e.g. The heart", text: $title).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
            Picker("Deck", selection: $deck) {
                Text("New deck: \(newDeckName)").tag(UUID?.none)
                ForEach(state.data.decks) { Text($0.name.isEmpty ? "Deck" : $0.name).tag(Optional($0.id)) }
            }.fixedSize()
            Toggle("Cover every part on each card", isOn: $hideAll).toggleStyle(.checkbox).font(.caption).fixedSize()
                .help("On: the other parts stay covered, so their labels can't give the answer away. Off: they show, as context.")
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(parts.isEmpty ? "Add Cards" : "Add \(parts.count) Card\(parts.count == 1 ? "" : "s")") { add() }
                .buttonStyle(.borderedProminent).disabled(image == nil || parts.isEmpty)
        }.padding(12)
    }

    // MARK: Actions

    private func coverLabels(_ cg: CGImage) {
        reading = true; readNothing = false
        Task {
            let found = await ImageCards.labels(in: cg)
            reading = false
            readNothing = found.isEmpty
            // Reading order, and never on top of a part already covered.
            let fresh = found.filter { f in !parts.contains { $0.box.rect.intersects(f.box.rect) } }
                .sorted { abs($0.box.y - $1.box.y) > 0.02 ? $0.box.y < $1.box.y : $0.box.x < $1.box.x }
            parts += fresh.map { Part(box: $0.box, label: $0.text) }
        }
    }

    private func removeSelected() {
        guard let s = selected else { return }
        parts.removeAll { $0.id == s }; selected = nil
    }

    private func add() {
        guard let cg = image, !parts.isEmpty, let jpeg = ImageCards.jpeg(cg) else { return }
        let stored = CardImage(jpeg: jpeg)
        let n = parts.count
        let target = state.data.decks.first { $0.id == deck }
        state.withUndo("Added \(n) image card\(n == 1 ? "" : "s") to \(target?.name ?? newDeckName)") {
            let d: Deck
            if let target { d = target } else { d = Deck(name: newDeckName, courseID: course); state.data.decks.append(d) }
            state.data.cardImages = (state.data.cardImages ?? []) + [stored]
            state.data.flashcards += ImageCards.cards(title: title, imageID: stored.id, boxes: parts.map(\.box),
                                                      labels: parts.map(\.label), hideAll: hideAll, deckID: d.id)
        }
        dismiss()
    }

    // MARK: Geometry — parts are kept in fractions of the picture

    static func fit(_ size: CGSize, in space: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let s = min(space.width / size.width, space.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: (space.width - w) / 2, y: (space.height - h) / 2, width: w, height: h)
    }
    static func place(_ r: CGRect, in fit: CGRect) -> CGRect {
        CGRect(x: fit.minX + r.minX * fit.width, y: fit.minY + r.minY * fit.height, width: r.width * fit.width, height: r.height * fit.height)
    }
    static func unplace(_ r: CGRect, in fit: CGRect) -> CGRect {
        guard fit.width > 0, fit.height > 0 else { return .zero }
        let n = CGRect(x: (r.minX - fit.minX) / fit.width, y: (r.minY - fit.minY) / fit.height,
                       width: r.width / fit.width, height: r.height / fit.height)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return n.isNull ? .zero : n
    }
}

private struct Prominent: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
    }
}
