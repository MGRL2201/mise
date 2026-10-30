import Foundation
import SwiftData

// Notes (#52). Same model rules as Storage.swift: defaults everywhere, no unique attributes.

@Model
final class NoteFolder {
    var id: UUID = UUID()
    var name: String = ""
    var createdAt: Date = Date()
    var parent: NoteFolder?
    @Relationship(inverse: \NoteFolder.parent) var children: [NoteFolder]? = []
    @Relationship(inverse: \Note.folder) var notes: [Note]? = []

    init(name: String, parent: NoteFolder? = nil) {
        self.name = name
        self.parent = parent
    }
}

@Model
final class Note {
    var id: UUID = UUID()
    /// Markdown; the source of truth.
    var body: String = ""
    var createdAt: Date = Date()
    /// Bumped by body edits only (not moves or pins).
    var modified: Date = Date()
    var pinned = false
    var folder: NoteFolder?
    var tags: [Tag]? = []

    init(body: String = "") {
        self.body = body
    }

    /// First non-blank line, minus a leading heading / list / checkbox marker.
    var title: String {
        guard var line = body.split(whereSeparator: \.isNewline).lazy
            .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return "New Note" }
        if let marker = line.firstMatch(of: /^(#{1,6}|- \[[ xX]\]|[-*+])(\s+|$)/) { line.removeSubrange(marker.range) }
        let title = line.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? "New Note" : title
    }
}

enum Notes {
    /// Pinned first, then most recently modified.
    static func sorted(_ notes: [Note]) -> [Note] {
        notes.sorted { ($0.pinned ? 1 : 0, $0.modified) > ($1.pinned ? 1 : 0, $1.modified) }
    }

    /// Moves the folder's notes and child folders up to its parent (root when nil), then deletes it. Saves.
    static func delete(_ folder: NoteFolder, context: ModelContext) throws {
        for note in folder.notes ?? [] { note.folder = folder.parent }
        for child in folder.children ?? [] { child.parent = folder.parent }
        context.delete(folder)
        do { try context.save() } catch { context.rollback(); throw error }
    }

    /// Every folder with its "Parent / Child" path, sorted by path (the Move list). Stops at a parent cycle.
    static func paths(_ folders: [NoteFolder]) -> [(folder: NoteFolder, path: String)] {
        folders.map { folder in
            var names: [String] = [], seen: Set<UUID> = [], current: NoteFolder? = folder
            while let next = current, seen.insert(next.id).inserted {
                names.insert(next.name, at: 0)
                current = next.parent
            }
            return (folder, names.joined(separator: " / "))
        }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

#if DEBUG
extension Notes {
    /// Screenshot data for `-miseSeedFinance YES`; only ever inserted into an in-memory container.
    static func seed(_ context: ModelContext) {
        let work = NoteFolder(name: "Work"), projects = NoteFolder(name: "Projects"), personal = NoteFolder(name: "Personal")
        [work, projects, personal].forEach(context.insert)
        projects.parent = work
        let tagWork = try? Tag.named("work", in: context), ideas = try? Tag.named("ideas", in: context)
        let seeds: [(String, NoteFolder?, Bool, [Tag?], Double)] = [
            ("# Shopping list\n- [ ] Milk\n- [ ] Eggs\n- [ ] Coffee beans", nil, true, [], 5),
            ("# Standup notes\nShipped notes folders. Next: rich editor.", work, false, [tagWork], 1),
            ("# mise roadmap\n- Notes editor\n- Wake tracker", projects, false, [tagWork, ideas], 2),
            ("# Trip to Kyoto\nBook ryokan, JR pass.", personal, false, [], 3),
            ("Gift ideas for Mum", nil, false, [ideas], 4),
        ]
        for (body, folder, pinned, tags, hoursAgo) in seeds {
            let note = Note(body: body)
            context.insert(note)
            note.folder = folder
            note.pinned = pinned
            note.tags = tags.compactMap { $0 }
            note.modified = .now.addingTimeInterval(-hoursAgo * 3600)
        }
        try? context.save()
    }
}
#endif
