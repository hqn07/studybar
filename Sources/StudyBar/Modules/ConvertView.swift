import SwiftUI
import UniformTypeIdentifiers

/// Files waiting to be converted — filled by drops, the Finder's "Convert with StudyBar"
/// service and the Shelf, even before the Convert module is on screen.
@MainActor
final class ConvertQueue: ObservableObject {
    static let shared = ConvertQueue()
    @Published var files: [URL] = []

    func add(_ urls: [URL]) {
        for u in urls where Converter.kind(u) != nil && !files.contains(u) { files.append(u) }
    }

    /// Hand files over and open the Convert module.
    func open(_ urls: [URL]) {
        add(urls)
        AppState.current?.selectedModuleID = "convert"
        WindowOpener.open?("main")
    }
}

struct ConvertView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var queue = ConvertQueue.shared
    @State private var target: Converter.Target?
    @State private var results: [Result] = []
    @State private var busy = false
    @State private var pageSpec = ""
    @State private var outDir: URL?
    @State private var targeted = false

    struct Result: Identifiable { let id = UUID(); let name: String; let outputs: [URL]; let error: String? }

    /// Formats every selected file can become.
    private var common: [Converter.Target] {
        guard let first = queue.files.first else { return [] }
        return queue.files.dropFirst().reduce(Converter.targets(for: first)) { acc, u in
            let t = Set(Converter.targets(for: u)); return acc.filter(t.contains)
        }
    }
    private var kinds: Set<String> { Set(queue.files.compactMap { Converter.kind($0).map { "\($0)" } }) }
    private var allPDF: Bool { !queue.files.isEmpty && kinds == ["pdf"] }
    private var allImages: Bool { !queue.files.isEmpty && kinds == ["image"] }

    var body: some View {
        ModulePane(title: "Convert") {
            Button { pick() } label: { Label("Add files…", systemImage: "plus") }
        } content: {
            VStack(spacing: 0) {
                if queue.files.isEmpty { dropHint } else { fileList }
                if !results.isEmpty { Divider(); resultList }
            }
            // Filling the pane keeps the file list at the top (unsized, the window centered the
            // whole module, header and all) and makes all of it a drop target.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(targeted ? Color.accentColor.opacity(0.07) : Color.clear)
            .onDrop(of: [.fileURL], isTargeted: $targeted) { _ in
                let urls = (NSPasteboard(name: .drag).readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
                queue.add(urls); return !urls.isEmpty
            }
        }
    }

    private var dropHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath.doc.on.clipboard").font(.system(size: 40)).foregroundStyle(.tint)
            Text("Drop files to convert").font(.title3.weight(.semibold))
            Text("Word, PDF, PowerPoint, Excel, Pages, Keynote, Numbers, images, audio and video. Or right-click files in Finder ▸ Services ▸ Convert with StudyBar.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button("Choose files…") { pick() }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(queue.files, id: \.self) { u in
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: u.path)).resizable().frame(width: 22, height: 22)
                            Text(u.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button { queue.files.removeAll { $0 == u } } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).foregroundStyle(.secondary)
                                .accessibilityLabel("Remove \(u.lastPathComponent)")
                        }.padding(.horizontal, 12).padding(.vertical, 4)
                    }
                }.padding(.vertical, 6)
            }
            .frame(maxHeight: 220)
            Divider()
            controls.padding(12)
        }
    }

    @ViewBuilder private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if common.isEmpty && !(allPDF || allImages) {
                Text("These files have no format in common — convert one kind at a time.").font(.callout).foregroundStyle(.secondary)
            }
            if !common.isEmpty {
                HStack {
                    Picker("Convert to", selection: $target) {
                        Text("Choose…").tag(Converter.Target?.none)
                        ForEach(common) { Text($0.title).tag(Converter.Target?.some($0)) }
                    }.frame(maxWidth: 360)
                    Button("Convert") { run { try await convertAll() } }.buttonStyle(.borderedProminent).disabled(target == nil || busy)
                }
                if let t = target, let first = queue.files.first, let app = Converter.app(t, for: first) {
                    Text("\(app.rawValue) opens each file and exports it — the first time, macOS asks to let StudyBar control \(app.rawValue).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            // Things done to the files together rather than one by one.
            HStack(spacing: 8) {
                if allPDF && queue.files.count > 1 {
                    Button("Merge into one PDF") { run { try merge() } }
                }
                if allPDF && queue.files.count == 1 {
                    Button("Split into pages") { run { [try Converter.split(queue.files[0])] } }
                    Button("Rotate") { run { [try Converter.rotate(queue.files[0])] } }
                    TextField("Pages, e.g. 1-3, 5", text: $pageSpec).textFieldStyle(.roundedBorder).frame(width: 150)
                    Button("Extract") { run { [try Converter.extract(queue.files[0], pages: pageSpec)] } }.disabled(pageSpec.isEmpty)
                }
                if allImages {
                    Button(queue.files.count > 1 ? "Combine into one PDF" : "Make a PDF") { run { try combine(gif: false) } }
                    if queue.files.count > 1 { Button("Animated GIF") { run { try combine(gif: true) } } }
                }
                if queue.files.count == 1, ["gif", "tif", "tiff"].contains(queue.files[0].pathExtension.lowercased()) {
                    Button("Frames") { run { [try Converter.frames(queue.files[0])] } }
                }
                if queue.files.allSatisfy({ ["pptx", "pdf"].contains($0.pathExtension.lowercased()) }) {
                    Button { run { try await studyNotes() } } label: { Label("Make study notes", systemImage: "sparkles") }
                        .disabled(!AIConfig.isReady(for: .transcript))
                        .help("Turn the slides' text into full study notes, filled in and saved as a note")
                }
            }
            .disabled(busy)
            HStack {
                Toggle("Save next to the originals", isOn: Binding(get: { outDir == nil }, set: { if $0 { outDir = nil } else { chooseFolder() } }))
                if let outDir { Text(outDir.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Clear") { queue.files = []; results = []; target = nil }.disabled(busy)
            }
        }
        .onChange(of: common) { _, c in if let t = target, !c.contains(t) { target = nil } }
    }

    private var resultList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(results) { r in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: r.error == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(r.error == nil ? .green : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.name).font(.callout.weight(.medium))
                            if let e = r.error { Text(e).font(.caption).foregroundStyle(.secondary) }
                            ForEach(r.outputs, id: \.self) { o in Text(o.lastPathComponent).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if !r.outputs.isEmpty {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(r.outputs) }.controlSize(.small)
                        }
                    }
                }
            }.padding(12)
        }
    }

    // MARK: Actions

    private func run(_ job: @escaping () async throws -> [URL]) {
        busy = true
        Task {
            do {
                let out = try await job()
                if !out.isEmpty {
                    results.insert(Result(name: out.count == 1 ? out[0].lastPathComponent : "\(out.count) files", outputs: out, error: nil), at: 0)
                }
            } catch {
                results.insert(Result(name: "Couldn't finish", outputs: [], error: error.localizedDescription), at: 0)
            }
            busy = false
        }
    }

    /// One at a time, each file's outcome listed; a failure doesn't stop the rest.
    private func convertAll() async throws -> [URL] {
        guard let t = target else { return [] }
        var all: [URL] = []
        for u in queue.files {
            do {
                let out = try await Converter.convert(u, to: t, in: outDir)
                all += out
                if queue.files.count > 1 { results.insert(Result(name: u.lastPathComponent, outputs: out, error: nil), at: 0) }
            } catch {
                results.insert(Result(name: u.lastPathComponent, outputs: [], error: error.localizedDescription), at: 0)
            }
        }
        if queue.files.count > 1 { return [] }
        return all
    }

    private func merge() throws -> [URL] {
        let out = Converter.destination(for: queue.files[0], ext: "pdf", suffix: " (merged)", in: outDir)
        try Converter.merge(queue.files, to: out)
        return [out]
    }

    private func combine(gif: Bool) throws -> [URL] {
        let out = Converter.destination(for: queue.files[0], ext: gif ? "gif" : "pdf", suffix: queue.files.count > 1 ? " and more" : "", in: outDir)
        if gif { try Converter.imagesToGIF(queue.files, to: out) } else { try Converter.imagesToPDF(queue.files, to: out) }
        return [out]
    }

    /// Slides (or a slide PDF) → their text → filled-in study notes, saved as a note.
    private func studyNotes() async throws -> [URL] {
        guard let provider = AIService.makeProvider(for: .transcript) else { return [] }
        for u in queue.files {
            let text = u.pathExtension.lowercased() == "pptx"
                ? StudyMaterial.slides(u).filter { !$0.text.isEmpty }.map { "[Slide \($0.number)]\n\($0.text)" }.joined(separator: "\n\n")
                : StudyMaterial.extract(u).map { "[\($0.locator)]\n\($0.text)" }.joined(separator: "\n\n")
            guard !text.isEmpty else { throw Converter.Failure.nothingFound }
            guard let notes = await LectureNotes.run(text, job: .slides, provider: provider,
                                                     mode: AIConfig.engine(for: .transcript), progress: { _, _, _ in }) else {
                throw Converter.Failure.app("The AI didn't return notes — try again, or a stronger engine in Settings ▸ Intelligence.")
            }
            var note = Note(title: u.deletingPathExtension().lastPathComponent, body: notes)
            note.updatedAt = .now
            state.data.notes.append(note)
            results.insert(Result(name: "Saved “\(note.title)” to Notes", outputs: [], error: nil), at: 0)
        }
        return []
    }

    private func pick() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        guard p.runModal() == .OK else { return }
        queue.add(p.urls)
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.prompt = "Save Here"
        if p.runModal() == .OK { outDir = p.url }
    }
}
