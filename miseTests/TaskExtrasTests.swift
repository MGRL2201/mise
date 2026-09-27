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

    @Test func reconcileKeepsRelinksAndDeletes() throws {
        let context = context()
        let tag = try #require(try mise.Tag.named("Work", in: context))
        let listed = extras("listed", nil, in: context)
        let moved = extras("old-id", "ext", in: context)
        let gone = extras("gone", nil, in: context)
        gone.tags = [tag]
        let oldCompleted = extras("old-done", nil, in: context)
        try context.save()

        try TaskExtras.reconcile(context, reminders: [(id: "listed", externalID: nil), (id: "new-id", externalID: "ext")],
                                 exists: { $0.reminderID == "old-done" })

        let left = try context.fetch(FetchDescriptor<TaskExtras>())
        #expect(Set(left.map(\.reminderID)) == ["listed", "new-id", "old-done"])
        #expect(moved.reminderID == "new-id")
        #expect(left.contains { $0 === listed } && left.contains { $0 === oldCompleted })
        #expect(try context.fetch(FetchDescriptor<mise.Tag>()).map(\.name) == ["Work"])
    }

    @Test func tagNamedTrimsAndIgnoresCase() throws {
        let context = context()
        #expect(try mise.Tag.named("  ", in: context) == nil)
        let work = try #require(try mise.Tag.named("Work", in: context))
        #expect(try mise.Tag.named(" work ", in: context) === work)
        #expect(try context.fetch(FetchDescriptor<mise.Tag>()).count == 1)
    }
}
