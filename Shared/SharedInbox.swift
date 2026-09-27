import Foundation

/// Spike #13: PDFs/images handed to mise by the share extension or "Open in
/// mise", parked in `<App Group container>/Inbox` until a real importer reads them.
nonisolated enum SharedInbox {
    struct NoContainer: Error {}

    static var folder: URL? {
        SharedStore.containerURL?.appending(path: "Inbox", directoryHint: .isDirectory)
    }

    /// Copies `url` to `Inbox/<uuid>-<original name>`; throws when the App Group isn't provisioned.
    @discardableResult
    static func importFile(at url: URL) throws -> URL {
        guard let folder else { throw NoContainer() }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appending(path: "\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    /// "Open in mise" (document types) hands the app a file URL.
    static func importOpened(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do { try importFile(at: url) } catch { print("SharedInbox: import failed: \(error)") }
    }

    /// Newest first (by when the file was added to the folder; copies keep the source's dates).
    static var files: [URL] {
        guard let folder, let urls = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.addedToDirectoryDateKey]) else { return [] }
        func added(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate) ?? .distantPast
        }
        return urls.sorted { added($0) > added($1) }
    }
}
