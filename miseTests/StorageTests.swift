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
}
