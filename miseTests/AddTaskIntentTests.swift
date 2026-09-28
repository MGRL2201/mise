import Testing
import Foundation
import EventKit
import SwiftData
@testable import mise

/// #22: Siri / Shortcuts intents write to Reminders via EventKit.
@MainActor
struct AddTaskIntentTests {
    /// Runs AddTaskIntent, then finds the created reminder by the unique `id` in its title.
    private func add(_ title: String, id: String, due: Date? = nil) async throws -> (RemindersStore, EKReminder) {
        var intent = AddTaskIntent()
        intent.title = title
        intent.due = due
        _ = try await intent.perform()
        let store = RemindersStore()
        await store.refresh()
        let reminder = try #require(store.reminders.first { $0.title?.contains(id) == true })
        return (store, reminder)
    }

    @Test(.enabled(if: EKEventStore.authorizationStatus(for: .reminder) == .fullAccess))
    func addParsesQuickAddIntoDefaultList() async throws {
        let id = UUID().uuidString
        let (store, reminder) = try await add("mise intent test \(id) tomorrow !high", id: id)
        defer { try? store.eventStore.remove(reminder, commit: true) }

        #expect(reminder.title == "mise intent test \(id)")
        #expect(reminder.priority == 1)
        #expect(reminder.calendar?.calendarIdentifier == store.eventStore.defaultCalendarForNewReminders()?.calendarIdentifier)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now)!
        let due = try #require(reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) })
        #expect(Calendar.current.isDate(due, inSameDayAs: tomorrow))
    }

    @Test(.enabled(if: EKEventStore.authorizationStatus(for: .reminder) == .fullAccess))
    func explicitDueOverridesParsedDate() async throws {
        let id = UUID().uuidString
        let due = DateComponents(calendar: .current, year: 2030, month: 1, day: 2, hour: 9, minute: 30).date!
        let (store, reminder) = try await add("mise intent test \(id) tomorrow", id: id, due: due)
        defer { try? store.eventStore.remove(reminder, commit: true) }

        #expect(reminder.title == "mise intent test \(id)")
        let c = try #require(reminder.dueDateComponents)
        #expect([c.year, c.month, c.day, c.hour, c.minute] == [2030, 1, 2, 9, 30])
        #expect(reminder.alarms?.filter { $0.absoluteDate == nil && $0.relativeOffset == 0 }.count == 1)
    }

    @Test(.enabled(if: EKEventStore.authorizationStatus(for: .reminder) == .fullAccess))
    func explicitDueDropsParsedRecurrence() async throws {
        let id = UUID().uuidString
        let due = DateComponents(calendar: .current, year: 2030, month: 1, day: 2, hour: 9, minute: 30).date!
        let (store, reminder) = try await add("mise intent test \(id) every monday", id: id, due: due)
        defer { try? store.eventStore.remove(reminder, commit: true) }

        #expect(reminder.recurrenceRules?.isEmpty ?? true)
    }

    @Test(.enabled(if: EKEventStore.authorizationStatus(for: .reminder) == .fullAccess))
    func unknownListFallsBackToCloseMatch() async throws {
        let name = "misetest" + UUID().uuidString.prefix(8)
        let list = try RemindersStore().newList(title: name)
        defer { try? RemindersStore().deleteList(list) }
        let id = UUID().uuidString
        let (store, reminder) = try await add("mise intent test \(id) #\(name.dropLast())", id: id)
        defer { try? store.eventStore.remove(reminder, commit: true) }

        #expect(reminder.title == "mise intent test \(id)")
        #expect(reminder.calendar?.calendarIdentifier == list.calendarIdentifier)
    }

    @Test(.enabled(if: EKEventStore.authorizationStatus(for: .reminder) == .fullAccess))
    func completeMarksReminderDone() async throws {
        let store = RemindersStore()
        let list = try store.newList(title: "mise-test-\(UUID().uuidString)")
        defer { try? store.deleteList(list) }
        let reminder = store.newReminder(in: list)
        reminder.title = "mise intent complete test"
        try store.save(reminder)

        let intent = CompleteTaskIntent(reminderID: reminder.calendarItemIdentifier)
        // @Dependency only resolves inside the system's perform flow; a direct perform() needs it set.
        intent.container = try ModelContainer(for: Schema(Storage.models),
                                              configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        _ = try await intent.perform()

        let reread = try #require(EKEventStore().calendarItem(withIdentifier: reminder.calendarItemIdentifier) as? EKReminder)
        #expect(reread.isCompleted)
    }
}
