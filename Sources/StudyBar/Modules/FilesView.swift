import SwiftUI

struct FilesView: View {
    @EnvironmentObject var state: AppState
    @State private var mode = 0   // 0 recent, 1 pdf search
    @State private var query = ""
    @State private var recent: [FolderAccess.FileItem] = []
    @State private var matches: [FolderAccess.PDFMatch] = []
    @State private var searching = false
    @State private var typeFilter = "all"
    @State private var collapsed: Set<String> = []
    @State private var groupPrompt: GroupPrompt? = nil

    /// Inline "name a group" prompt. `url == nil` means pick files afterward.
    private struct GroupPrompt: Identifiable { let id = UUID(); var name: String; var url: URL? }

    private let fileTypes: [(String, String, Set<String>)] = [
        ("all", "All", []),
        ("pdf", "PDF", ["pdf", "epub"]),
        ("docs", "Docs", ["docx","doc","pages","txt","md","rtf","rtfd","tex","odt"]),
        ("slides", "Slides", ["pptx","ppt","key","odp"]),
        ("sheets", "Sheets", ["xlsx","xls","numbers","csv","tsv","ods"]),
        ("images", "Images", ["png","jpg","jpeg","gif","heic","tiff","tif","bmp","webp","svg"]),
        ("code", "Code", ["swift","py","js","ts","java","kt","c","cpp","cc","h","hpp","cs","go","rb","rs","php","html","css","json","xml","yml","yaml","sh"]),
    ]
    private var filteredRecent: [FolderAccess.FileItem] {
        guard typeFilter != "all", let set = fileTypes.first(where: { $0.0 == typeFilter })?.2 else { return recent }
        return recent.filter { set.contains($0.url.pathExtension.lowercased()) }
    }

    var body: some View {
        ModulePane(title: "Files") {
            HStack(spacing: 8) {
                Button { groupPrompt = GroupPrompt(name: "Syllabus", url: nil) } label: {
                    Image(systemName: "pin.badge.plus")
                }.help("Pin files into a group")
                Button { addFolder() } label: { Image(systemName: "folder.badge.plus") }
                    .help("Add a folder")
            }
        } content: {
            VStack(spacing: 0) {
                folderBar
                Divider()
                Picker("", selection: $mode) {
                    Text("Recent").tag(0); Text("Search PDFs").tag(1)
                }.pickerStyle(.segmented).labelsHidden().padding(8)
                Divider()
                if state.data.folders.isEmpty && state.fileRefs.isEmpty {
                    EmptyState(symbol: "folder", title: "No folders or pinned files",
                               subtitle: "Add a folder to list recent files and search PDFs, or pin files into a group for quick access.")
                } else if mode == 0 {
                    recentList
                } else {
                    pdfSearch
                }
            }
        }
        .onAppear { loadRecent() }
        .overlay { if let gp = groupPrompt { groupPromptCard(gp) } }
    }

    // MARK: Pinned-file groups

    @ViewBuilder private var groupsSection: some View {
        if !state.fileRefs.isEmpty {
            let groups = Dictionary(grouping: state.fileRefs, by: { $0.group })
            let names = groups.keys.sorted { ($0.isEmpty ? "~" : $0.lowercased()) < ($1.isEmpty ? "~" : $1.lowercased()) }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(names, id: \.self) { g in
                    DisclosureGroup(isExpanded: expansion(g)) {
                        VStack(spacing: 4) {
                            ForEach(groups[g] ?? []) { pinnedRow($0) }
                        }.padding(.top, 4)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "tag.fill").font(.caption2).foregroundStyle(.tint)
                            Text(g.isEmpty ? "Ungrouped" : g).font(.caption.bold())
                            Text("\(groups[g]?.count ?? 0)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func addToGroupMenu(_ url: URL) -> some View {
        Menu("Add to group") {
            ForEach(existingGroups, id: \.self) { name in
                Button(name) { state.fileRefs.append(FolderAccess.fileRef(for: url, group: name)) }
            }
            if !existingGroups.isEmpty { Divider() }
            Button("New group…") { groupPrompt = GroupPrompt(name: "Syllabus", url: url) }
        }
    }

    private func pinnedRow(_ ref: FileRef) -> some View {
        let url = FolderAccess.resolveFile(ref)
        return HStack(spacing: 8) {
            Image(nsImage: url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(forFileType: "public.data"))
                .resizable().frame(width: 18, height: 18)
            Text(ref.name).font(.caption).lineLimit(1).foregroundStyle(url == nil ? .secondary : .primary)
            if url == nil { Text("missing").font(.caption2).foregroundStyle(.orange) }
            Spacer()
            if let url {
                Button { preview(url) } label: { Image(systemName: "eye") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).font(.caption).help("Open in Preview")
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).font(.caption).help("Reveal in Finder")
            }
            Button { state.fileRefs.removeAll { $0.id == ref.id } } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).font(.caption).help("Remove from group")
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 7))
    }

    private func expansion(_ g: String) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(g) },
                set: { open in if open { collapsed.remove(g) } else { collapsed.insert(g) } })
    }

    private func groupPromptCard(_ gp: GroupPrompt) -> some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea().onTapGesture { groupPrompt = nil }
            VStack(spacing: 12) {
                Text(gp.url == nil ? "Pin files into a group" : "Add to group").font(.headline)
                Text("Name a group — it doubles as a quick-access tag.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                TextField("Group name", text: Binding(
                    get: { groupPrompt?.name ?? "" },
                    set: { groupPrompt?.name = $0 }))
                    .textFieldStyle(.roundedBorder).frame(width: 220)
                    .onSubmit { commitGroup(gp.url) }
                if !existingGroups.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(existingGroups, id: \.self) { name in
                                Button { groupPrompt?.name = name } label: {
                                    Text(name).font(.caption2).padding(.horizontal, 7).padding(.vertical, 2)
                                        .background(.background.secondary, in: Capsule())
                                }.buttonStyle(.plain)
                            }
                        }
                    }.frame(maxWidth: 220)
                }
                HStack(spacing: 10) {
                    Button("Cancel") { groupPrompt = nil }.keyboardShortcut(.cancelAction)
                    Button(gp.url == nil ? "Choose files…" : "Add") { commitGroup(gp.url) }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
            .padding(20).frame(maxWidth: 280)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator)).shadow(radius: 20)
        }
    }

    private var existingGroups: [String] {
        Array(Set(state.fileRefs.map { $0.group }.filter { !$0.isEmpty })).sorted()
    }

    private func commitGroup(_ url: URL?) {
        let group = (groupPrompt?.name ?? "").trimmingCharacters(in: .whitespaces)
        if let url {
            state.fileRefs.append(FolderAccess.fileRef(for: url, group: group))
            groupPrompt = nil
        } else {
            groupPrompt = nil
            state.fileRefs.append(contentsOf: FolderAccess.pickFiles(group: group))
        }
    }

    private var folderBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(state.data.folders) { f in
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill").font(.caption2)
                        Text(f.name).font(.caption)
                        Button { state.data.folders.removeAll { $0.id == f.id }; loadRecent() } label: {
                            Image(systemName: "xmark.circle.fill").font(.caption2)
                        }.buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.background.secondary, in: Capsule())
                }
            }.padding(.horizontal, 10).padding(.vertical, 6)
        }
    }

    private var recentList: some View {
        VStack(spacing: 0) {
            if !recent.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(fileTypes, id: \.0) { t in
                            Button { typeFilter = t.0 } label: {
                                Text(t.1).font(.caption)
                                    .padding(.horizontal, 9).padding(.vertical, 3)
                                    .background(typeFilter == t.0 ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.background.secondary), in: Capsule())
                                    .foregroundStyle(typeFilter == t.0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 10).padding(.vertical, 6)
                }
                Divider()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if !state.fileRefs.isEmpty {
                        Text("GROUPS").font(.caption2.bold()).foregroundStyle(.secondary)
                    } else if !recent.isEmpty {
                        Label("Tap the tag icon on a file to group it (e.g. Syllabus).",
                              systemImage: "tag")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    groupsSection
                    if !state.fileRefs.isEmpty && !filteredRecent.isEmpty {
                        Divider().padding(.vertical, 2)
                        Text("RECENT").font(.caption2.bold()).foregroundStyle(.secondary)
                    }
                    if filteredRecent.isEmpty {
                        if recent.isEmpty {
                            Text(state.data.folders.isEmpty
                                 ? "Add a folder to list recent files here."
                                 : "No recent files in these folders.")
                                .font(.caption).foregroundStyle(.secondary).padding(.vertical, 6)
                        } else {
                            Text("No recent files match this filter.").font(.caption).foregroundStyle(.secondary).padding(.vertical, 6)
                        }
                    } else {
                        ForEach(filteredRecent) { f in
                            fileRow(f.url, sub: "\(f.modified.relativeShort) · \(size(f.size))")
                                .contextMenu { addToGroupMenu(f.url) }
                        }
                    }
                }.padding(10)
            }
        }
    }

    private var pdfSearch: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search inside PDFs…", text: $query, onCommit: runSearch).textFieldStyle(.plain)
                if searching { ProgressView().controlSize(.small) }
                else { Button("Search", action: runSearch).disabled(query.isEmpty) }
            }.padding(10)
            Divider()
            if matches.isEmpty {
                EmptyState(symbol: "doc.text.magnifyingglass", title: "Search your PDFs",
                           subtitle: "Type a term to find it across the PDFs in your folders.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(matches) { m in
                            Button { preview(m.url) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.url.lastPathComponent).fontWeight(.medium).lineLimit(1)
                                    Text("…\(m.snippet)…").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(9).background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain)
                        }
                    }.padding(10)
                }
            }
        }
    }

    private func fileRow(_ url: URL, sub: String) -> some View {
        let grouped = state.fileRefs.contains { FolderAccess.resolveFile($0)?.path == url.path }
        return HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent).fontWeight(.medium).lineLimit(1)
                Text(sub).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                ForEach(existingGroups, id: \.self) { name in
                    Button { state.fileRefs.append(FolderAccess.fileRef(for: url, group: name)) } label: {
                        Label(name, systemImage: "tag")
                    }
                }
                if !existingGroups.isEmpty { Divider() }
                Button { groupPrompt = GroupPrompt(name: "Syllabus", url: url) } label: {
                    Label("New group…", systemImage: "plus")
                }
            } label: {
                Image(systemName: grouped ? "tag.fill" : "tag")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .foregroundStyle(grouped ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .font(.caption).help("Add to a group (tag)")
            Button { preview(url) } label: { Image(systemName: "eye") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).font(.caption).help("Open in Preview")
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).font(.caption).help("Reveal in Finder")
            Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right.square") }
                .buttonStyle(.borderless).font(.caption).help("Open")
        }
        .padding(8).background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }

    /// Open in Apple Preview for docs/images (resizable, annotatable — nicer than a
    /// transient Quick Look panel, and as an external app it won't dismiss the popover);
    /// fall back to the default app for other types.
    private func preview(_ url: URL) {
        let previewable: Set<String> = ["pdf", "png", "jpg", "jpeg", "gif", "tiff", "tif",
                                        "heic", "bmp", "webp", "icns", "eps", "ps", "ai"]
        if previewable.contains(url.pathExtension.lowercased()),
           let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            NSWorkspace.shared.open([url], withApplicationAt: app,
                                    configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func addFolder() {
        if let ref = FolderAccess.pick() {
            state.data.folders.append(ref)
            loadRecent()
        }
    }
    private func loadRecent() {
        recent = state.data.folders.flatMap { FolderAccess.recentFiles(in: $0) }
            .sorted { $0.modified > $1.modified }
    }
    private func runSearch() {
        let q = query
        guard !q.isEmpty else { return }
        let folders = state.data.folders
        searching = true; matches = []
        Task {
            let all = await Task.detached { () -> [FolderAccess.PDFMatch] in
                var out: [FolderAccess.PDFMatch] = []
                for f in folders { out += FolderAccess.searchPDFs(in: f, query: q) }
                return out
            }.value
            matches = all
            searching = false
        }
    }
    private func size(_ b: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
    }
}
