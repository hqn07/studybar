import AppKit

/// Backs the macOS Services menu entries ("Add to StudyBar as Note / Task").
final class ServicesProvider: NSObject {
    static let shared = ServicesProvider()

    @objc func addNoteService(_ pboard: NSPasteboard, userData: String?,
                              error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        guard let text = pboard.string(forType: .string) else { return }
        Task { @MainActor in
            if AppActions.addNote(text) { Notifier.post(title: "Saved to StudyBar", body: "Added as a note.") }
        }
    }

    @objc func addTaskService(_ pboard: NSPasteboard, userData: String?,
                              error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        guard let text = pboard.string(forType: .string) else { return }
        Task { @MainActor in
            if AppActions.addTask(text) { Notifier.post(title: "Saved to StudyBar", body: "Added as a task.") }
        }
    }

    /// Finder ▸ Services ▸ Convert with StudyBar: the selected files, into the Convert module.
    @objc func convertFilesService(_ pboard: NSPasteboard, userData: String?,
                                   error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        Task { @MainActor in ConvertQueue.shared.open(urls) }
    }

    static func register() {
        NSApp.servicesProvider = shared
        NSUpdateDynamicServices()
    }
}
