#if os(iOS)
import Testing
import Foundation
@testable import mise

/// Spike #13: the share extension and "Open in mise" both land files here.
@MainActor
struct SharedInboxTests {
    @Test func importedFileIsListed() throws {
        let source = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).pdf")
        try Data("%PDF-1.4".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let copy = try SharedInbox.importFile(at: source)
        defer { try? FileManager.default.removeItem(at: copy) }

        #expect(copy.lastPathComponent.hasSuffix("-\(source.lastPathComponent)"))
        #expect(SharedInbox.files.first?.lastPathComponent == copy.lastPathComponent)
        #expect(try Data(contentsOf: copy) == Data("%PDF-1.4".utf8))
    }
}
#endif
