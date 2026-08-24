import AppKit
import PDFKit
import UniformTypeIdentifiers

/// Import a syllabus from a PDF or text file, extract its text, and hand it to the
/// AI assistant to triage into a course, assignments, readings and class times.
@MainActor
enum SyllabusImport {

    static func pickAndTriage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .plainText, .text, .rtf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a syllabus (PDF or text file)"
        panel.prompt = "Import"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            triage(url: url)
        }
    }

    /// Extract text from a file (picked or dropped) and hand it to the assistant.
    static func triage(url: URL) {
        let text = extractText(url)
        // Surface the assistant in the window so the result is visible even if the
        // menu-bar popover dismissed (e.g. the file panel took focus).
        WindowOpener.open?("main")
        guard text.count > 40 else {
            AppActions.assistant("I couldn't read text from “\(url.lastPathComponent)” — it may be a scanned image. Try a text-based PDF, or paste the syllabus text here.")
            return
        }
        let clipped = String(text.prefix(8000))
        AppActions.assistant("""
        Organize this syllabus into StudyBar. Extract the course, its assignments \
        (with due dates and point values), required readings, and class meeting times, \
        and propose them using create_course, create_assignment, add_reading and add_class. \
        Today is \(Date().formatted(date: .abbreviated, time: .omitted)).

        SYLLABUS (“\(url.lastPathComponent)”):
        \(clipped)
        """)
    }

    static func extractText(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pdf":
            return PDFDocument(url: url)?.string ?? ""
        case "rtf":
            return (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string ?? ""
        default:
            return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
    }
}
