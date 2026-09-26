import Testing
import SwiftData
import Foundation
@testable import mise

@MainActor
struct BackupTests {
    @MainActor private struct Store {
        let container: ModelContainer
        let files: AttachmentFileStore
        let defaults: UserDefaults
        var context: ModelContext { container.mainContext }
    }

    private func freshStore() throws -> Store {
        Store(
            container: try ModelContainer(
                for: Schema(Storage.models),
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            ),
            files: AttachmentFileStore(baseDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)),
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
    }

    private func export(_ store: Store) throws -> Data {
        try BackupService.export(context: store.context, files: store.files, defaults: store.defaults)
    }

    private func restore(_ data: Data, into store: Store) throws {
        try BackupService.restore(data, context: store.context, files: store.files, defaults: store.defaults)
    }

    private func add(_ filename: String, bytes: String, to store: Store) throws -> mise.Attachment {
        let attachment = mise.Attachment(filename: filename)
        store.context.insert(attachment)
        try store.files.write(Data(bytes.utf8), for: attachment.id)
        return attachment
    }

    @Test func backupThenRestoreIntoEmptyStoreIsIdentical() throws {
        let source = try freshStore()
        let originals = [try add("a.jpg", bytes: "aaa", to: source), try add("b.pdf", bytes: "bbb", to: source)]
        try source.context.save()
        source.defaults.set("wholeApp", forKey: "lock.mode")

        let target = try freshStore()
        try restore(try export(source), into: target)

        let restored = try target.context.fetch(FetchDescriptor<mise.Attachment>())
        #expect(restored.count == 2)
        for original in originals {
            let copy = try #require(restored.first { $0.id == original.id })
            #expect(copy.filename == original.filename)
            #expect(copy.createdAt == original.createdAt)
            #expect(target.files.read(for: copy.id) == source.files.read(for: original.id))
        }
        #expect(target.defaults.string(forKey: "lock.mode") == "wholeApp")
    }

    @Test func unknownVersionIsRejected() throws {
        let data = Data(#"{"version": 999}"#.utf8)
        #expect(throws: BackupError.unsupportedVersion(999)) {
            try restore(data, into: try freshStore())
        }
    }

    @Test func restoreReplacesExistingData() throws {
        let source = try freshStore()
        let kept = try add("new.txt", bytes: "new", to: source)
        let backup = try export(source)

        let target = try freshStore()
        let old = try add("old.txt", bytes: "old", to: target)
        try restore(backup, into: target)

        #expect(try target.context.fetch(FetchDescriptor<mise.Attachment>()).map(\.id) == [kept.id])
        #expect(target.files.read(for: old.id) == nil)
    }
}
