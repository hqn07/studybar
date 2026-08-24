import AppKit
import PDFKit

enum FolderAccess {
    /// Prompt the user to pick a folder; returns a FolderRef with a bookmark.
    @MainActor static func pick() -> FolderRef? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let data = (try? url.bookmarkData(options: .withSecurityScope)) ?? (try? url.bookmarkData()) ?? Data()
        return FolderRef(name: url.lastPathComponent, bookmark: data)
    }

    static func resolve(_ ref: FolderRef) -> URL? {
        var stale = false
        let opts: URL.BookmarkResolutionOptions = [.withSecurityScope]
        if let url = try? URL(resolvingBookmarkData: ref.bookmark, options: opts,
                              relativeTo: nil, bookmarkDataIsStale: &stale) {
            return url
        }
        return try? URL(resolvingBookmarkData: ref.bookmark, bookmarkDataIsStale: &stale)
    }

    // MARK: Pinned individual files (grouped)

    /// Prompt the user to pick one or more files to pin into a group.
    @MainActor static func pickFiles(group: String) -> [FileRef] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Pin"
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.map { fileRef(for: $0, group: group) }
    }

    /// Bookmark an already-known file URL (e.g. from the recent list) into a group.
    static func fileRef(for url: URL, group: String) -> FileRef {
        let data = (try? url.bookmarkData(options: .withSecurityScope)) ?? (try? url.bookmarkData()) ?? Data()
        return FileRef(name: url.lastPathComponent, bookmark: data, group: group)
    }

    static func resolveFile(_ ref: FileRef) -> URL? {
        var stale = false
        if let url = try? URL(resolvingBookmarkData: ref.bookmark, options: [.withSecurityScope],
                              relativeTo: nil, bookmarkDataIsStale: &stale) { return url }
        return try? URL(resolvingBookmarkData: ref.bookmark, bookmarkDataIsStale: &stale)
    }

    struct FileItem: Identifiable, Hashable, Sendable {
        var id: String { url.path }
        let url: URL
        let modified: Date
        let size: Int
    }

    /// (25) Recent files in a folder tree, newest first.
    static func recentFiles(in ref: FolderRef, limit: Int = 60,
                            exts: Set<String> = ["pdf","docx","pptx","xlsx","txt","md","key","pages","numbers"]) -> [FileItem] {
        guard let root = resolve(ref) else { return [] }
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey]
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles]) else { return [] }
        var out: [FileItem] = []
        for case let url as URL in en {
            let ext = url.pathExtension.lowercased()
            guard !exts.isEmpty ? exts.contains(ext) : true else { continue }
            let vals = try? url.resourceValues(forKeys: Set(keys))
            if vals?.isDirectory == true { continue }
            out.append(FileItem(url: url,
                                modified: vals?.contentModificationDate ?? .distantPast,
                                size: vals?.fileSize ?? 0))
        }
        return Array(out.sorted { $0.modified > $1.modified }.prefix(limit))
    }

    struct PDFMatch: Identifiable, Hashable, Sendable {
        var id: String { url.path }
        let url: URL
        let snippet: String
    }

    /// (32) Search text across PDFs in a folder tree.
    static func searchPDFs(in ref: FolderRef, query: String, limit: Int = 40) -> [PDFMatch] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let root = resolve(ref) else { return [] }
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        guard let en = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var out: [PDFMatch] = []
        for case let url as URL in en where url.pathExtension.lowercased() == "pdf" {
            guard let doc = PDFDocument(url: url) else { continue }
            let sels = doc.findString(q, withOptions: [.caseInsensitive])
            guard let first = sels.first, let page = first.pages.first else { continue }
            let snippet = context(of: first, on: page)
            out.append(PDFMatch(url: url, snippet: snippet))
            if out.count >= limit { break }
        }
        return out
    }

    private static func context(of selection: PDFSelection, on page: PDFPage) -> String {
        guard let extended = selection.copy() as? PDFSelection else { return selection.string ?? "" }
        extended.extend(atStart: 30)
        extended.extend(atEnd: 60)
        return (extended.string ?? selection.string ?? "").replacingOccurrences(of: "\n", with: " ")
    }
}
