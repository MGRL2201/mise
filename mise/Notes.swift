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
    var created: Date = Date()
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
        guard var line = body.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return "New Note" }
        if let marker = line.firstMatch(of: /^(#{1,6} |- \[[ xX]\] |- )/) { line.removeSubrange(marker.range) }
        return line.trimmingCharacters(in: .whitespaces)
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
}
