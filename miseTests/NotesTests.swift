import Testing
import SwiftData
import Foundation
@testable import mise

@MainActor
struct NotesTests {
    let container = try! ModelContainer(
        for: Schema(Storage.models),
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )

    private func context() -> ModelContext { container.mainContext }

    private func note(_ body: String, in context: ModelContext) -> Note {
        let note = Note(body: body)
        context.insert(note)
        return note
    }

    private func folder(_ name: String, parent: NoteFolder? = nil, in context: ModelContext) -> NoteFolder {
        let folder = NoteFolder(name: name, parent: parent)
        context.insert(folder)
        return folder
    }

    @Test func titleIsFirstNonBlankLineWithoutMarkers() {
        #expect(Note(body: "# Groceries\nmilk").title == "Groceries")
        #expect(Note(body: "\n  \n## Plan  \nmore").title == "Plan")
        #expect(Note(body: "- [ ] buy milk").title == "buy milk")
        #expect(Note(body: "- [x] done").title == "done")
        #expect(Note(body: "- item").title == "item")
        #expect(Note(body: "plain text").title == "plain text")
        #expect(Note(body: "").title == "New Note")
        #expect(Note(body: " \n\t\n").title == "New Note")
    }

    @Test func sortedPinnedFirstThenModifiedDescending() {
        let old = Note(body: "old"), new = Note(body: "new"), pinnedOld = Note(body: "pinned")
        old.modified = Date(timeIntervalSince1970: 1)
        new.modified = Date(timeIntervalSince1970: 3)
        pinnedOld.modified = Date(timeIntervalSince1970: 0)
        pinnedOld.pinned = true
        #expect(Notes.sorted([old, new, pinnedOld]).map(\.body) == ["pinned", "new", "old"])
    }

    @Test func nestedFoldersLinkBothWays() throws {
        let context = context()
        let parent = folder("Work", in: context)
        let child = folder("Projects", parent: parent, in: context)
        try context.save()
        #expect(child.parent === parent)
        #expect(parent.children?.map(\.name) == ["Projects"])
    }

    @Test func deletingMiddleFolderMovesContentsToParent() throws {
        let context = context()
        let root = folder("Root", in: context)
        let middle = folder("Middle", parent: root, in: context)
        let leaf = folder("Leaf", parent: middle, in: context)
        let note = note("hello", in: context)
        note.folder = middle
        try context.save()

        try Notes.delete(middle, context: context)

        #expect(note.folder === root)
        #expect(leaf.parent === root)
        #expect(Set((root.children ?? []).map(\.name)) == ["Leaf"])
        #expect(try context.fetch(FetchDescriptor<NoteFolder>()).count == 2)
        #expect(try context.fetch(FetchDescriptor<Note>()).count == 1)
    }

    @Test func deletingRootFolderMovesContentsToRoot() throws {
        let context = context()
        let top = folder("Top", in: context)
        let child = folder("Child", parent: top, in: context)
        let note = note("hello", in: context)
        note.folder = top
        try context.save()

        try Notes.delete(top, context: context)

        #expect(note.folder == nil)
        #expect(child.parent == nil)
        #expect(try context.fetch(FetchDescriptor<NoteFolder>()).map(\.name) == ["Child"])
        #expect(try context.fetch(FetchDescriptor<Note>()).count == 1)
    }

    @Test func movingNoteUpdatesBothFolders() throws {
        let context = context()
        let a = folder("A", in: context), b = folder("B", in: context)
        let note = note("hello", in: context)
        note.folder = a
        try context.save()
        #expect(a.notes?.count == 1)

        note.folder = b
        try context.save()
        #expect(a.notes?.isEmpty == true)
        #expect(b.notes?.first === note)
    }

    @Test func tagsAreSharedWithTasks() throws {
        let context = context()
        let task = TaskExtras(reminderID: "r", externalID: nil)
        context.insert(task)
        let taskTag = try #require(try mise.Tag.named("work", in: context))
        task.tags = [taskTag]
        let note = note("hello", in: context)
        let noteTag = try #require(try mise.Tag.named(" Work ", in: context))
        note.tags = [noteTag]
        try context.save()

        #expect(taskTag === noteTag)
        #expect(taskTag.tasks?.first === task)
        #expect(taskTag.notes?.first === note)
        #expect(try context.fetch(FetchDescriptor<mise.Tag>()).count == 1)
    }
}
