import Testing
import SwiftData
import Foundation
@testable import mise

@MainActor
struct StorageTests {
    @Test func attachmentModelRoundTrip() throws {
        let container = try ModelContainer(
            for: Schema(Storage.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext

        let attachment = mise.Attachment(filename: "photo.jpg")
        context.insert(attachment)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<mise.Attachment>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.filename == "photo.jpg")
        #expect(fetched.first?.id == attachment.id)
    }

    @Test func attachmentFileWriteReadDelete() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = AttachmentFileStore(baseDirectory: tempDir)
        let id = UUID()
        let data = Data("hello attachment".utf8)

        try store.write(data, for: id)
        #expect(store.read(for: id) == data)

        try store.delete(for: id)
        #expect(store.read(for: id) == nil)
    }

    #if os(iOS)
    /// The store must stay app-private: SwiftData's default configuration
    /// moves it into the App Group container once the entitlement exists.
    @Test func storeIsNotInAppGroupContainer() throws {
        let group = try #require(SharedStore.containerURL)
        let store = Storage.configuration.url
        #expect(!store.standardizedFileURL.path.hasPrefix(group.standardizedFileURL.path),
                "store \(store.path) is inside App Group \(group.path)")
    }
    #endif
}
