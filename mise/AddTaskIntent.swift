import AppIntents
import Foundation

/// Spike #12: Siri / Shortcuts add-task. String params can't appear in App
/// Shortcut phrases, so Siri asks for the title as a follow-up.
struct AddTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Task"
    static let storeKey = "spike.siriTasks"

    @Parameter(title: "Task", requestValueDialog: "What's the task?")
    var title: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // ponytail: spike store; real add goes to Reminders (EventKit) in the Tasks phase
        let defaults = UserDefaults.standard
        defaults.set((defaults.stringArray(forKey: Self.storeKey) ?? []) + [title], forKey: Self.storeKey)
        return .result(dialog: "Added \(title) to mise.")
    }
}

nonisolated struct MiseShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddTaskIntent(),
            phrases: [
                "Add a task in \(.applicationName)",
                "Add task to \(.applicationName)",
            ],
            shortTitle: "Add Task",
            systemImageName: "checklist"
        )
    }
}
