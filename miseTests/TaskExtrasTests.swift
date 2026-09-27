import Testing
import SwiftData
import Foundation
@testable import mise

@MainActor
struct TaskExtrasTests {
    let container = try! ModelContainer(
        for: Schema(Storage.models),
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )

    private func context() -> ModelContext { container.mainContext }

    private func extras(_ id: String, _ externalID: String?, in context: ModelContext) -> TaskExtras {
        let extras = TaskExtras(reminderID: id, externalID: externalID)
        context.insert(extras)
        return extras
    }

    @Test func matchPrefersIDThenExternalID() throws {
        let context = context()
        let byID = extras("a", "x", in: context)
        let byExternal = extras("b", "y", in: context)
        let blank = extras("c", "", in: context)
        let all = [byExternal, blank, byID]

        #expect(TaskExtras.match(all, id: "a", externalID: "y") === byID)
        #expect(TaskExtras.match(all, id: "new", externalID: "y") === byExternal)
        #expect(TaskExtras.match(all, id: "new", externalID: "") == nil)
        #expect(TaskExtras.match(all, id: "new", externalID: nil) == nil)
    }

    @Test func reconcileKeepsRelinksAndDeletesAfterGrace() throws {
        let context = context()
        let tag = try #require(try mise.Tag.named("Work", in: context))
        let listed = extras("listed", nil, in: context)
        let moved = extras("old-id", "ext", in: context)
        let gone = extras("gone", nil, in: context)
        gone.tags = [tag]
        let oldCompleted = extras("old-done", nil, in: context)
        try context.save()
        let reminders: [(id: String, externalID: String?)] = [(id: "listed", externalID: nil), (id: "new-id", externalID: "ext")]
        let start = Date(timeIntervalSince1970: 1_000_000)

        try TaskExtras.reconcile(context, reminders: reminders, now: start, exists: { $0.reminderID == "old-done" })

        var left = try context.fetch(FetchDescriptor<TaskExtras>())
        #expect(Set(left.map(\.reminderID)) == ["listed", "new-id", "old-done", "gone"])
        #expect(moved.reminderID == "new-id")
        #expect(gone.missingSince == start)
        #expect(listed.missingSince == nil && oldCompleted.missingSince == nil)

        try TaskExtras.reconcile(context, reminders: reminders, now: start + 8 * 86400,
                                 exists: { $0.reminderID == "old-done" })

        left = try context.fetch(FetchDescriptor<TaskExtras>())
        #expect(Set(left.map(\.reminderID)) == ["listed", "new-id", "old-done"])
        #expect(try context.fetch(FetchDescriptor<mise.Tag>()).map(\.name) == ["Work"])
    }

    @Test func reconcileClearsMissingSinceWhenSeenAgain() throws {
        let context = context()
        let row = extras("r", nil, in: context)
        try TaskExtras.reconcile(context, reminders: [], exists: { _ in false })
        #expect(row.missingSince != nil)
        try TaskExtras.reconcile(context, reminders: [(id: "r", externalID: nil)], exists: { _ in false })
        #expect(row.missingSince == nil)
    }

    @Test func reconcileEmptyListDeletesNothingOnFirstPass() throws {
        let context = context()
        _ = extras("a", nil, in: context)
        _ = extras("b", "x", in: context)
        try TaskExtras.reconcile(context, reminders: [], exists: { _ in false })
        #expect(try context.fetch(FetchDescriptor<TaskExtras>()).count == 2)
    }

    @Test func reconcileMergesRelinkIntoExistingOwner() throws {
        let context = context()
        let work = try #require(try mise.Tag.named("Work", in: context))
        let home = try #require(try mise.Tag.named("Home", in: context))
        let old = extras("old-id", "ext", in: context)
        old.subtasks = [Subtask(title: "old")]
        old.tags = [work, home]
        let fresh = extras("new-id", nil, in: context)
        fresh.subtasks = [Subtask(title: "new")]
        fresh.tags = [work]
        try context.save()

        try TaskExtras.reconcile(context, reminders: [(id: "new-id", externalID: "ext")], exists: { _ in false })

        let left = try context.fetch(FetchDescriptor<TaskExtras>())
        #expect(left.count == 1 && left.first === fresh)
        #expect(fresh.subtasks.map(\.title) == ["new", "old"])
        #expect(Set((fresh.tags ?? []).map(\.name)) == ["Work", "Home"])
    }

    @Test func tagNamedTrimsAndIgnoresCase() throws {
        let context = context()
        #expect(try mise.Tag.named("  ", in: context) == nil)
        let work = try #require(try mise.Tag.named("Work", in: context))
        #expect(try mise.Tag.named(" work ", in: context) === work)
        #expect(try context.fetch(FetchDescriptor<mise.Tag>()).count == 1)
    }
}
