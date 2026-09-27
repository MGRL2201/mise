import Foundation
import SwiftData

/// A user tag. Name identity (trimmed, case-insensitive) is enforced in code,
/// not by a unique attribute, so CloudKit stays possible.
@Model
final class Tag {
    var name: String = ""
    @Relationship(inverse: \TaskExtras.tags) var tasks: [TaskExtras]? = []

    init(name: String) {
        self.name = name
    }

    /// Fetch-or-create by name. Blank names return nil.
    static func named(_ name: String, in context: ModelContext) throws -> Tag? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        // ponytail: fetches all tags to compare case-insensitively; fine for hundreds of tags.
        if let existing = try context.fetch(FetchDescriptor<Tag>()).first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) { return existing }
        let tag = Tag(name: name)
        context.insert(tag)
        return tag
    }
}

struct Subtask: Codable, Hashable, Identifiable {
    var id = UUID()
    var title: String
    var done = false
}

/// App-owned data attached to an EventKit reminder (subtasks, tags).
/// Linked by calendarItemIdentifier, with the external identifier as fallback
/// since EventKit ids can change after sync.
@Model
final class TaskExtras {
    var reminderID: String = ""
    var externalID: String?
    var subtasks: [Subtask] = []  // array order = display order
    var tags: [Tag]? = []

    init(reminderID: String, externalID: String?) {
        self.reminderID = reminderID
        self.externalID = externalID
    }

    static func match(_ all: [TaskExtras], id: String, externalID: String?) -> TaskExtras? {
        if let exact = all.first(where: { $0.reminderID == id }) { return exact }
        guard let externalID, !externalID.isEmpty else { return nil }
        return all.first { $0.externalID == externalID }
    }

    /// Keeps extras whose reminder is listed (relinking on id change), and deletes
    /// the rest unless `exists` says the reminder is still there (e.g. an old
    /// completed reminder outside the store's fetch window).
    static func reconcile(_ context: ModelContext, reminders: [(id: String, externalID: String?)],
                          exists: (TaskExtras) -> Bool) throws {
        let ids = Set(reminders.map(\.id))
        for extras in try context.fetch(FetchDescriptor<TaskExtras>()) where !ids.contains(extras.reminderID) {
            if let externalID = extras.externalID, !externalID.isEmpty,
               let reminder = reminders.first(where: { $0.externalID == externalID }) {
                extras.reminderID = reminder.id
            } else if !exists(extras) {
                context.delete(extras)
            }
        }
        try context.save()
    }
}
