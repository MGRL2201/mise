import AppIntents
import EventKit
import Foundation
import SwiftData

/// Siri / Shortcuts add-task. String params can't appear in App Shortcut
/// phrases, so Siri asks for the title as a follow-up.
struct AddTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Task"

    @Parameter(title: "Task", requestValueDialog: "What's the task?")
    var title: String

    @Parameter(title: "Due Date")
    var due: Date?

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .result(dialog: "What's the task? Give it a title.")
        }
        let store = RemindersStore()
        if store.status == .notDetermined { await store.requestAccess() }
        guard store.hasAccess else {
            return .result(dialog: "mise needs Reminders access. Open mise and allow access to Reminders.")
        }
        let writable = store.eventStore.calendars(for: .reminder).filter(\.allowsContentModifications)
        var q = QuickAdd.parse(title, lists: writable.map(\.title), now: .now)
        guard !q.title.isEmpty else {
            return .result(dialog: "What's the task? Give it a title.")
        }
        // Siri can't ask "Did you mean", so take the close match; no list creation from Siri.
        if q.listName == nil, let n = q.unknownList { q.listName = QuickAdd.closeMatch(n, in: writable.map(\.title)) }
        if let due {
            q.due = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            q.recurrence = .none  // a parsed rule would repeat on the overridden date
        }
        let r = store.newReminder()
        q.apply(to: r, lists: writable)
        try store.save(r)
        return .result(dialog: "Added \(q.title) to mise.")
    }
}

/// Marks a reminder done by identifier. Plumbing for widget buttons (#77), not a user-facing Shortcut.
struct CompleteTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Complete Task"
    static let isDiscoverable = false

    @Parameter(title: "Task ID")
    var reminderID: String

    @Dependency var container: ModelContainer

    init() {}
    init(reminderID: String) { self.reminderID = reminderID }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = RemindersStore(context: container.mainContext)  // context so the linked time-block title updates
        if store.status == .notDetermined { await store.requestAccess() }
        guard store.hasAccess else {
            return .result(dialog: "mise needs Reminders access. Open mise and allow access to Reminders.")
        }
        guard let r = store.eventStore.calendarItem(withIdentifier: reminderID) as? EKReminder else {
            return .result(dialog: "That task no longer exists.")
        }
        try store.setCompleted(r, true)
        return .result(dialog: "Completed \(r.title ?? "task").")
    }
}

/// Run by a Shortcuts "Transaction" personal automation (Wallet card tap) to log an Apple Pay purchase (#153).
/// Optional params so a missing automation value never makes Shortcuts prompt.
struct LogTransactionIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Transaction"
    static let description = IntentDescription(
        "Logs an Apple Pay purchase in mise. Use it in a Shortcuts Transaction automation, passing Amount, Merchant and Card.")

    @Parameter(title: "Amount")
    var amount: String?

    @Parameter(title: "Merchant")
    var merchant: String?

    @Parameter(title: "Card")
    var card: String?

    @Parameter(title: "Date")
    var date: Date?

    @Dependency var container: ModelContainer

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = container.mainContext
        let (dialog, saved) = await ApplePay.log(amount: amount ?? "", merchant: merchant ?? "", card: card ?? "",
                                                 date: date ?? .now, context: context)
        if let saved {
            await FX.refresh(context: context)
            await Budgets.checkAlerts(for: saved.category, on: saved.date, context: context)
        }
        return .result(dialog: IntentDialog(stringLiteral: dialog))
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
