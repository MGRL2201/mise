import Foundation
import SwiftData

/// App-owned data lives in SwiftData. Model list is centralized here so
/// backup/restore (#8) and the container setup share one source of truth.
enum Storage {
    /// Adding a model? Also add it to `BackupService` export/restore (Backup.swift).
    static let models: [any PersistentModel.Type] = [
        Attachment.self,
    ]

    static func makeContainer() -> ModelContainer {
        // ponytail: plain on-disk container, no CloudKit config yet. Swap in
        // a CloudKit-backed ModelConfiguration later (SPEC §2.5) — model
        // shapes here already avoid @Attribute(.unique) to stay compatible.
        try! ModelContainer(for: Schema(Storage.models))
    }
}

/// A file attachment (photo, PDF, audio, ...). The file itself lives on disk
/// under Application Support, named by `id`; this model stores metadata only.
@Model
final class Attachment {
    var id: UUID = UUID()
    var filename: String = ""
    var createdAt: Date = Date()

    init(filename: String) {
        self.filename = filename
    }
}

/// Reads/writes attachment files by id under `baseDirectory` (defaults to
/// Application Support/Attachments). Tests pass a temp directory.
struct AttachmentFileStore {
    let baseDirectory: URL

    init(baseDirectory: URL? = nil) {
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            )[0]
            self.baseDirectory = appSupport.appendingPathComponent("Attachments")
        }
    }

    private func url(for id: UUID) -> URL {
        baseDirectory.appendingPathComponent(id.uuidString)
    }

    func write(_ data: Data, for id: UUID) throws {
        try FileManager.default.createDirectory(
            at: baseDirectory, withIntermediateDirectories: true
        )
        try data.write(to: url(for: id))
    }

    func read(for id: UUID) -> Data? {
        try? Data(contentsOf: url(for: id))
    }

    func delete(for id: UUID) throws {
        try FileManager.default.removeItem(at: url(for: id))
    }
}
