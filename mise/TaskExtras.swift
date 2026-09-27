import Foundation
import SwiftData

/// A user tag. Name identity (trimmed, case-insensitive) is enforced in code,
/// not by a unique attribute, so CloudKit stays possible.
// ponytail: tags with no tasks persist on purpose (Notes will share them); no delete/rename UI yet.
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
    /// When reconcile first found the reminder gone; nil while it exists.
    var missingSince: Date?

    init(reminderID: String, externalID: String?) {
        self.reminderID = reminderID
        self.externalID = externalID
    }

    static func match(_ all: [TaskExtras], id: String, externalID: String?) -> TaskExtras? {
        if let exact = all.first(where: { $0.reminderID == id }) { return exact }
        guard let externalID, !externalID.isEmpty else { return nil }
        return all.first { $0.externalID == externalID }
    }

    /// Writes the editor's draft for a saved reminder: replaces subtasks and tags on the
    /// matching row, creating one only when there is something to store. Saves.
    static func write(in context: ModelContext, reminderID: String, externalID: String?,
                      subtasks: [Subtask], tagNames: [String]) throws {
        let subtasks = subtasks.filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var tags: [Tag] = []
        for name in tagNames {
            if let tag = try Tag.named(name, in: context), !tags.contains(where: { $0 === tag }) { tags.append(tag) }
        }
        var row = match(try context.fetch(FetchDescriptor<TaskExtras>()), id: reminderID, externalID: externalID)
        if row == nil, !subtasks.isEmpty || !tags.isEmpty {
            row = TaskExtras(reminderID: reminderID, externalID: externalID)
            context.insert(row!)
        }
        if let row {
            row.reminderID = reminderID
            row.externalID = externalID
            row.subtasks = subtasks
            row.tags = tags
        }
        do { try context.save() } catch { context.rollback(); throw error }
    }

    /// Keeps extras whose reminder is listed (relinking on id change, merging into
    /// any row that already owns the new id). Rows whose reminder is neither listed
    /// nor `exists` (e.g. an old completed reminder outside the fetch window) are
    /// stamped `missingSince` and deleted once missing for 7 days.
    // ponytail: 7-day grace so an empty/partial fetch (iCloud not synced yet, signed out,
    // fetch error) never wipes extras; a truly deleted reminder's extras linger up to a week.
    static func reconcile(_ context: ModelContext, reminders: [(id: String, externalID: String?)],
                          now: Date = .now, exists: (TaskExtras) -> Bool) throws {
        let all = try context.fetch(FetchDescriptor<TaskExtras>())
        let ids = Set(reminders.map(\.id))
        let idByExternal = Dictionary(reminders.compactMap { reminder in
            reminder.externalID.flatMap { $0.isEmpty ? nil : ($0, reminder.id) }
        }, uniquingKeysWith: { first, _ in first })
        var owners = Dictionary(all.map { ($0.reminderID, $0) }, uniquingKeysWith: { first, _ in first })
        for extras in all {
            if ids.contains(extras.reminderID) {
                extras.missingSince = nil
            } else if let externalID = extras.externalID, let id = idByExternal[externalID] {
                if let owner = owners[id], owner !== extras {
                    owner.subtasks += extras.subtasks
                    owner.tags = (owner.tags ?? []) + (extras.tags ?? []).filter { tag in
                        !(owner.tags ?? []).contains { $0 === tag }
                    }
                    context.delete(extras)
                } else {
                    extras.reminderID = id
                    extras.missingSince = nil
                    owners[id] = extras
                }
            } else if exists(extras) {
                extras.missingSince = nil
            } else if let since = extras.missingSince {
                if now.timeIntervalSince(since) >= 7 * 86400 { context.delete(extras) }
            } else {
                extras.missingSince = now
            }
        }
        try context.save()
    }
}
