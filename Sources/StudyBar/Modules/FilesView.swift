import SwiftUI

struct FilesView: View {
    @EnvironmentObject var state: AppState
    @State private var mode = 0   // 0 recent, 1 pdf search
    @State private var query = ""
    @State private var recent: [FolderAccess.FileItem] = []
    @State private var matches: [FolderAccess.PDFMatch] = []
    @State private var searching = false
    @State private var typeFilter = "all"

    private let fileTypes: [(String, String, Set<String>)] = [
        ("all", "All", []),
        ("pdf", "PDF", ["pdf"]),
        ("docs", "Docs", ["docx","doc","pages","txt","md","rtf"]),
        ("slides", "Slides", ["pptx","ppt","key"]),
        ("sheets", "Sheets", ["xlsx","xls","numbers","csv"]),
    ]
    private var filteredRecent: [FolderAccess.FileItem] {
        guard typeFilter != "all", let set = fileTypes.first(where: { $0.0 == typeFilter })?.2 else { return recent }
        return recent.filter { set.contains($0.url.pathExtension.lowercased()) }
    }

    var body: some View {
        ModulePane(title: "Files") {
            Button { addFolder() } label: { Image(systemName: "folder.badge.plus") }
                .help("Add a folder")
        } content: {
            VStack(spacing: 0) {
                folderBar
                Divider()
                Picker("", selection: $mode) {
                    Text("Recent").tag(0); Text("Search PDFs").tag(1)
                }.pickerStyle(.segmented).labelsHidden().padding(8)
                Divider()
                if state.data.folders.isEmpty {
                    EmptyState(symbol: "folder", title: "No folders",
                               subtitle: "Add a course or Downloads folder to list recent files and search inside PDFs.")
                } else if mode == 0 {
                    recentList
                } else {
                    pdfSearch
                }
            }
        }
        .onAppear { loadRecent() }
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
            if filteredRecent.isEmpty {
                EmptyState(symbol: "clock", title: "No recent files", subtitle: "Nothing matching in these folders.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filteredRecent) { f in
                            fileRow(f.url, sub: "\(f.modified.relativeShort) · \(size(f.size))")
                        }
                    }.padding(10)
                }
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
                            Button { NSWorkspace.shared.open(m.url) } label: {
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
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent).fontWeight(.medium).lineLimit(1)
                Text(sub).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button { quickLook(url) } label: { Image(systemName: "eye") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).font(.caption).help("Quick Look")
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).font(.caption).help("Reveal in Finder")
            Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right.square") }
                .buttonStyle(.borderless).font(.caption).help("Open")
        }
        .padding(8).background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func quickLook(_ url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        p.arguments = ["-p", url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
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
