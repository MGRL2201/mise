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
    /// EKEvent.eventIdentifier of the linked time-block event.
    // ponytail: eventIdentifier can change when the event is moved between calendars outside mise,
    // losing the link; upgrade path = also store the event's calendarItemExternalIdentifier as fallback.
    var eventID: String?
    var flagged = false
    /// Task length estimate in minutes (#30); sizes time blocks and free-slot suggestions.
    var estimateMinutes: Int?

    init(reminderID: String, externalID: String?) {
        self.reminderID = reminderID
        self.externalID = externalID
    }

    static func match(_ all: [TaskExtras], id: String, externalID: String?) -> TaskExtras? {
        if let exact = all.first(where: { $0.reminderID == id }) { return exact }
        guard let externalID, !externalID.isEmpty else { return nil }
        return all.first { $0.externalID == externalID }
    }

    /// Writes the editor's draft for a saved reminder: replaces tags (and flag / estimate, unless nil) on the matching row,
    /// creating one only when there is something to store. Subtasks are 3-way merged against the
    /// stored ones when `base` (what the editor loaded) is given, else replaced. Saves.
    static func write(in context: ModelContext, reminderID: String, externalID: String?,
                      subtasks: [Subtask], tagNames: [String], flagged: Bool? = nil, estimateMinutes: Int?? = nil,
                      base: [Subtask]? = nil) throws {
        var tags: [Tag] = []
        for name in tagNames {
            if let tag = try Tag.named(name, in: context), !tags.contains(where: { $0 === tag }) { tags.append(tag) }
        }
        var row = match(try context.fetch(FetchDescriptor<TaskExtras>()), id: reminderID, externalID: externalID)
        let merged = if let base, let row { merge(base: base, mine: subtasks, theirs: row.subtasks) } else { subtasks }
        let subtasks = merged.filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if row == nil, !subtasks.isEmpty || !tags.isEmpty || flagged == true || (estimateMinutes ?? nil) != nil {
            row = TaskExtras(reminderID: reminderID, externalID: externalID)
            context.insert(row!)
        }
        if let row {
            row.reminderID = reminderID
            row.externalID = externalID
            row.subtasks = subtasks
            row.tags = tags
            if let flagged { row.flagged = flagged }
            if let estimateMinutes { row.estimateMinutes = estimateMinutes }
        }
        do { try context.save() } catch { context.rollback(); throw error }
    }

    /// 3-way merge of subtask lists: base = what the editor loaded, mine = the editor's list,
    /// theirs = what is stored now. Per field, my change wins, else theirs. Order = mine, then theirs' additions.
    static func merge(base: [Subtask], mine: [Subtask], theirs: [Subtask]) -> [Subtask] {
        let base = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let theirsByID = Dictionary(theirs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let mineIDs = Set(mine.map(\.id))
        return mine.compactMap { item in
            guard let old = base[item.id] else { return item }  // added by me
            guard var merged = theirsByID[item.id] else { return (item.title, item.done) == (old.title, old.done) ? nil : item }  // deleted elsewhere
            if item.title != old.title { merged.title = item.title }
            if item.done != old.done { merged.done = item.done }
            return merged
        } + theirs.filter { !base.keys.contains($0.id) && !mineIDs.contains($0.id) }
    }

    /// Flips one subtask's done flag; unknown ids are a no-op. Saves.
    static func toggleSubtask(_ id: UUID, in extras: TaskExtras, context: ModelContext) throws {
        guard let index = extras.subtasks.firstIndex(where: { $0.id == id }) else { return }
        extras.subtasks[index].done.toggle()
        do { try context.save() } catch { context.rollback(); throw error }
    }

    /// Links (or with nil, unlinks) a time-block event; creates a row only to store a link. Saves.
    static func setEventID(_ eventID: String?, in context: ModelContext, reminderID: String, externalID: String?) throws {
        var row = match(try context.fetch(FetchDescriptor<TaskExtras>()), id: reminderID, externalID: externalID)
        if row == nil, eventID != nil {
            row = TaskExtras(reminderID: reminderID, externalID: externalID)
            context.insert(row!)
        }
        row?.eventID = eventID
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
                    owner.eventID = owner.eventID ?? extras.eventID
                    owner.flagged = owner.flagged || extras.flagged
                    owner.estimateMinutes = owner.estimateMinutes ?? extras.estimateMinutes
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
