import Foundation

/// Handles `studybar://` deep links (from Shortcuts, scripts, other apps).
///   studybar://note?text=…&course=…
///   studybar://task?text=…&course=…&due=3
///   studybar://focus?minutes=25&label=…
///   studybar://open?module=today
///   studybar://palette
@MainActor
enum URLRouter {
    static func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "studybar" else { return }
        let action = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ k: String) -> String? { items.first { $0.name == k }?.value }

        switch action {
        case "note":
            AppActions.addNote(q("text") ?? "", course: q("course"))
        case "task":
            AppActions.addTask(q("text") ?? "", course: q("course"), dueInDays: q("due").flatMap { Int($0) })
        case "focus":
            AppActions.startFocus(minutes: q("minutes").flatMap { Int($0) }, label: q("label"))
        case "open":
            AppActions.open(module: q("module") ?? "today")
        case "palette":
            AppActions.open(module: AppState.current?.selectedModuleID ?? "today")
            AppState.current?.paletteRequested = true
        default:
            break
        }
    }
}
