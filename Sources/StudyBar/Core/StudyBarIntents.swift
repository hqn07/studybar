import AppIntents

struct AddTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Task"
    static var description = IntentDescription("Add a to-do to StudyBar.")

    @Parameter(title: "Task") var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = AppActions.addTask(text)
        return .result(dialog: "Added “\(text)” to StudyBar.")
    }
}

struct AddNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Note"
    static var description = IntentDescription("Save a quick note to StudyBar.")

    @Parameter(title: "Note") var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = AppActions.addNote(text)
        return .result(dialog: "Saved a note to StudyBar.")
    }
}

struct StartFocusIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Focus"
    static var description = IntentDescription("Start a focus / Pomodoro session in StudyBar.")

    @Parameter(title: "Minutes", default: 25) var minutes: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppActions.startFocus(minutes: minutes)
        return .result(dialog: "Focusing for \(minutes) minutes.")
    }
}

struct StudyBarShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddTaskIntent(),
                    phrases: ["Add a task to \(.applicationName)", "New task in \(.applicationName)"],
                    shortTitle: "Add Task", systemImageName: "checkmark.circle")
        AppShortcut(intent: AddNoteIntent(),
                    phrases: ["Add a note to \(.applicationName)", "New note in \(.applicationName)"],
                    shortTitle: "Add Note", systemImageName: "note.text")
        AppShortcut(intent: StartFocusIntent(),
                    phrases: ["Start focus in \(.applicationName)", "Start a Pomodoro in \(.applicationName)"],
                    shortTitle: "Start Focus", systemImageName: "timer")
    }
}
