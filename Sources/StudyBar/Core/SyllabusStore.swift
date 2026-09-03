import Foundation
import AppKit

/// Stores a course's syllabus file beside the app's other assets (App Support/StudyBar/Syllabi),
/// so it's kept and re-openable — unlike the fire-and-forget import that only triaged the text.
enum SyllabusStore {
    static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StudyBar/Syllabi", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Copy a picked syllabus file into the store, keyed by course. Returns a fresh SyllabusItem.
    static func attach(_ src: URL, courseID: UUID) -> SyllabusItem? {
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        let ext = src.pathExtension.isEmpty ? "pdf" : src.pathExtension
        let dst = dir.appendingPathComponent("\(courseID.uuidString).\(ext)")
        try? FileManager.default.removeItem(at: dst)
        do { try FileManager.default.copyItem(at: src, to: dst) } catch { return nil }
        return SyllabusItem(fileName: src.lastPathComponent, filePath: dst.path, importedAt: .now)
    }

    static func remove(_ item: SyllabusItem) {
        guard !item.filePath.isEmpty else { return }
        try? FileManager.default.removeItem(atPath: item.filePath)
    }

    static func open(_ item: SyllabusItem) {
        guard !item.filePath.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: item.filePath))
    }

    /// Extracted text of the stored file (for AI extraction). Reuses SyllabusImport's extractor.
    @MainActor static func text(_ item: SyllabusItem) -> String {
        guard !item.filePath.isEmpty else { return "" }
        return SyllabusImport.extractText(URL(fileURLWithPath: item.filePath))
    }
}
