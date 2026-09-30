import AppKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers

// MARK: - The Shelf: a box to carry things between apps and modules

/// Something parked on the Shelf. Files are kept by bookmark, so one renamed or moved while it
/// waits is still found; a dropped image with no file behind it is saved to App Support first.
struct ShelfItem: Identifiable, Codable, Hashable {
    enum Kind: String, Codable { case file, link, text }
    var id = UUID()
    var kind: Kind
    var name: String
    var bookmark: Data?                  // .file
    var value = ""                       // .link: the URL · .text: the text
}

@MainActor
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()
    @Published private(set) var items: [ShelfItem] = [] { didSet { save() } }

    private init() {
        if let d = UserDefaults.standard.data(forKey: "shelfItems"),
           let saved = try? JSONDecoder().decode([ShelfItem].self, from: d) { items = saved }
    }
    private func save() {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: "shelfItems") }
    }

    static var imageDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StudyBar/Shelf", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func url(_ item: ShelfItem) -> URL? {
        guard let b = item.bookmark else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: b, bookmarkDataIsStale: &stale)
    }

    func addFile(_ url: URL) {
        guard !items.contains(where: { $0.kind == .file && self.url($0) == url }),
              let b = try? url.bookmarkData() else { return }
        items.append(ShelfItem(kind: .file, name: url.lastPathComponent, bookmark: b))
    }
    func addLink(_ url: URL) {
        guard !items.contains(where: { $0.kind == .link && $0.value == url.absoluteString }) else { return }
        items.append(ShelfItem(kind: .link, name: url.host ?? url.absoluteString, value: url.absoluteString))
    }
    func addText(_ s: String) {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        items.append(ShelfItem(kind: .text, name: String(t.prefix(60)), value: t))
    }
    func addImage(_ image: NSImage) {
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let url = Self.imageDir.appendingPathComponent("Image \(Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))).png"
            .replacingOccurrences(of: ":", with: "."))
        guard (try? png.write(to: url)) != nil else { return }
        addFile(url)
    }

    /// Everything a drag carries, in order of what it most is: files, then links, then an
    /// image with no file, then text. Returns whether anything was taken.
    @discardableResult
    func add(from pb: NSPasteboard) -> Bool {
        let before = items.count
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
        for u in urls { u.isFileURL ? addFile(u) : addLink(u) }
        if urls.isEmpty {
            if let img = NSImage(pasteboard: pb), pb.availableType(from: [.tiff, .png]) != nil { addImage(img) }
            else if let s = pb.string(forType: .string) {
                if let u = URL(string: s), u.scheme?.hasPrefix("http") == true { addLink(u) } else { addText(s) }
            }
        }
        return items.count > before
    }

    func remove(_ item: ShelfItem) { items.removeAll { $0.id == item.id } }
    func clear() { items.removeAll() }

    /// What dragging the item out hands over.
    func provider(_ item: ShelfItem) -> NSItemProvider {
        switch item.kind {
        case .file: return url(item).flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider()
        case .link: return URL(string: item.value).map { NSItemProvider(object: $0 as NSURL) } ?? NSItemProvider(object: item.value as NSString)
        case .text: return NSItemProvider(object: item.value as NSString)
        }
    }
}

// MARK: - The panel

/// A small floating panel under the menu bar. It stays over other apps while you drag things
/// in and out, and doesn't take focus from the app you're working in.
@MainActor
final class ShelfPanel: NSPanel, QLPreviewPanelDataSource {
    static var shared: ShelfPanel?
    var previewURLs: [URL] = []

    static func show() {
        if shared == nil {
            let p = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 360),
                               styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow, .fullSizeContentView],
                               backing: .buffered, defer: false)
            p.title = "Shelf"
            p.titlebarAppearsTransparent = true
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.becomesKeyOnlyIfNeeded = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: ShelfView(store: .shared))
            p.setFrameAutosaveName("StudyBarShelf")
            if !p.setFrameUsingName("StudyBarShelf"), let vis = NSScreen.main?.visibleFrame {
                p.setFrameTopLeftPoint(NSPoint(x: vis.maxX - 300, y: vis.maxY - 12))
            }
            shared = p
        }
        shared?.orderFrontRegardless()
    }
    static func toggle() { if shared?.isVisible == true { shared?.orderOut(nil) } else { show() } }

    override var canBecomeKey: Bool { true }

    // Quick Look, from the spacebar or the menu.
    func quickLook(_ urls: [URL]) {
        previewURLs = urls
        guard let ql = QLPreviewPanel.shared() else { return }
        makeKey()
        if ql.isVisible { ql.reloadData() } else { ql.makeKeyAndOrderFront(nil) }
    }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self; panel.reloadData() }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil }
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { previewURLs.count }
    }
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { previewURLs[index] as NSURL }
    }
}

private struct ShelfView: View {
    @ObservedObject var store: ShelfStore
    @State private var selected: UUID?
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Shelf").font(.headline)
                if !store.items.isEmpty { Text("\(store.items.count)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if store.items.contains(where: { $0.kind == .file }) {
                    Button("Convert") { ConvertQueue.shared.open(store.items.compactMap(store.url)) }
                        .buttonStyle(.borderless).font(.caption).help("Open the Shelf's files in Convert")
                }
                if !store.items.isEmpty { Button("Clear") { store.clear() }.buttonStyle(.borderless).font(.caption) }
            }
            .padding(.horizontal, 12).padding(.top, 26).padding(.bottom, 6)
            Divider()
            if store.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Drop files, links, text or images here — or on StudyBar's menu-bar icon — then drag them out wherever they're going.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 2) { ForEach(store.items) { row($0) } }.padding(6)
                }
            }
        }
        .background(targeted ? Color.accentColor.opacity(0.1) : Color.clear)
        .onDrop(of: [.fileURL, .url, .image, .plainText], isTargeted: $targeted) { providers in
            store.add(from: NSPasteboard(name: .drag))
            return !providers.isEmpty
        }
        .onKeyPress(.space) {
            guard let id = selected, let item = store.items.first(where: { $0.id == id }), let url = store.url(item) else { return .ignored }
            ShelfPanel.shared?.quickLook([url]); return .handled
        }
        .onKeyPress(.delete) {
            guard let id = selected, let item = store.items.first(where: { $0.id == id }) else { return .ignored }
            store.remove(item); return .handled
        }
        .focusable()
        .focusEffectDisabled()
    }

    private func row(_ item: ShelfItem) -> some View {
        HStack(spacing: 8) {
            icon(item).frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.name).font(.callout).lineLimit(1).truncationMode(.middle)
                if item.kind != .file { Text(item.kind == .link ? item.value : "Text").font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
            Button { store.remove(item) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).opacity(selected == item.id ? 1 : 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(selected == item.id ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(item) }
        .onTapGesture { selected = item.id }
        .onDrag { store.provider(item) }
        .contextMenu {
            Button("Open") { open(item) }
            if item.kind == .file, let url = store.url(item) {
                Button("Quick Look") { ShelfPanel.shared?.quickLook([url]) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Convert…") { ConvertQueue.shared.open([url]) }
                Button("Share…") { share(url) }
            }
            if item.kind != .file {
                Button("Copy") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.value, forType: .string)
                }
            }
            Divider()
            Button("Remove", role: .destructive) { store.remove(item) }
        }
    }

    @ViewBuilder private func icon(_ item: ShelfItem) -> some View {
        switch item.kind {
        case .file:
            if let url = store.url(item) { Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable() }
            else { Image(systemName: "questionmark.folder").foregroundStyle(.secondary) }
        case .link: Image(systemName: "link").foregroundStyle(.tint)
        case .text: Image(systemName: "text.alignleft").foregroundStyle(.secondary)
        }
    }

    private func open(_ item: ShelfItem) {
        switch item.kind {
        case .file: if let url = store.url(item) { NSWorkspace.shared.open(url) }
        case .link: if let url = URL(string: item.value) { NSWorkspace.shared.open(url) }
        case .text: NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.value, forType: .string)
        }
    }

    private func share(_ url: URL) {
        guard let view = ShelfPanel.shared?.contentView else { return }
        NSSharingServicePicker(items: [url]).show(relativeTo: .zero, of: view, preferredEdge: .minY)
    }
}
