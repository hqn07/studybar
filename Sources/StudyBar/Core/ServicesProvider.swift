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

    static func register() {
        NSApp.servicesProvider = shared
        NSUpdateDynamicServices()
    }
}
